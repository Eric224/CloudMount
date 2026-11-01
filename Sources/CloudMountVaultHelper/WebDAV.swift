import Foundation
import CloudMountVaultCore

actor VaultWebDAV {
    let fs: VaultFileSystem
    let scratch: URL
    let readOnly: Bool
    var cache: (String, String, URL)?
    init(fs: VaultFileSystem, scratch: URL, readOnly: Bool) { self.fs = fs; self.scratch = scratch; self.readOnly = readOnly }
    private func path(_ target: String) throws -> String {
        guard target.hasPrefix("/"), !target.hasPrefix("//"), let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first,
              let decoded = String(path).removingPercentEncoding, !decoded.contains("\\"), !decoded.contains("\0"),
              !decoded.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw VaultCoreError.unsafePath }
        return decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    private func xml(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }
    private func etag(_ value: String) -> String { "\"" + Data(value.utf8).base64EncodedString() + "\"" }
    private func response(_ item: VaultItem, path: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~/"))
        let href = "/" + (path.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + (item.isDirectory && !path.isEmpty ? "/" : "")
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT: 0); date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return "<d:response><d:href>\(xml(href))</d:href><d:propstat><d:prop><d:displayname>\(xml(item.name))</d:displayname><d:resourcetype>\(item.isDirectory ? "<d:collection/>" : "")</d:resourcetype><d:getcontentlength>\(item.size)</d:getcontentlength><d:getlastmodified>\(date.string(from: item.modified))</d:getlastmodified><d:getetag>\(xml(etag(item.version)))</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
    }
    private func clearCache() { if let cache { try? FileManager.default.removeItem(at: cache.2) }; cache = nil }
    func handle(_ request: HTTPRequest) async throws -> HTTPReply {
        let p = try path(request.target)
        if request.method == "OPTIONS" { return HTTPReply(code: 200, headers: ["DAV":"1", "Allow":"OPTIONS, PROPFIND, HEAD, GET, PUT, MKCOL, DELETE, MOVE"]) }
        if readOnly, !["PROPFIND", "GET", "HEAD"].contains(request.method) { return HTTPReply(code: 403) }
        switch request.method {
        case "PROPFIND":
            guard ["0", "1"].contains(request.headers["depth"] ?? "1") else { return HTTPReply(code: 403) }
            let item = try await fs.stat(p)
            var output = response(item, path: p)
            if item.isDirectory, request.headers["depth"] != "0" {
                for child in try await fs.list(p) { output += response(child, path: p.isEmpty ? child.name : p + "/" + child.name) }
            }
            return HTTPReply(code: 207, headers: ["Content-Type":"application/xml; charset=utf-8"], data: Data(("<?xml version=\"1.0\" encoding=\"utf-8\"?><d:multistatus xmlns:d=\"DAV:\">" + output + "</d:multistatus>").utf8))
        case "GET", "HEAD":
            let item = try await fs.stat(p)
            guard !item.isDirectory else { return HTTPReply(code: 405) }
            var reply = HTTPReply(code: 200, headers: ["ETag":etag(item.version), "Accept-Ranges":"bytes", "Content-Type":"application/octet-stream"], length: UInt64(item.size))
            if let range = request.headers["range"] {
                guard range.hasPrefix("bytes="), !range.contains(",") else { return HTTPReply(code: 416) }
                let values = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
                guard values.count == 2 else { return HTTPReply(code: 416) }
                let total = UInt64(item.size)
                let start: UInt64, end: UInt64
                if values[0].isEmpty {
                    guard let suffix = UInt64(values[1]), suffix > 0, total > 0 else { return HTTPReply(code: 416) }
                    start = total - min(total, suffix); end = total - 1
                } else {
                    guard let lower = UInt64(values[0]), lower < total else { return HTTPReply(code: 416) }
                    start = lower; end = values[1].isEmpty ? total - 1 : min(UInt64(values[1]) ?? 0, total - 1)
                    guard end >= start else { return HTTPReply(code: 416) }
                }
                reply.code = 206; reply.offset = start; reply.length = end - start + 1
                reply.headers["Content-Range"] = "bytes \(start)-\(end)/\(total)"
            }
            if request.method == "HEAD" { return reply }
            if cache?.0 != p || cache?.1 != item.version {
                clearCache()
                let volume = try scratch.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                guard let free = volume.volumeAvailableCapacityForImportantUsage, item.size <= max(0, free / 3) else { throw VaultCoreError.unavailable }
                let file = scratch.appendingPathComponent("read-" + UUID().uuidString, isDirectory: false)
                _ = try await fs.download(p, to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                cache = (p, item.version, file)
            }
            reply.file = cache!.2
            return reply
        case "PUT":
            let before: VaultItem?
            do { before = try await fs.stat(p) } catch VaultCoreError.missing { before = nil }
            if let match = request.headers["if-match"], match != "*", before.map({ etag($0.version) }) != match { return HTTPReply(code: 412) }
            if request.headers["if-none-match"] == "*", before != nil { return HTTPReply(code: 412) }
            clearCache()
            try await fs.upload(request.body, to: p, expectedVersion: before?.version, requireNew: before == nil)
            return HTTPReply(code: before == nil ? 201 : 204)
        case "MKCOL": clearCache(); try await fs.mkdir(p); return HTTPReply(code: 201)
        case "DELETE":
            // Directory deletion is recursive only after enumerating through the
            // decrypted view. Unknown ciphertext is never purged implicitly.
            clearCache(); try await remove(p); return HTTPReply(code: 204)
        case "MOVE":
            guard let destination = request.headers["destination"], let url = URLComponents(string: destination),
                  url.scheme == "http", url.host == "127.0.0.1", let port = url.port,
                  request.headers["host"] == "127.0.0.1:\(port)" else { return HTTPReply(code: 400) }
            let to = try path(url.percentEncodedPath)
            clearCache(); try await fs.move(p, to: to, replace: request.headers["overwrite"] != "F")
            return HTTPReply(code: 201)
        default: return HTTPReply(code: 405)
        }
    }
    private func remove(_ path: String) async throws {
        guard !path.isEmpty else { throw VaultCoreError.unsafePath }
        if try await fs.stat(path).isDirectory {
            for child in try await fs.list(path) { try await remove(path + "/" + child.name) }
        }
        try await fs.delete(path)
    }
}
