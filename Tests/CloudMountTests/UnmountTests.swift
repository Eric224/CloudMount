import XCTest
@testable import CloudMount

final class UnmountTests: XCTestCase {
    @MainActor
    private func scenario(
        results: [CommandResult], snapshots: [[SystemMount]?], duration: TimeInterval = 0
    ) async -> (UnmountOutcome, [(String, [String], TimeInterval)], Int) {
        var calls: [(String, [String], TimeInterval)] = []
        var reads = 0
        var clock: TimeInterval = 100
        let outcome = await UnmountOperation.run(path: "/Cloud/NAS", timeout: 8,
            execute: { executable, arguments, limit in
                calls.append((executable, arguments, limit))
                clock += duration
                guard calls.count <= results.count else { XCTFail("Unexpected utility invocation"); return self.failure }
                return results[calls.count - 1]
            }, snapshot: {
                defer { reads += 1 }
                guard reads < snapshots.count else { XCTFail("Unexpected snapshot"); return nil }
                return snapshots[reads]
            }, now: { clock })
        return (outcome, calls, reads)
    }
    private var mounted: [SystemMount] { [SystemMount(source: "127.0.0.1:/", destination: "/Cloud/NAS", fileSystem: "nfs")] }
    private var success: CommandResult { CommandResult(status: 0, stdout: "", stderr: "", stillRunning: false) }
    private var busy: CommandResult { CommandResult(status: 1, stdout: "", stderr: "Resource busy -- try 'diskutil unmount'", stillRunning: false) }
    private var failure: CommandResult { CommandResult(status: 1, stdout: "", stderr: "Permission denied", stillRunning: false) }

    @MainActor func testNormalUnmountVerifiesKernelTable() async {
        let (outcome, calls, reads) = await scenario(results: [success], snapshots: [mounted, []])
        XCTAssertEqual(outcome, .unmounted)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, "/sbin/umount")
        XCTAssertEqual(calls.first?.1, ["/Cloud/NAS"])
        XCTAssertEqual(reads, 2)
    }
    @MainActor func testAlreadyGoneDoesNotLaunchUnmount() async {
        let (outcome, calls, _) = await scenario(results: [], snapshots: [[]])
        XCTAssertEqual(outcome, .unmounted)
        XCTAssertTrue(calls.isEmpty)
    }
    @MainActor func testBusyUsesOneNormalDiskutilFallbackWithinSharedBudget() async {
        let (outcome, calls, _) = await scenario(results: [busy, success], snapshots: [mounted, mounted, []], duration: 3)
        XCTAssertEqual(outcome, .unmounted)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.last?.0, "/usr/sbin/diskutil")
        XCTAssertEqual(calls.last?.1, ["unmount", "/Cloud/NAS"])
        XCTAssertEqual(calls.last?.2, 5)
    }
    @MainActor func testStillBusyIsMountedAndRetryableWithoutSwallowingRealFailures() async {
        let (outcome, calls, _) = await scenario(results: [busy, failure], snapshots: [mounted, mounted, mounted])
        guard case .stillMounted(let isBusy, let details) = outcome else { return XCTFail("Busy mount lost its state") }
        XCTAssertTrue(isBusy)
        XCTAssertTrue(details.contains("Resource busy"))
        XCTAssertEqual(calls.count, 2)
        let phase = MountPhase.afterUnmountFailure(previous: .mounted, current: .unmounting, busy: isBusy)
        XCTAssertEqual(phase, .inUse)
        XCTAssertTrue(phase.allowsOpening)
        XCTAssertEqual(MountPhase.afterUnmountFailure(previous: .inUse, current: .unmounting, busy: true), .inUse)
        XCTAssertEqual(MountPhase.afterUnmountFailure(previous: .mounted, current: .failed, busy: true), .failed)
        XCTAssertEqual(MountPhase.afterUnmountFailure(previous: .mounted, current: .blocked, busy: true), .blocked)
    }
    @MainActor func testSuccessfulExitDoesNotInventUnmountSuccessOrRetry() async {
        let (outcome, calls, _) = await scenario(results: [success], snapshots: [mounted, mounted])
        XCTAssertEqual(outcome, .stillMounted(busy: false, details: ""))
        XCTAssertEqual(calls.count, 1)
    }
    @MainActor func testPermissionFailureDoesNotRunAnotherUtility() async {
        let (outcome, calls, _) = await scenario(results: [failure], snapshots: [mounted, mounted])
        XCTAssertEqual(outcome, .stillMounted(busy: false, details: "Permission denied"))
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(MountPhase.afterUnmountFailure(previous: .mounted, current: .unmounting, busy: false), .mounted)
    }
    @MainActor func testTimeoutOrLivingUtilityStopsAllFurtherAttempts() async {
        for result in [CommandResult(status: -2, stdout: "", stderr: "", stillRunning: false),
                       CommandResult(status: 1, stdout: "", stderr: "Resource busy", stillRunning: true)] {
            let (outcome, calls, reads) = await scenario(results: [result], snapshots: [mounted])
            XCTAssertEqual(outcome, .unsafe)
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(reads, 1)
        }
        let stalled = CommandResult(status: -2, stdout: "", stderr: "", stillRunning: false)
        let (outcome, calls, _) = await scenario(results: [busy, stalled], snapshots: [mounted, mounted])
        XCTAssertEqual(outcome, .unsafe)
        XCTAssertEqual(calls.count, 2)
    }
    @MainActor func testSnapshotFailureDoesNotInventSuccess() async {
        for (results, snapshots) in [([], [nil]), ([success], [mounted, nil]), ([busy, success], [mounted, mounted, nil])] as [([CommandResult], [[SystemMount]?])] {
            let (outcome, calls, _) = await scenario(results: results, snapshots: snapshots)
            XCTAssertEqual(outcome, .unverified)
            XCTAssertEqual(calls.count, results.count)
        }
    }
    @MainActor func testExhaustedBudgetDoesNotLaunchFallback() async {
        let (outcome, calls, _) = await scenario(results: [busy], snapshots: [mounted, mounted], duration: 8)
        XCTAssertEqual(outcome, .stillMounted(busy: true, details: busy.output))
        XCTAssertEqual(calls.count, 1)
    }
}
