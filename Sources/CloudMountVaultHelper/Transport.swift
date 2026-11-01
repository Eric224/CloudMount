import Foundation
import CloudMountVaultCore

struct BridgeBootstrap: Codable {
    let socket: String
    let folder: String
    let descriptor: VaultDescriptor
    let rawKey: Data
    let token: String
    let readyFile: String
    let scratch: String
    let readOnly: Bool
}

/// Private Unix-socket RC only. Secret configuration never enters process argv.
actor RemoteCiphertextStore: CiphertextStore {
    let socket: String
    let fs: String
    let diagnostic: URL
    init(socket: String, folder: String, diagnostic: URL) { self.socket = socket; fs = "cloudmount_base:" + folder; self.diagnostic = diagnostic }
    nonisolated private static func report(_ file: URL, method: String, status: Int, kind: String) {
        let value: [String: Any] = ["operation": method, "status": status, "kind": kind]
        if let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            var history = (try? Data(contentsOf: file)) ?? Data()
            if history.count < 4096 { history.append(bytes); history.append(10); try? history.write(to: file, options: .atomic) }
        }
    }
    private func safe(_ path: String) throws {
        guard !path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw VaultCoreError.unsafePath }
    }
    func call(_ method: String, _ parameters: [String: Any]) async throws -> [String: Any] {
        var scoped = parameters
        if method == "operations/copyfile" || method == "operations/movefile" {
            // These are filesystem mutations/materialization, not a sync
            // comparison. Drime has no ModTime precision: rclone otherwise
            // considers same-sized ciphertext equal and can discard the new
            // staged object. Revision checks remain in VaultFileSystem.
            scoped["_config"] = ["IgnoreTimes": true]
        }
        let input = try JSONSerialization.data(withJSONObject: scoped)
        let socket = self.socket, diagnostic = self.diagnostic
        let label = method + (method == "operations/copyfile" ? ((parameters["srcFs"] as? String ?? "").hasPrefix("cloudmount_base:") ? ".download" : ".upload") : "")
        return try await Task.detached {
            let process = Process(), stdin = Pipe(), stdout = Pipe(), stderr = FileHandle.nullDevice
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl", isDirectory: false)
            process.arguments = ["--silent", "--show-error", "--max-time", "45", "--connect-timeout", "1", "--noproxy", "*", "--unix-socket", socket,
                "-X", "POST", "-H", "Content-Type: application/json", "--data-binary", "@-", "http://localhost/" + method]
            process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
            try process.run()
            try stdin.fileHandleForWriting.write(contentsOf: input); try stdin.fileHandleForWriting.close()
            // All calls return bounded metadata; file bytes travel by private local files.
            var output = Data()
            while let chunk = try stdout.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                guard output.count + chunk.count <= 8_388_608 else { process.terminate(); throw VaultCoreError.unavailable }
                output.append(chunk)
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let value = try JSONSerialization.jsonObject(with: output) as? [String: Any] else {
                Self.report(diagnostic, method: label, status: Int(process.terminationStatus), kind: "transport")
                throw VaultCoreError.unavailable
            }
            if let code = value["status"] as? Int, code >= 400 {
                let error = (value["error"] as? String ?? "").lowercased()
                let category = ["directory not found", "object not found", "not found", "timeout", "forbidden", "not a directory", "file already exists", "is a directory", "failed to upload file", "failed to copy item", "read metadata", "failed to delete", "failed to initiate", "failed to upload part", "failed to complete", "signaturedoesnotmatch", "accessdenied", "expired", "failed to create entry", "multipart"].filter { error.contains($0) }.joined(separator: ",")
                Self.report(diagnostic, method: label, status: code, kind: category)
                if code == 404 { throw VaultCoreError.missing }
                throw VaultCoreError.unavailable
            }
            if value["error"] != nil { Self.report(diagnostic, method: label, status: 0, kind: "remote"); throw VaultCoreError.unavailable }
            return value
        }.value
    }
    private func item(_ o: [String: Any]) throws -> CipherItem {
        guard let name = o["Name"] as? String, let size = o["Size"] as? Int64,
              let directory = o["IsDir"] as? Bool, let timestamp = o["ModTime"] as? String else { throw VaultCoreError.malformed }
        let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = format.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp) ?? .distantPast
        let id = o["ID"] as? String ?? ""
        return CipherItem(name: name, size: max(0, size), modified: date, version: "\(id)|\(size)|\(timestamp)", isDirectory: directory)
    }
    func stat(_ path: String) async throws -> CipherItem {
        try safe(path)
        let o = try await call("operations/stat", ["fs": fs, "remote": path, "opt": ["showHash": false]])
        guard let value = o["item"] as? [String: Any] else { throw VaultCoreError.missing }
        return try item(value)
    }
    func list(_ path: String) async throws -> [CipherItem] {
        try safe(path)
        let o = try await call("operations/list", ["fs": fs, "remote": path, "opt": ["recurse": false]])
        guard let values = o["list"] as? [[String: Any]], values.count <= 50_000 else { throw VaultCoreError.malformed }
        return try values.map(item)
    }
    func read(_ path: String, limit: Int) async throws -> Data {
        guard try await stat(path).size <= limit else { throw VaultCoreError.malformed }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cm-cipher-" + UUID().uuidString, isDirectory: false)
        defer { try? FileManager.default.removeItem(at: url) }
        try await download(path, to: url)
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw VaultCoreError.malformed }
        return data
    }
    func download(_ path: String, to file: URL) async throws {
        try safe(path)
        _ = try await call("operations/copyfile", ["srcFs": fs, "srcRemote": path, "dstFs": file.deletingLastPathComponent().path, "dstRemote": file.lastPathComponent])
    }
    func upload(_ file: URL, to path: String) async throws {
        try safe(path)
        _ = try await call("operations/copyfile", ["srcFs": file.deletingLastPathComponent().path, "srcRemote": file.lastPathComponent, "dstFs": fs, "dstRemote": path])
    }
    func mkdir(_ path: String) async throws { try safe(path); _ = try await call("operations/mkdir", ["fs": fs, "remote": path]) }
    func move(_ source: String, to destination: String, directory: Bool, replace: Bool) async throws {
        try safe(source); try safe(destination)
        if !replace {
            do { _ = try await stat(destination); throw VaultCoreError.exists } catch VaultCoreError.missing {}
        }
        guard !directory else { throw VaultCoreError.unsupported }
        _ = try await call("operations/movefile", ["srcFs": fs, "srcRemote": source, "dstFs": fs, "dstRemote": destination])
    }
    func delete(_ path: String, directory: Bool) async throws {
        try safe(path)
        _ = try await call(directory ? "operations/rmdir" : "operations/deletefile", ["fs": fs, "remote": path])
    }
}
