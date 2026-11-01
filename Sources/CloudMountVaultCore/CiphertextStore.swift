import Foundation

public struct CipherItem: Codable, Sendable, Equatable {
    public var name: String
    public var size: Int64
    public var modified: Date
    public var version: String
    public var isDirectory: Bool
    public init(name: String, size: Int64, modified: Date, version: String, isDirectory: Bool) {
        self.name = name; self.size = size; self.modified = modified; self.version = version; self.isDirectory = isDirectory
    }
}

/// Relative ciphertext paths only. Adapters must not reinterpret names as URLs
/// or shell input. Authentication, retry and conditional writes belong here.
public protocol CiphertextStore: Sendable {
    func stat(_ path: String) async throws -> CipherItem
    func list(_ path: String) async throws -> [CipherItem]
    func read(_ path: String, limit: Int) async throws -> Data
    func download(_ path: String, to file: URL) async throws
    func upload(_ file: URL, to path: String) async throws
    func mkdir(_ path: String) async throws
    func move(_ source: String, to destination: String, directory: Bool, replace: Bool) async throws
    func delete(_ path: String, directory: Bool) async throws
}

public actor LocalCiphertextStore: CiphertextStore {
    private let root: URL
    public init(root: URL) { self.root = root.resolvingSymlinksInPath() }
    private func url(_ path: String) throws -> URL {
        guard !path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { throw VaultCoreError.unsafePath }
        var current = root
        for component in path.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: false)
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: current.path)
                guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else { throw VaultCoreError.unsafePath }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { break }
        }
        return root.appendingPathComponent(path, isDirectory: false)
    }
    public func stat(_ path: String) throws -> CipherItem {
        let file = try url(path)
        let a: [FileAttributeKey: Any]
        do { a = try FileManager.default.attributesOfItem(atPath: file.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { throw VaultCoreError.missing }
        guard a[.type] as? FileAttributeType != .typeSymbolicLink else { throw VaultCoreError.unsafePath }
        let size = (a[.size] as? NSNumber)?.int64Value ?? 0
        let date = a[.modificationDate] as? Date ?? .distantPast
        return CipherItem(name: file.lastPathComponent, size: size, modified: date,
                          version: "\(a[.systemFileNumber] ?? ""):\(size):\(date.timeIntervalSince1970)", isDirectory: a[.type] as? FileAttributeType == .typeDirectory)
    }
    public func list(_ path: String) throws -> [CipherItem] {
        guard try stat(path).isDirectory else { throw VaultCoreError.missing }
        return try FileManager.default.contentsOfDirectory(atPath: url(path).path).map { try stat(path.isEmpty ? $0 : path + "/" + $0) }
    }
    public func read(_ path: String, limit: Int) throws -> Data {
        guard try stat(path).size <= limit else { throw VaultCoreError.malformed }
        return try Data(contentsOf: url(path))
    }
    public func download(_ path: String, to file: URL) throws {
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.copyItem(at: url(path), to: file)
    }
    public func upload(_ file: URL, to path: String) throws {
        let target = try url(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".staged-" + UUID().uuidString, isDirectory: false)
        try FileManager.default.copyItem(at: file, to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: target) }
    }
    public func mkdir(_ path: String) throws { try FileManager.default.createDirectory(at: url(path), withIntermediateDirectories: true) }
    public func move(_ source: String, to destination: String, directory: Bool, replace: Bool) throws {
        let a = try url(source), b = try url(destination)
        if FileManager.default.fileExists(atPath: b.path) {
            guard replace, !directory else { throw VaultCoreError.exists }
            _ = try FileManager.default.replaceItemAt(b, withItemAt: a)
        } else { try FileManager.default.moveItem(at: a, to: b) }
    }
    public func delete(_ path: String, directory: Bool) throws {
        let file = try url(path)
        if directory, !(try FileManager.default.contentsOfDirectory(atPath: file.path)).isEmpty { throw VaultCoreError.busy }
        try FileManager.default.removeItem(at: file)
    }
}
