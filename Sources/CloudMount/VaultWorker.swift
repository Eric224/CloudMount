import Foundation
import Darwin
import CloudMountVaultCore

@MainActor
final class VaultWorker {
    let executable: String
    let socket: String
    let control = CommandControl()
    private(set) var didExit = false
    private(set) var stillRunning = false
    private(set) var pid: Int32?
    private var task: Task<CommandResult, Never>?
    private let ownsProcess: Bool
    private var cacheOptions: [String: Any] = ["CacheMode": 3]
    private(set) var mountInFlight = false
    private var mountJob: Int?
    private var bridgeTask: Task<CommandResult, Never>?
    private var bridgeControl = CommandControl()
    private struct BridgeSession: Codable { let port: UInt16; let pid: Int32; let token: String; let scratch: String }
    private struct BridgeReady: Decodable { let port: UInt16; let pid: Int32 }
    private struct BridgeInput: Encodable {
        let socket: String; let folder: String; let descriptor: VaultDescriptor; let rawKey: Data
        let token: String; let readyFile: String; let scratch: String; let readOnly: Bool
    }
    private var bridge: BridgeSession?
    func bridgeDiagnostic() -> String {
        ["transport-error.json", "filesystem-error.json"].compactMap { name -> String? in
            let file = bridgeFile.deletingLastPathComponent().appendingPathComponent(name, isDirectory: false)
            guard let bytes = try? Data(contentsOf: file), bytes.count < 8192 else { return nil }
            return String(data: bytes, encoding: .utf8)
        }.joined(separator: " | ")
    }
    private var bridgeFile: URL { URL(fileURLWithPath: socket, isDirectory: false).deletingLastPathComponent().appendingPathComponent("bridge.json", isDirectory: false) }

    init(executable: String, socket: String, attached: Bool = false) {
        self.executable = executable; self.socket = socket; ownsProcess = !attached
        if attached, let bytes = try? Data(contentsOf: bridgeFile) { bridge = try? JSONDecoder().decode(BridgeSession.self, from: bytes) }
    }
    func start(cache: String, sizeGB: Int, ageHours: Int, directoryMinutes: Int = 5) async throws {
        guard ownsProcess, task == nil else { throw VaultFailure.invalid }
        cacheOptions = MountCachePolicy.vaultOptions(sizeGB: sizeGB, ageHours: ageHours, directoryMinutes: directoryMinutes)
        let args = ["rcd", "--config", "/dev/null", "--rc-addr", socket, "--rc-no-auth", "--ask-password=false",
                    "--cache-dir", cache, "--contimeout", "10s", "--timeout", "30s",
                    "--low-level-retries", "2", "--log-level", "ERROR"] + MountCachePolicy.processArguments
        let executable = self.executable, control = self.control
        task = Task {
            let result = await CommandRunner.execute(executable, arguments: args, timeout: nil,
                control: control, outputLimit: 4096, forceStop: false, discardOutput: true, environment: ["CGOFUSE_LIBFUSE_PATH": "/usr/local/lib/libfuse.2.dylib"])
            didExit = true; stillRunning = result.stillRunning
            return result
        }
        for _ in 0..<25 {
            if didExit { break }
            if (try? await call("core/version", timeout: 0.5)) != nil {
                // The parent directory is already private; restrict the socket too.
                guard chmod(socket, S_IRUSR | S_IWUSR) == 0 else { throw VaultFailure.invalid }
                try await capturePID()
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        control.cancel()
        throw VaultFailure.message("無法啟動保險箱工作程序，請確認 rclone 版本及 app 安裝完整。")
    }
    func capturePID() async throws {
        let result = try await call("core/pid", timeout: 2)
        guard let value = result["pid"] as? Int, value > 1, value <= Int(Int32.max) else { throw VaultFailure.invalid }
        pid = Int32(value)
    }
    func call(_ method: String, _ value: [String: Any] = [:], timeout: TimeInterval = 15) async throws -> [String: Any] {
        guard !didExit, !Task.isCancelled else { throw VaultFailure.message("保險箱工作程序已停止，請重新解鎖。") }
        let result = await CommandRunner.execute("/usr/bin/curl", arguments: ["--silent", "--show-error", "--fail-with-body",
            "--max-time", String(timeout), "--connect-timeout", "1", "--noproxy", "*", "--unix-socket", socket,
            "-X", "POST", "-H", "Content-Type: application/json", "--data-binary", "@-", "http://localhost/" + method],
            timeout: timeout + 1, outputLimit: 1_048_576, input: try JSONSerialization.data(withJSONObject: value))
        guard result.succeeded, let object = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
              (object["error"] as? String).map({ $0.isEmpty }) ?? true else {
            // RC responses may contain credentials or plaintext filenames.
            // Do not interpolate them into alerts or persistent logs.
            throw VaultFailure.message(VaultRemoteFailure.message(result))
        }
        return object
    }
    func configure(remote: String, config: [String: String], location: VaultLocation, keys: VaultSecrets, descriptor: VaultDescriptor? = nil, readOnly: Bool = false) async throws {
        guard let type = config["type"], ["drime", "webdav", "s3", "local"].contains(type) else {
            throw VaultFailure.message("此版本的保險箱先支援 Drime、WebDAV、MinIO 與其他 S3 相容服務。")
        }
        var base = config; base["type"] = nil
        _ = try await call("config/create", ["name": "cloudmount_base", "type": type, "parameters": base,
            "opt": ["nonInteractive": true, "noObscure": true]])
        if let descriptor, let raw = keys.cryptomatorKey {
            try await startBridge(location: location, descriptor: descriptor, raw: raw, readOnly: readOnly)
            guard let bridge else { throw VaultFailure.invalid }
            _ = try await call("config/create", ["name": "cloudmount_vault", "type": "webdav", "parameters": [
                "url": "http://127.0.0.1:\(bridge.port)/", "vendor": "other", "user": "cloudmount", "pass": bridge.token],
                "opt": ["nonInteractive": true, "obscure": true]])
            return
        }
        guard keys.cryptomatorKey == nil else { throw VaultFailure.invalid }
        _ = try await call("config/create", ["name": "cloudmount_vault", "type": "crypt", "parameters": [
            "remote": "cloudmount_base:" + location.folder + "/data", "password": keys.password, "password2": keys.salt,
            "filename_encryption": "standard", "directory_name_encryption": "true"],
            "opt": ["nonInteractive": true, "obscure": true]])
    }
    private func startBridge(location: VaultLocation, descriptor: VaultDescriptor, raw: Data, readOnly: Bool) async throws {
        let executableURL: URL
        if Bundle.main.bundleURL.pathExtension == "app" {
            executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CloudMountVaultHelper", isDirectory: false)
        } else {
            let binary = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0], isDirectory: false).deletingLastPathComponent()
            let nearby = binary.appendingPathComponent("CloudMountVaultHelper", isDirectory: false)
            if FileManager.default.isExecutableFile(atPath: nearby.path) { executableURL = nearby }
            else { executableURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).appendingPathComponent(".build/debug/CloudMountVaultHelper", isDirectory: false) }
        }
        let directory = bridgeFile.deletingLastPathComponent()
        let ready = directory.appendingPathComponent("ready.json", isDirectory: false)
        let scratch = try VaultDisk.privateDirectory(directory.appendingPathComponent("staging", isDirectory: true))
        let token = UUID().uuidString + UUID().uuidString
        let input = try JSONEncoder().encode(BridgeInput(socket: socket, folder: location.folder, descriptor: descriptor,
            rawKey: raw, token: token, readyFile: ready.path, scratch: scratch.path, readOnly: readOnly))
        let control = bridgeControl
        bridgeTask = Task {
            await CommandRunner.execute(executableURL.path, arguments: [], timeout: nil, control: control,
                outputLimit: 0, forceStop: false, input: input, discardOutput: true)
        }
        for _ in 0..<50 {
            if let bytes = try? Data(contentsOf: ready), let value = try? JSONDecoder().decode(BridgeReady.self, from: bytes) {
                guard value.pid > 1, value.port > 0 else { throw VaultFailure.invalid }
                bridge = BridgeSession(port: value.port, pid: value.pid, token: token, scratch: scratch.path)
                try VaultDisk.write(bridge!, to: bridgeFile)
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        // No mount or write has been submitted yet.
        bridgeControl.cancel()
        throw VaultFailure.message("無法啟動保險箱工作程序，請確認 rclone 版本及 app 安裝完整。")
    }
    private func stopBridge() async -> Bool {
        guard let bridge else { return true }
        let authorization = Data(("cloudmount:" + bridge.token).utf8).base64EncodedString()
        let config = "url = \"http://127.0.0.1:\(bridge.port)/\"\nrequest = \"CMSTOP\"\nheader = \"Authorization: Basic \(authorization)\"\n"
        let result = await CommandRunner.execute("/usr/bin/curl", arguments: ["--silent", "--fail", "--noproxy", "*", "--max-time", "3", "--config", "-"], timeout: 4, outputLimit: 0, input: Data(config.utf8))
        // A stale PID is never killed. Authenticated shutdown addresses this
        // exact helper; an absent helper after reboot is already stopped.
        for _ in 0..<20 {
            if kill(bridge.pid, 0) != 0, errno == ESRCH {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: bridge.scratch, isDirectory: true))
                self.bridge = nil; return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return result.succeeded && self.bridge == nil
    }
    func bridgeIsHealthy() async -> Bool {
        guard let bridge else { return true } // Legacy crypt worker.
        let authorization = Data(("cloudmount:" + bridge.token).utf8).base64EncodedString()
        let config = "url = \"http://127.0.0.1:\(bridge.port)/\"\nrequest = \"CMSTATUS\"\nheader = \"Authorization: Basic \(authorization)\"\n"
        let result = await CommandRunner.execute("/usr/bin/curl", arguments: ["--silent", "--fail", "--noproxy", "*", "--max-time", "2", "--config", "-"], timeout: 3, outputLimit: 0, input: Data(config.utf8))
        return result.succeeded
    }
    func verifyRoundTrip() async throws {
        let root = try VaultDisk.privateDirectory(FileManager.default.temporaryDirectory.appendingPathComponent("cm-check-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: root) }
        let source = Data(UUID().uuidString.utf8), name = ".cloudmount-check-" + UUID().uuidString
        try source.write(to: root.appendingPathComponent("input"), options: .atomic)
        _ = try await call("operations/copyfile", ["srcFs": root.path, "srcRemote": "input", "dstFs": "cloudmount_vault:", "dstRemote": name], timeout: 90)
        _ = try await call("operations/copyfile", ["srcFs": "cloudmount_vault:", "srcRemote": name, "dstFs": root.path, "dstRemote": "output"], timeout: 90)
        guard try Data(contentsOf: root.appendingPathComponent("output")) == source else { throw VaultFailure.invalid }
        _ = try await call("operations/deletefile", ["fs": "cloudmount_vault:", "remote": name], timeout: 90)
    }
    func mount(destination: String, readOnly: Bool, label: String, method: MountMethod = .nfs) async throws {
        guard method != .automatic else { throw VaultFailure.invalid }
        guard await bridgeIsHealthy() else { throw VaultFailure.message("保險箱工作程序已停止，請重新解鎖。") }
        mountInFlight = true
        var options = cacheOptions; options["ReadOnly"] = readOnly
        let job = try await call("mount/mount", ["fs": "cloudmount_vault:", "mountPoint": destination, "mountType": method.rcMountType,
            "vfsOpt": options, "mountOpt": method.mountOptions(label: label), "_async": true], timeout: 5)
        guard let id = job["jobid"] as? Int else { throw VaultFailure.invalid }
        mountJob = id
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while ProcessInfo.processInfo.systemUptime < deadline {
            let status = try await call("job/status", ["jobid": id], timeout: 2)
            if status["finished"] as? Bool == true {
                mountInFlight = false
                guard status["success"] as? Bool == true else { throw VaultFailure.message("保險箱掛載未完成，請檢查系統掛載狀態後重試。") }
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        throw VaultFailure.message("保險箱掛載指令未回應，已停止重複操作。請稍後檢查，必要時重新啟動 Mac。")
    }
    func refreshMountJob() async {
        guard mountInFlight, let mountJob else { return }
        if let result = try? await call("job/status", ["jobid": mountJob], timeout: 2), result["finished"] as? Bool == true { mountInFlight = false }
    }
    func shutdownAfterUnmount() async -> Bool {
        _ = try? await call("core/quit", timeout: 2)
        for _ in 0..<20 {
            if ownsProcess && didExit && !stillRunning { return await stopBridge() }
            if !ownsProcess {
                if let pid, kill(pid, 0) != 0, errno == ESRCH { return await stopBridge() }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if ownsProcess { control.cancel() }
        for _ in 0..<15 {
            if didExit && !stillRunning { return await stopBridge() }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
}

enum VaultDisk {
    static func privateDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(),
              chmod(url.path, S_IRWXU) == 0 else { throw VaultFailure.invalid }
        return url
    }
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        // Save panels can target Desktop/Documents: never chmod the user's
        // existing parent directory when exporting a recovery file.
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".cloudmount-write-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw VaultFailure.invalid }
        defer { unlink(temporary.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: JSONEncoder().encode(value))
            try handle.synchronize(); try handle.close()
            guard rename(temporary.path, url.path) == 0 else { throw VaultFailure.invalid }
        } catch { try? handle.close(); throw error }
    }
}

struct VaultUploadState: Equatable {
    let references: Int
    let queued: Int
    let uploading: Int
    let errors: Int
    let outOfSpace: Bool
    // inUse counts VFS references, not open file handles. Pending open writes
    // are checked independently using the cache's persisted Dirty flags.
    var clean: Bool { queued == 0 && uploading == 0 && errors == 0 && !outOfSpace }
    static func parse(_ object: [String: Any]) throws -> Self {
        guard let inUse = object["inUse"] as? Int, inUse >= 0,
              let disk = object["diskCache"] as? [String: Any],
              let queued = disk["uploadsQueued"] as? Int, queued >= 0,
              let uploading = disk["uploadsInProgress"] as? Int, uploading >= 0,
              let errors = disk["erroredFiles"] as? Int, errors >= 0,
              let outOfSpace = disk["outOfSpace"] as? Bool else { throw VaultFailure.invalid }
        return Self(references: inUse, queued: queued, uploading: uploading, errors: errors, outOfSpace: outOfSpace)
    }
}
