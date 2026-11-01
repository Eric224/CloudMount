import Citadel
import CloudMountVaultCore
import Foundation

/// Password-based SFTP with explicit SHA256 host-key confirmation. Originals
/// are replaced only with OpenSSH atomic rename, never remove-then-upload.
public struct SFTPStore: NativeConditionalStore, Sendable {
  private let address: FileServerAddress
  private let settings: FileServerSettings
  private let username: String, password: String
  public init(endpoint: URL, settings: FileServerSettings, username: String, password: String) throws {
    guard settings.kind == .sftp else { throw MobileError.invalidAddress }
    address = try FileServerAddress(endpoint, settings: settings)
    self.settings = settings; self.username = username; self.password = password
  }
  private func session<T: Sendable>(_ work: @escaping @Sendable (SFTPClient) async throws -> T) async throws -> T {
    let cancellation = TransferCancellation()
    let timer = DispatchWorkItem { cancellation.cancel() }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120, execute: timer)
    defer { timer.cancel(); cancellation.cancel() }
    do {
      return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        var options = SSHClientSettings(host: address.host, port: address.port,
          authenticationMethod: { .passwordBased(username: username, password: password) },
          hostKeyValidator: .sha256Pinned(settings.hostKeyFingerprint) {
            SSHHostVerification(host: address.host, fingerprint: $0, changed: $1)
          })
        options.connectTimeout = .seconds(20)
        let client = try await SSHClient.connect(to: options)
        cancellation.add { Task { try? await client.close() } }
        try Task.checkCancellation()
        var logger = clientLogger()
        logger.logLevel = .critical
        let sftp = try await client.openSFTP(logger: logger)
        cancellation.add { Task { try? await sftp.close() } }
        let result = try await work(sftp)
        try await sftp.close()
        try await client.close()
        return result
      } onCancel: { cancellation.cancel() }
    } catch let status as SFTPMessage.Status {
      switch status.errorCode {
      case .noSuchFile: throw VaultCoreError.missing
      case .permissionDenied: throw MobileError.forbidden
      case .unsupportedOperation: throw MobileError.unsupported
      default: throw MobileError.network(Int(status.errorCode.rawValue))
      }
    }
  }
  private func item(_ name: String, attributes: SFTPFileAttributes) throws -> CipherItem {
    guard let mode = attributes.permissions else { throw MobileError.incomplete }
    let type = mode & 0o170000
    guard type == 0o040000 || type == 0o100000 else { throw MobileError.unsupported }
    let directory = type == 0o040000
    guard let modified = attributes.accessModificationTime?.modificationTime,
      let size = directory ? UInt64(0) : attributes.size, size <= UInt64(Int64.max)
    else { throw MobileError.incomplete }
    return CipherItem(name: name, size: Int64(size), modified: modified,
      version: "\(size):\(modified.timeIntervalSince1970):\(mode)", isDirectory: directory)
  }
  public func homeDirectory() async throws -> String {
    try await session { try await $0.getRealPath(atPath: ".") }
  }
  private func checkedStat(_ path: String, sftp: SFTPClient) async throws -> CipherItem {
    // Check every component inside the selected root without following symlinks.
    let suffix = path.dropFirst(address.root == "/" ? 1 : address.root.count)
    var cursor = address.root
    var attributes = try await sftp.getLinkAttributes(at: cursor)
    guard attributes.permissions.map({ $0 & 0o170000 == 0o040000 }) == true else { throw MobileError.unsupported }
    for component in suffix.split(separator: "/") {
      cursor = (cursor == "/" ? "" : cursor) + "/" + component
      attributes = try await sftp.getLinkAttributes(at: cursor)
      _ = try item(String(component), attributes: attributes)
    }
    return try item((path as NSString).lastPathComponent, attributes: attributes)
  }
  private func optionalStat(_ path: String, sftp: SFTPClient) async throws -> CipherItem? {
    do { return try await checkedStat(path, sftp: sftp) }
    catch let status as SFTPMessage.Status where status.errorCode == .noSuchFile { return nil }
  }
  public func stat(_ path: String) async throws -> CipherItem {
    let full = try address.path(path)
    return try await session { try await checkedStat(full, sftp: $0) }
  }
  public func list(_ path: String) async throws -> [CipherItem] {
    let full = try address.path(path)
    return try await session { sftp in
      guard try await checkedStat(full, sftp: sftp).isDirectory else { throw VaultCoreError.missing }
      let chunks = try await sftp.listDirectory(atPath: full)
      var result = [CipherItem](), names = Set<Data>()
      for entry in chunks.flatMap(\.components) where entry.filename != "." && entry.filename != ".." {
        _ = try MobilePath.name(entry.filename)
        guard result.count < 20_000, names.insert(Data(entry.filename.utf8)).inserted else { throw MobileError.incomplete }
        result.append(try item(entry.filename, attributes: entry.attributes))
      }
      return result
    }
  }
  public func read(_ path: String, limit: Int) async throws -> Data {
    guard limit >= 0 else { throw MobileError.incomplete }
    let full = try address.path(path)
    return try await session { sftp in
      let original = try await checkedStat(full, sftp: sftp)
      guard !original.isDirectory, original.size <= limit else { throw MobileError.incomplete }
      return try await sftp.withFile(filePath: full, flags: .read) { file in
        var result = Data(), offset: UInt64 = 0
        while true {
          try Task.checkCancellation()
          let chunk = try await file.read(from: offset, length: 65_536)
          if chunk.readableBytes == 0 { break }
          guard chunk.readableBytes <= limit - result.count else { throw MobileError.incomplete }
          result.append(contentsOf: chunk.readableBytesView); offset += UInt64(chunk.readableBytes)
        }
        guard result.count == original.size else { throw MobileError.incomplete }
        return result
      }
    }
  }
  public func download(_ path: String, to file: URL) async throws {
    let full = try address.path(path)
    try await session { sftp in
      let original = try await checkedStat(full, sftp: sftp)
      guard !original.isDirectory else { throw MobileError.unsupported }
      FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
      let handle = try FileHandle(forWritingTo: file)
      do {
        let bytes = try await sftp.withFile(filePath: full, flags: .read) { remote in
          var offset: UInt64 = 0
          while true {
            try Task.checkCancellation()
            let buffer = try await remote.read(from: offset, length: 65_536)
            if buffer.readableBytes == 0 { break }
            try handle.write(contentsOf: Data(buffer.readableBytesView)); offset += UInt64(buffer.readableBytes)
            guard offset <= UInt64(original.size) else { throw MobileError.conflict }
          }
          return offset
        }
        try handle.close()
        guard bytes == UInt64(original.size), try await checkedStat(full, sftp: sftp).version == original.version else { throw MobileError.conflict }
      } catch { try? handle.close(); try? FileManager.default.removeItem(at: file); throw error }
    }
  }
  public func upload(_ file: URL, to path: String) async throws {
    try await put(file, path: path, expected: nil, requireNew: false)
  }
  public func put(_ file: URL, path: String, expected: String?, requireNew: Bool) async throws {
    guard !path.isEmpty else { throw MobileError.invalidName }
    let full = try address.path(path)
    try await session { sftp in
      let previous = try await optionalStat(full, sftp: sftp)
      guard !requireNew || previous == nil, expected == nil || previous?.version == expected,
        previous?.isDirectory != true else { throw MobileError.conflict }
      let parent = (full as NSString).deletingLastPathComponent
      guard try await checkedStat(parent, sftp: sftp).isDirectory else { throw MobileError.invalidAddress }
      let temporary = parent + "/.cloudmount-upload-" + UUID().uuidString
      do {
        try await sftp.withFile(filePath: temporary, flags: [.write, .create, .forceCreate]) { remote in
          let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
          var offset: UInt64 = 0
          while let data = try handle.read(upToCount: 65_536), !data.isEmpty {
            try Task.checkCancellation()
            try await remote.write(.init(bytes: data), at: offset); offset += UInt64(data.count)
          }
        }
        guard try await optionalStat(full, sftp: sftp)?.version == previous?.version else { throw MobileError.conflict }
        if previous == nil { try await sftp.rename(at: temporary, to: full) }
        else { try await sftp.posixRename(at: temporary, to: full) }
      } catch { try? await sftp.remove(at: temporary); throw error }
    }
  }
  public func mkdir(_ path: String) async throws {
    let parts = try MobilePath.checked(path).split(separator: "/")
    try await session { sftp in
      for count in 1...max(1, parts.count) where !parts.isEmpty {
        let full = try address.path(parts.prefix(count).joined(separator: "/"))
        if let item = try await optionalStat(full, sftp: sftp) {
          guard item.isDirectory else { throw MobileError.conflict }
        } else { try await sftp.createDirectory(atPath: full) }
      }
    }
  }
  public func move(_ source: String, to destination: String, directory: Bool, replace: Bool) async throws {
    guard !source.isEmpty, !destination.isEmpty else { throw MobileError.invalidName }
    let from = try address.path(source), to = try address.path(destination)
    try await session { sftp in
      _ = try await checkedStat(from, sftp: sftp)
      _ = try await checkedStat((to as NSString).deletingLastPathComponent, sftp: sftp)
      if try await optionalStat(to, sftp: sftp) != nil {
        guard replace, !directory else { throw VaultCoreError.exists }
        try await sftp.posixRename(at: from, to: to)
      } else { try await sftp.rename(at: from, to: to) }
    }
  }
  public func delete(_ path: String, directory: Bool) async throws {
    guard !path.isEmpty else { throw MobileError.invalidName }
    let full = try address.path(path)
    try await session { sftp in
      guard try await checkedStat(full, sftp: sftp).isDirectory == directory else { throw MobileError.unsupported }
      if directory { try await sftp.rmdir(at: full) } else { try await sftp.remove(at: full) }
    }
  }
}
