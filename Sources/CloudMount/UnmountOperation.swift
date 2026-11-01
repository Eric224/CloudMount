import Foundation

enum UnmountOutcome: Equatable {
    case unmounted
    case stillMounted(busy: Bool, details: String)
    case unsafe
    case unverified
}

/// Normal unmounts only. A failed utility must have exited before another is
/// considered, and the kernel mount table, rather than the exit code, decides
/// whether a volume has gone away. Never traverse the mounted directory.
enum UnmountOperation {
    @MainActor
    static func run(
        path: String, timeout: TimeInterval,
        execute: (String, [String], TimeInterval) async -> CommandResult = { executable, arguments, limit in
            await CommandRunner.execute(executable, arguments: arguments, timeout: limit, outputLimit: 16_384)
        },
        snapshot: () async -> [SystemMount]?,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) async -> UnmountOutcome {
        func containsPath(_ mounts: [SystemMount]) -> Bool {
            mounts.contains { RcloneHelpers.pathsEqual($0.destination, path) }
        }
        guard let before = await snapshot() else { return .unverified }
        guard containsPath(before) else { return .unmounted }
        let deadline = now() + timeout
        let first = await execute("/sbin/umount", [path], max(0.01, deadline - now()))
        guard !first.timedOut, !first.stillRunning else { return .unsafe }
        guard let after = await snapshot() else { return .unverified }
        guard containsPath(after) else { return .unmounted }

        let busy = isBusy(first.output)
        let remaining = deadline - now()
        // Disk Arbitration can ask applications to release a volume. This is
        // the normal, non-force form recommended by macOS's umount diagnostic.
        // Do not repeat an unsuccessful operation or retry a stalled utility.
        guard !first.succeeded, !first.cancelled, busy, remaining > 0.1 else {
            return .stillMounted(busy: busy, details: first.output)
        }
        let fallback = await execute("/usr/sbin/diskutil", ["unmount", path], remaining)
        guard !fallback.timedOut, !fallback.stillRunning else { return .unsafe }
        guard let final = await snapshot() else { return .unverified }
        guard containsPath(final) else { return .unmounted }
        return .stillMounted(busy: busy || isBusy(fallback.output),
            details: [first.output, fallback.output].filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    private static func isBusy(_ text: String) -> Bool {
        let value = text.lowercased()
        return value.contains("busy") || value.contains("in use") || value.contains("dissented")
    }
}
