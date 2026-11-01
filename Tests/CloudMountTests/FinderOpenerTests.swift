import XCTest
@testable import CloudMount

final class FinderOpenerTests: XCTestCase {
    private func result(_ status: Int32 = 0, _ output: String = "", running: Bool = false) -> CommandResult {
        CommandResult(status: status, stdout: output, stderr: "", stillRunning: running)
    }
    @MainActor
    func testAcknowledgementDoesNotClaimFolderContentsHaveLoaded() {
        XCTAssertEqual(FinderOpener.interpret(result(0, "{\"status\":\"accepted\"}")), .accepted)
        XCTAssertEqual(FinderOpener.interpret(result(0, "{\"status\":\"not-mounted\"}")), .notMounted)
    }
    @MainActor
    func testTimeoutAndLateOrMissingAcknowledgementAreNotMountFailures() {
        for value in [result(-2), result(-2, running: true), result(1), result(), result(0, "{\"status\":\"unconfirmed\"}")] {
            XCTAssertEqual(FinderOpener.interpret(value), .unconfirmed)
        }
        XCTAssertEqual(FinderOpener.interpret(result(-1)), .unavailable)
    }
    @MainActor
    func testSlowRequestLeavesMainActorResponsiveAndCoalescesRepeatedClicks() async {
        let opener = FinderOpener()
        var launches = 0, heartbeat = false
        let task = Task {
            await opener.open(path: "/virtual/mount", helper: "unused") { _, _ in
                launches += 1
                try? await Task.sleep(nanoseconds: 200_000_000)
                return self.result(0, "{\"status\":\"accepted\"}")
            }
        }
        await Task.yield()
        XCTAssertTrue(opener.busy)
        await opener.open(path: "/virtual/mount", helper: "unused") { _, _ in XCTFail("duplicate request"); return self.result() }
        await opener.open(path: "/other/mount", helper: "unused") { _, _ in XCTFail("parallel helper"); return self.result() }
        heartbeat = true
        XCTAssertTrue(heartbeat)
        XCTAssertTrue(opener.busy)
        await task.value
        XCTAssertEqual(launches, 1)
        XCTAssertEqual(opener.outcome, .accepted)
        await opener.open(path: "/virtual/mount", helper: "unused") { _, _ in XCTFail("rapid repeated request"); return self.result() }
        XCTAssertFalse(opener.busy)
    }
    @MainActor
    func testUnkillableWorkerPreventsFurtherFinderHelpers() async {
        let opener = FinderOpener()
        await opener.open(path: "/virtual/a", helper: "unused") { _, _ in self.result(-2, running: true) }
        XCTAssertEqual(opener.outcome, .unconfirmed)
        await opener.open(path: "/virtual/b", helper: "unused") { _, _ in XCTFail("must not accumulate helpers"); return self.result() }
        XCTAssertFalse(opener.busy)
    }
    @MainActor
    func testRealStalledChildHasBoundedWaitAndDoesNotBlockMainActor() async {
        let opener = FinderOpener()
        let began = ProcessInfo.processInfo.systemUptime
        let task = Task {
            await opener.open(path: "/virtual/mount", helper: "unused") { _, _ in
                await CommandRunner.execute("/bin/sleep", arguments: ["10"], timeout: 0.2)
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(opener.busy)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 1)
        await task.value
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 3)
        XCTAssertEqual(opener.outcome, .unconfirmed)
    }
    func testHelperRefusesUnmountedOrInvalidPathsWithoutOpeningFinder() throws {
        var directory = Bundle(for: FinderOpenerTests.self).bundleURL.deletingLastPathComponent()
        var helper: String?
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("CloudMountHelper", isDirectory: false).path
            if FileManager.default.isExecutableFile(atPath: candidate) { helper = candidate; break }
            directory.deleteLastPathComponent()
        }
        let executable = try XCTUnwrap(helper)
        let unmounted = CommandRunner.run(executable, arguments: ["open-finder", "/private/tmp/CloudMount-not-mounted-" + UUID().uuidString], timeout: 5)
        XCTAssertTrue(unmounted.succeeded, unmounted.output)
        XCTAssertTrue(unmounted.stdout.contains("not-mounted"))
        for path in ["relative", "/private/tmp/../something"] {
            XCTAssertFalse(CommandRunner.run(executable, arguments: ["open-finder", path], timeout: 5).succeeded)
        }
    }
}
