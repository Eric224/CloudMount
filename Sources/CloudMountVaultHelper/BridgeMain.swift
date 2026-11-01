import Foundation
import Network
import Darwin
import CloudMountVaultCore

@main struct BridgeMain {
    static func main() async {
        umask(0o077)
        do {
            if CommandLine.arguments.dropFirst() == ["--check-installation"] {
                let fixture = Data((0..<64).map(UInt8.init))
                let words = try RecoveryWords.encode(fixture)
                guard try RecoveryWords.decode(words) == fixture else { throw VaultCoreError.malformed }
                FileHandle.standardOutput.write(Data("{\"vaultFormat\":8,\"recoveryWordCount\":44}\n".utf8))
                return
            }
            let input = FileHandle.standardInput.readDataToEndOfFile()
            guard input.count < 262144 else { throw VaultCoreError.malformed }
            let config = try JSONDecoder().decode(BridgeBootstrap.self, from: input)
            let scratch = URL(fileURLWithPath: config.scratch, isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let store = RemoteCiphertextStore(socket: config.socket, folder: config.folder, diagnostic: URL(fileURLWithPath: config.readyFile, isDirectory: false).deletingLastPathComponent().appendingPathComponent("transport-error.json", isDirectory: false))
            let fs = try VaultFileSystem(store: store, descriptor: config.descriptor, rawKey: config.rawKey, scratch: scratch)
            let dav = VaultWebDAV(fs: fs, scratch: scratch, readOnly: config.readOnly), gate = BridgeOperationGate()
            let authorization = "Basic " + Data(("cloudmount:" + config.token).utf8).base64EncodedString()
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            let listener = try NWListener(using: parameters)
            let queue = DispatchQueue(label: "CloudMount.vault.bridge")
            // Cap open connections, including clients waiting to send a body.
            let slots = DispatchSemaphore(value: 8)
            listener.newConnectionHandler = { connection in
                guard slots.wait(timeout: .now()) == .success else { connection.cancel(); return }
                connection.start(queue: queue)
                let http = HTTPConnection(connection, scratch: scratch)
                let timeout = DispatchWorkItem { connection.cancel() }
                queue.asyncAfter(deadline: .now() + 120, execute: timeout)
                Task {
                    defer { timeout.cancel(); connection.cancel(); slots.signal() }
                    do {
                        let request = try await http.request(expectedAuthorization: authorization)
                        defer { try? FileManager.default.removeItem(at: request.body) }
                        if request.method == "CMSTATUS", request.target == "/" {
                            try await http.reply(HTTPReply(code: 200))
                            return
                        }
                        // Keep the read staging file alive until the response has
                        // finished, so another mutation cannot remove it mid-send.
                        try await gate.run {
                            if request.method == "CMSTOP", request.target == "/" {
                                try await http.reply(HTTPReply(code: 204))
                                queue.asyncAfter(deadline: .now() + 0.1) { exit(0) }
                                return
                            }
                            let reply = try await dav.handle(request)
                            try await http.reply(reply, head: request.method == "HEAD")
                        }
                    } catch {
                        let kind: String
                        if let failure = error as? VaultCoreError { kind = String(describing: failure) } else { kind = "filesystem" }
                        let diagnostic = URL(fileURLWithPath: config.readyFile, isDirectory: false).deletingLastPathComponent().appendingPathComponent("filesystem-error.json", isDirectory: false)
                        try? JSONEncoder().encode(["kind":kind, "method":"request"]).write(to: diagnostic, options: .atomic)
                        let code: Int
                        switch error {
                        case VaultCoreError.password: code = 401
                        case VaultCoreError.missing: code = 404
                        case VaultCoreError.exists, VaultCoreError.conflict: code = 409
                        case VaultCoreError.busy: code = 423
                        case VaultCoreError.unsafePath, VaultCoreError.malformed: code = 400
                        case VaultCoreError.unsupported: code = 405
                        default: code = 503
                        }
                        try? await http.reply(HTTPReply(code: code))
                    }
                }
            }
            listener.stateUpdateHandler = { state in
                if case .ready = state, let port = listener.port {
                    do {
                        try JSONEncoder().encode(BridgeReady(port: port.rawValue, pid: getpid())).write(to: URL(fileURLWithPath: config.readyFile, isDirectory: false), options: .atomic)
                    } catch { exit(1) }
                }
                if case .failed = state { exit(1) }
            }
            listener.start(queue: queue)
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        } catch { exit(1) }
    }
}
