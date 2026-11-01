import Foundation
import Darwin

final class CommandControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let stillRunning: Bool
    var output: String { [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n") }
    var succeeded: Bool { status == 0 && !stillRunning }
    var timedOut: Bool { status == -2 }
    var cancelled: Bool { status == -3 }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var pending = Data()
    private let limit: Int
    private var discardingPartialLine = false
    init(limit: Int) { self.limit = limit }
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        bytes.append(data)
        if bytes.count > limit { bytes.removeFirst(bytes.count - limit) }
        var chunk = data
        if discardingPartialLine {
            guard let end = chunk.firstIndex(of: 10) else { return }
            chunk = Data(chunk[chunk.index(after: end)...]); discardingPartialLine = false
        }
        pending.append(chunk)
        if pending.count > 65_536 { pending.removeAll(keepingCapacity: true); discardingPartialLine = true }
    }
    func text() -> String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
    func takePending(final: Bool = false) -> String {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { return "" }
        if final {
            let value = String(decoding: pending, as: UTF8.self)
            pending.removeAll(keepingCapacity: true); return value
        }
        guard let end = pending.lastIndex(of: 10) else { return "" }
        let value = String(decoding: pending[...end], as: UTF8.self)
        pending.removeSubrange(...end)
        return value
    }
}

// Runs off the main actor. Neither pipe draining nor a kernel-stalled child can
// leave its caller waiting forever. Output is bounded even for a noisy backend.
enum CommandRunner {
    static func run(_ executable: String, arguments: [String], timeout: TimeInterval? = 20,
                    control: CommandControl = CommandControl(), outputLimit: Int = 8_388_608,
                    forceStop: Bool = true, logFile: String? = nil, input: Data? = nil, discardOutput: Bool = false, environment: [String: String]? = nil, onOutput: ((String) -> Void)? = nil) -> CommandResult {
        if control.isCancelled { return CommandResult(status: -3, stdout: "", stderr: "", stillRunning: false) }
        let process = Process()
        if let environment { process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, value in value } }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let inputPipe = input == nil ? nil : Pipe()
        if let inputPipe { process.standardInput = inputPipe }
        let outPipe = Pipe(), errPipe = Pipe()
        let out = OutputBuffer(limit: outputLimit), err = OutputBuffer(limit: outputLimit)
        process.standardOutput = outPipe
        process.standardError = errPipe
        let exited = DispatchSemaphore(value: 0)
        let drained = DispatchGroup()
        if let logFile {
            do { try FileManager.default.createDirectory(at: URL(fileURLWithPath: logFile).deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            catch { return CommandResult(status: -1, stdout: "", stderr: L10n.error(error), stillRunning: false) }
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        } else if discardOutput {
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        } else {
        drained.enter(); drained.enter()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; drained.leave() } else { out.append(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; drained.leave() } else { err.append(data) }
        }
        }
        var logOffset: UInt64 = 0
        var logInode: UInt64 = 0
        func collectLog() {
            guard let logFile else { return }
            var info = stat()
            guard lstat(logFile, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return }
            if UInt64(info.st_ino) != logInode || UInt64(max(0, info.st_size)) < logOffset {
                logOffset = 0; logInode = UInt64(info.st_ino)
            }
            guard let handle = FileHandle(forReadingAtPath: logFile) else { return }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: logOffset)
                if let data = try handle.read(upToCount: 65_536), !data.isEmpty {
                    out.append(data); logOffset += UInt64(data.count)
                }
            } catch { }
        }
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return CommandResult(status: -1, stdout: "", stderr: L10n.error(error), stillRunning: false)
        }
        if let inputPipe, let input {
            try? inputPipe.fileHandleForReading.close()
            // Never interpolate secrets in command arguments. The private pipe
            // closes on EOF and its writer cannot stall the supervising loop.
            DispatchQueue.global(qos: .utility).async {
                let noSignal: Int32 = 1
                _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, noSignal)
                try? inputPipe.fileHandleForWriting.write(contentsOf: input)
                try? inputPipe.fileHandleForWriting.close()
            }
        }
        let start = ProcessInfo.processInfo.systemUptime
        var interrupted: Int32?
        while exited.wait(timeout: .now() + 0.1) != .success {
            collectLog()
            if let onOutput {
                let chunk = out.takePending() + err.takePending()
                if !chunk.isEmpty { onOutput(chunk) }
            }
            if control.isCancelled { interrupted = -3; break }
            if let timeout, ProcessInfo.processInfo.systemUptime - start >= timeout { interrupted = -2; break }
        }
        if interrupted != nil && process.isRunning {
            process.terminate()
            if exited.wait(timeout: .now() + 1) != .success && forceStop && process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 0.5)
            }
        }
        collectLog()
        let alive = process.isRunning
        if !alive { _ = drained.wait(timeout: .now() + 0.3) }
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        if let onOutput {
            let chunk = out.takePending(final: true) + err.takePending(final: true)
            if !chunk.isEmpty { onOutput(chunk) }
        }
        return CommandResult(status: interrupted ?? (alive ? -2 : process.terminationStatus),
                             stdout: out.text(), stderr: err.text(), stillRunning: alive)
    }

    static func execute(_ executable: String, arguments: [String], timeout: TimeInterval? = 20,
                        control: CommandControl = CommandControl(), outputLimit: Int = 8_388_608,
                        forceStop: Bool = true, logFile: String? = nil, input: Data? = nil, discardOutput: Bool = false, environment: [String: String]? = nil, onOutput: ((String) -> Void)? = nil) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: run(executable, arguments: arguments, timeout: timeout,
                    control: control, outputLimit: outputLimit, forceStop: forceStop, logFile: logFile, input: input, discardOutput: discardOutput, environment: environment, onOutput: onOutput))
            }
        }
    }
}

enum SessionSafety {
    static var bootID: String {
        var value = timeval(), size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0 else { return "unknown" }
        return "\(value.tv_sec)"
    }
    static func acquireInstanceLock() -> Bool {
        guard instanceFD < 0 else { return true }
        let bundle = (Bundle.main.bundleIdentifier ?? "com.codex.cloudmount").filter { $0.isLetter || $0.isNumber || ".-_".contains($0) }
        let path = "/private/tmp/\(bundle)-\(getuid()).lock"
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return false }
        instanceFD = fd
        return true
    }
    private static var instanceFD: Int32 = -1
}
