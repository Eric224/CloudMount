import Foundation
import Network
import CloudMountVaultCore

struct BridgeReady: Codable { let port: UInt16; let pid: Int32 }
struct HTTPRequest {
    let method: String
    let target: String
    let headers: [String: String]
    let body: URL
}
struct HTTPReply {
    var code: Int
    var headers: [String: String] = [:]
    var data = Data()
    var file: URL? = nil
    var offset: UInt64 = 0
    var length: UInt64? = nil
}

/// One complete filesystem operation at a time, including all suspension points.
actor BridgeOperationGate {
    var tail: Task<Void, Never> = Task {}
    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let job = Task { await previous.value; return try await operation() }
        tail = Task { _ = try? await job.value }
        return try await job.value
    }
}

final class HTTPConnection: @unchecked Sendable {
    let connection: NWConnection
    let scratch: URL
    var buffer = Data()
    init(_ connection: NWConnection, scratch: URL) { self.connection = connection; self.scratch = scratch }
    func next() async throws -> Data {
        try await withCheckedThrowingContinuation { c in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, end, error in
                if let error { c.resume(throwing: error) }
                else if let data, !data.isEmpty { c.resume(returning: data) }
                else { c.resume(throwing: VaultCoreError.unavailable) }
            }
        }
    }
    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }
    func line() async throws -> Data {
        while true {
            if let range = buffer.range(of: Data([13, 10])) {
                let value = buffer.subdata(in: 0..<range.lowerBound); buffer.removeSubrange(0..<range.upperBound); return value
            }
            guard buffer.count < 65536 else { throw VaultCoreError.malformed }
            buffer.append(try await next())
        }
    }
    func request(expectedAuthorization: String) async throws -> HTTPRequest {
        let first = try await line()
        guard let text = String(data: first, encoding: .utf8) else { throw VaultCoreError.malformed }
        let parts = text.split(separator: " ")
        guard parts.count == 3, parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else { throw VaultCoreError.malformed }
        var headers: [String: String] = [:], count = first.count
        while true {
            let bytes = try await line(); count += bytes.count
            guard count < 65536 else { throw VaultCoreError.malformed }
            if bytes.isEmpty { break }
            guard let field = String(data: bytes, encoding: .utf8), let colon = field.firstIndex(of: ":") else { throw VaultCoreError.malformed }
            let key = field[..<colon].lowercased()
            guard headers[key] == nil else { throw VaultCoreError.malformed }
            headers[key] = field[field.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["authorization"] == expectedAuthorization else { throw VaultCoreError.password }
        if headers["expect"]?.lowercased() == "100-continue" { try await send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)) }
        let body = scratch.appendingPathComponent("request-" + UUID().uuidString, isDirectory: false)
        guard FileManager.default.createFile(atPath: body.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw VaultCoreError.unavailable }
        let handle = try FileHandle(forWritingTo: body)
        do {
            if let transfer = headers["transfer-encoding"] {
                guard transfer.lowercased() == "chunked", headers["content-length"] == nil else { throw VaultCoreError.malformed }
                while true {
                    let line = try await line()
                    guard let text = String(data: line, encoding: .ascii), let size = UInt64(text.split(separator: ";")[0], radix: 16), size <= UInt64(Int64.max) else { throw VaultCoreError.malformed }
                    if size == 0 { guard try await self.line().isEmpty else { throw VaultCoreError.malformed }; break }
                    try await consume(size, into: handle)
                    guard try await self.line().isEmpty else { throw VaultCoreError.malformed }
                }
            } else {
                let size = headers["content-length"].flatMap(UInt64.init) ?? 0
                guard headers["content-length"] == nil || UInt64(headers["content-length"]!) != nil, size <= UInt64(Int64.max) else { throw VaultCoreError.malformed }
                try await consume(size, into: handle)
            }
            try handle.close()
        } catch { try? handle.close(); try? FileManager.default.removeItem(at: body); throw error }
        return HTTPRequest(method: String(parts[0]), target: String(parts[1]), headers: headers, body: body)
    }
    func consume(_ size: UInt64, into file: FileHandle) async throws {
        var remaining = size
        while remaining > 0 {
            if buffer.isEmpty { buffer.append(try await next()) }
            let n = min(buffer.count, Int(min(remaining, 65536)))
            try file.write(contentsOf: buffer.prefix(n)); buffer.removeFirst(n); remaining -= UInt64(n)
        }
    }
    func reply(_ reply: HTTPReply, head: Bool = false) async throws {
        let size = reply.length ?? UInt64(reply.data.count)
        var header = "HTTP/1.1 \(reply.code) \(Self.reason(reply.code))\r\nConnection: close\r\nContent-Length: \(size)\r\n"
        for (key, value) in reply.headers { header += key + ": " + value + "\r\n" }
        try await send(Data((header + "\r\n").utf8))
        guard !head else { return }
        if let file = reply.file {
            let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
            try input.seek(toOffset: reply.offset)
            var remaining = size
            while remaining > 0 {
                guard let data = try input.read(upToCount: Int(min(remaining, 65536))), !data.isEmpty else { throw VaultCoreError.unavailable }
                try await send(data); remaining -= UInt64(data.count)
            }
        } else if !reply.data.isEmpty { try await send(reply.data) }
    }
    static func reason(_ code: Int) -> String {
        [200:"OK",201:"Created",204:"No Content",206:"Partial Content",207:"Multi-Status",400:"Bad Request",401:"Unauthorized",403:"Forbidden",404:"Not Found",405:"Method Not Allowed",409:"Conflict",412:"Precondition Failed",416:"Range Not Satisfiable",423:"Locked",500:"Internal Server Error",503:"Service Unavailable"][code] ?? "Error"
    }
}
