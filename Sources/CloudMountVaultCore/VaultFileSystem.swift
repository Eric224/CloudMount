import Foundation
import CryptoKit
import CryptomatorCryptoLib

public struct VaultItem: Sendable {
    public let name: String
    public let size: Int64
    public let modified: Date
    public let version: String
    public let isDirectory: Bool
}

/// Cryptomator format 8 path layer. A platform adapter serializes complete
/// operations; actor reentrancy alone is not a mutation lock across awaits.
public actor VaultFileSystem {
    private let store: any CiphertextStore
    private let cryptor: Cryptor
    private let threshold: Int
    private let scratch: URL
    public init(store: any CiphertextStore, descriptor: VaultDescriptor, rawKey: Data, scratch: URL) throws {
        self.store = store; cryptor = try descriptor.cryptor(rawKey: rawKey)
        threshold = descriptor.shorteningThreshold; self.scratch = scratch
    }
    public func initialize() async throws {
        let folder = try contentDirectory("")
        try await store.mkdir(folder)
        try await backupDirectoryID("", at: folder)
    }
    private func parts(_ path: String) throws -> [String] {
        guard !path.contains("\0"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw VaultCoreError.unsafePath }
        let values = path.split(separator: "/").map { String($0).precomposedStringWithCanonicalMapping }
        guard values.count <= 128, !values.contains(where: { $0 == "." || $0 == ".." || $0.utf8.count > 4096 }) else { throw VaultCoreError.unsafePath }
        return values
    }
    private func contentDirectory(_ id: String) throws -> String {
        let hash = try cryptor.encryptDirId(Data(id.utf8))
        return "d/" + hash.prefix(2) + "/" + hash.dropFirst(2)
    }
    private struct Node {
        let name: String
        let base: String
        let fullName: String
        let shortened: Bool
    }
    private func node(_ name: String, parent: String) throws -> Node {
        let encrypted = try cryptor.encryptFileName(name, dirId: Data(parent.utf8)) + ".c9r"
        let short = encrypted.utf8.count > threshold
        let diskName = short ? shortenedName(Data(encrypted.utf8)) : encrypted
        return Node(name: name, base: try contentDirectory(parent) + "/" + diskName, fullName: encrypted, shortened: short)
    }
    private func shortenedName(_ bytes: Data) -> String {
        // Unlike JWT segments, Cryptomator's shortened name retains '=' padding.
        Data(Insecure.SHA1.hash(data: bytes)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_") + ".c9s"
    }
    private func directoryID(_ path: [String]) async throws -> String {
        var id = "", visited = Set<String>()
        for name in path {
            let n = try node(name, parent: id)
            let bytes = try await store.read(n.base + "/dir.c9r", limit: 4096)
            guard let next = String(data: bytes, encoding: .utf8), !next.isEmpty, next.utf8.count <= 256,
                  !visited.contains(next) else { throw VaultCoreError.malformed }
            visited.insert(next); id = next
        }
        return id
    }
    private func locate(_ path: String) async throws -> (Node, String) {
        let values = try parts(path)
        guard let name = values.last else { throw VaultCoreError.unsafePath }
        let id = try await directoryID(Array(values.dropLast()))
        return (try node(name, parent: id), id)
    }
    private func item(_ n: Node, metadata: CipherItem? = nil) async throws -> VaultItem {
        let base: CipherItem
        if let metadata { base = metadata } else { base = try await store.stat(n.base) }
        if !base.isDirectory {
            guard !n.shortened, base.size >= cryptor.fileHeaderSize, base.size <= Int.max else { throw VaultCoreError.malformed }
            return VaultItem(name: n.name, size: Int64(try cryptor.calculateCleartextSize(Int(base.size) - cryptor.fileHeaderSize)), modified: base.modified, version: base.version, isDirectory: false)
        }
        let children = try await store.list(n.base)
        if let id = children.first(where: { $0.name == "dir.c9r" && !$0.isDirectory }) {
            return VaultItem(name: n.name, size: 0, modified: id.modified, version: id.version, isDirectory: true)
        }
        if n.shortened, let data = children.first(where: { $0.name == "contents.c9r" && !$0.isDirectory }), data.size >= cryptor.fileHeaderSize, data.size <= Int.max {
            return VaultItem(name: n.name, size: Int64(try cryptor.calculateCleartextSize(Int(data.size) - cryptor.fileHeaderSize)), modified: data.modified, version: data.version, isDirectory: false)
        }
        throw VaultCoreError.unsupported // Never silently reinterpret symlinks or unknown nodes.
    }
    public func stat(_ path: String) async throws -> VaultItem {
        if try parts(path).isEmpty { return VaultItem(name: "", size: 0, modified: .distantPast, version: "root", isDirectory: true) }
        return try await item(locate(path).0)
    }
    public func list(_ path: String) async throws -> [VaultItem] {
        try await list(path, excludingIncomplete: nil)
    }
    private func list(_ path: String, excludingIncomplete: String?) async throws -> [VaultItem] {
        let id = try await directoryID(parts(path))
        let folder = try contentDirectory(id)
        let entries = try await store.list(folder)
        var result: [VaultItem] = []
        for entry in entries {
            if folder + "/" + entry.name == excludingIncomplete { continue }
            guard entry.name.hasSuffix(".c9r") || entry.name.hasSuffix(".c9s") else { continue }
            if entry.name == "dirid.c9r" { continue }
            let shortened = entry.name.hasSuffix(".c9s")
            var encrypted = entry.name
            if shortened {
                let data = try await store.read(folder + "/" + entry.name + "/name.c9s", limit: 8192)
                guard let text = String(data: data, encoding: .utf8), text.hasSuffix(".c9r"),
                      shortenedName(data) == entry.name else { throw VaultCoreError.malformed }
                encrypted = text
            }
            let name = try cryptor.decryptFileName(String(encrypted.dropLast(4)), dirId: Data(id.utf8))
            guard try parts(name).count == 1, !name.contains("/") else { throw VaultCoreError.malformed }
            // The directory listing already includes size, version and time.
            // Re-statting every file turns one cloud request into N+1 requests.
            result.append(try await item(Node(name: name, base: folder + "/" + entry.name, fullName: encrypted, shortened: shortened), metadata: entry))
        }
        guard Set(result.map { $0.name.precomposedStringWithCanonicalMapping.lowercased() }).count == result.count else { throw VaultCoreError.conflict }
        return result
    }
    private func temporary(_ suffix: String = "") throws -> URL {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return scratch.appendingPathComponent(UUID().uuidString + suffix, isDirectory: false)
    }
    private func writeSmall(_ data: Data, to path: String) async throws {
        let file = try temporary()
        defer { try? FileManager.default.removeItem(at: file) }
        try data.write(to: file, options: [.atomic]); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try await store.upload(file, to: path)
    }
    private func backupDirectoryID(_ id: String, at directory: String) async throws {
        let plain = try temporary(), cipher = try temporary()
        defer { try? FileManager.default.removeItem(at: plain); try? FileManager.default.removeItem(at: cipher) }
        try Data(id.utf8).write(to: plain)
        try await cryptor.encryptContent(from: plain, to: cipher)
        try await store.upload(cipher, to: directory + "/dirid.c9r")
    }
    private func ensureMapping(_ n: Node) async throws {
        if n.shortened {
            try await store.mkdir(n.base)
            do {
                let existing = try await store.read(n.base + "/name.c9s", limit: 8192)
                guard existing == Data(n.fullName.utf8) else { throw VaultCoreError.conflict }
            } catch VaultCoreError.missing {}
            try await writeSmall(Data(n.fullName.utf8), to: n.base + "/name.c9s")
        }
    }
    /// Retry only an incomplete, otherwise empty standard long-name container.
    /// Any content, directory ID, symlink or unfamiliar object blocks repair.
    private func incompleteLongFile(_ n: Node) async throws -> Bool {
        guard n.shortened, try await store.stat(n.base).isDirectory else { return false }
        let entries = try await store.list(n.base)
        guard entries.allSatisfy({ $0.name == "name.c9s" && !$0.isDirectory }) else { return false }
        if entries.isEmpty { return true }
        return try await store.read(n.base + "/name.c9s", limit: 8192) == Data(n.fullName.utf8)
    }
    private func checkNameAvailable(_ path: String, excluding source: String? = nil) async throws {
        let values = try parts(path), parent = values.dropLast().joined(separator: "/")
        guard let name = values.last else { throw VaultCoreError.unsafePath }
        let sourceParts = try source.map(parts)
        let excluded = sourceParts?.dropLast().joined(separator: "/") == parent ? sourceParts?.last : nil
        for item in try await list(parent) where item.name != excluded {
            if item.name != name, item.name.caseInsensitiveCompare(name) == .orderedSame { throw VaultCoreError.conflict }
        }
    }
    public func mkdir(_ path: String) async throws {
        let (n, _) = try await locate(path)
        do { _ = try await store.stat(n.base); throw VaultCoreError.exists } catch VaultCoreError.missing {}
        try await checkNameAvailable(path)
        let id = UUID().uuidString, content = try contentDirectory(id)
        try await store.mkdir(content)
        try await backupDirectoryID(id, at: content)
        try await store.mkdir(n.base)
        try await ensureMapping(n)
        try await writeSmall(Data(id.utf8), to: n.base + "/dir.c9r")
    }
    public func download(_ path: String, to plain: URL) async throws -> VaultItem {
        let (n, _) = try await locate(path), before = try await item(n)
        guard !before.isDirectory else { throw VaultCoreError.unsupported }
        let cipher = try temporary()
        defer { try? FileManager.default.removeItem(at: cipher) }
        try await store.download(n.base + (n.shortened ? "/contents.c9r" : ""), to: cipher)
        do {
            try await cryptor.decryptContent(from: cipher, to: plain)
            guard try await item(n).version == before.version else { throw VaultCoreError.conflict }
            return before
        } catch { try? FileManager.default.removeItem(at: plain); throw error }
    }
    public func upload(_ plain: URL, to path: String, expectedVersion: String? = nil, requireNew: Bool = false) async throws {
        let (n, _) = try await locate(path)
        let before: VaultItem?
        do { before = try await item(n) }
        catch VaultCoreError.missing { before = nil }
        catch VaultCoreError.unsupported {
            guard try await incompleteLongFile(n) else { throw VaultCoreError.unsupported }
            before = nil
        }
        guard before?.isDirectory != true else { throw VaultCoreError.exists }
        if requireNew, before != nil { throw VaultCoreError.conflict }
        if let expectedVersion, before?.version != expectedVersion { throw VaultCoreError.conflict }
        if before == nil {
            let parent = (try parts(path)).dropLast().joined(separator: "/")
            let siblings = try await list(parent, excludingIncomplete: n.base)
            guard !siblings.contains(where: { $0.name.caseInsensitiveCompare(n.name) == .orderedSame }) else { throw VaultCoreError.conflict }
        }
        let cipher = try temporary()
        defer { try? FileManager.default.removeItem(at: cipher) }
        try await cryptor.encryptContent(from: plain, to: cipher)
        let target = n.base + (n.shortened ? "/contents.c9r" : "")
        let parentID = try await directoryID(Array(parts(path).dropLast()))
        let stage = try contentDirectory(parentID)
        // Some services reject extensionless dot-prefixed upload names. The
        // .tmp suffix is ignored by standard Cryptomator directory filters.
        let staged = stage + "/cloudmount-upload-" + UUID().uuidString + ".tmp"
        do {
            try await store.upload(cipher, to: staged)
            let current: VaultItem?
            do { current = try await item(n) }
            catch VaultCoreError.missing { current = nil }
            catch VaultCoreError.unsupported {
                guard before == nil, try await incompleteLongFile(n) else { throw VaultCoreError.conflict }
                current = nil
            }
            guard current?.version == before?.version else { throw VaultCoreError.conflict }
            if before == nil { try await ensureMapping(n) }
            try await store.move(staged, to: target, directory: false, replace: before != nil)
        } catch { try? await store.delete(staged, directory: false); throw error }
    }
    public func delete(_ path: String) async throws {
        let (n, _) = try await locate(path), value = try await item(n)
        if value.isDirectory {
            guard try await list(path).isEmpty else { throw VaultCoreError.busy }
            let id = try await directoryID(parts(path)), content = try contentDirectory(id)
            let children = try await store.list(content)
            guard children.allSatisfy({ $0.name == "dirid.c9r" }) else { throw VaultCoreError.busy }
            for child in children { try await store.delete(content + "/" + child.name, directory: false) }
            try await store.delete(content, directory: true)
            try await store.delete(n.base + "/dir.c9r", directory: false)
        } else { try await store.delete(n.base + (n.shortened ? "/contents.c9r" : ""), directory: false) }
        if n.shortened { try await store.delete(n.base + "/name.c9s", directory: false) }
        if n.shortened || value.isDirectory { try await store.delete(n.base, directory: true) }
    }
    public func move(_ source: String, to destination: String, replace: Bool) async throws {
        let (a, _) = try await locate(source), (b, _) = try await locate(destination)
        if a.base == b.base { return }
        let value = try await item(a)
        try await checkNameAvailable(destination, excluding: source)
        let existing: VaultItem?
        do { existing = try await item(b) } catch VaultCoreError.missing { existing = nil }
        if let existing {
            guard replace, !existing.isDirectory, !value.isDirectory else { throw VaultCoreError.exists }
        }
        if value.isDirectory {
            let from = try parts(source), to = try parts(destination)
            guard !to.starts(with: from) else { throw VaultCoreError.unsafePath }
            guard existing == nil else { throw VaultCoreError.exists }
            try await store.mkdir(b.base)
            try await ensureMapping(b)
            try await store.move(a.base + "/dir.c9r", to: b.base + "/dir.c9r", directory: false, replace: false)
            if a.shortened { try await store.delete(a.base + "/name.c9s", directory: false) }
            try await store.delete(a.base, directory: true)
        } else {
            try await ensureMapping(b)
            try await store.move(a.base + (a.shortened ? "/contents.c9r" : ""), to: b.base + (b.shortened ? "/contents.c9r" : ""), directory: false, replace: existing != nil)
            if a.shortened { try await store.delete(a.base + "/name.c9s", directory: false); try await store.delete(a.base, directory: true) }
        }
    }
}
