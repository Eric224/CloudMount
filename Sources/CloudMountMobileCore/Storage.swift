import Darwin
import Foundation
import Security

public protocol MobileSecrets: Sendable {
  func read(_ key: String) throws -> Data?
  func save(_ value: Data, key: String) throws
  func remove(_ key: String) throws
}
public struct MobileKeychain: MobileSecrets {
  let accessGroup: String?
  public init(accessGroup: String? = nil) { self.accessGroup = accessGroup }
  private func query(_ key: String) -> [String: Any] {
    var result: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.codex.cloudmount.mobile", kSecAttrAccount as String: key,
    ]
    if let accessGroup { result[kSecAttrAccessGroup as String] = accessGroup }
    return result
  }
  public func read(_ key: String) throws -> Data? {
    var q = query(key)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var value: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &value)
    if status == errSecItemNotFound { return nil }
    if status == errSecInteractionNotAllowed || status == errSecNotAvailable { throw MobileError.deviceLocked }
    guard status == errSecSuccess else { throw MobileError.credential }
    return value as? Data
  }
  public func save(_ value: Data, key: String) throws {
    let q = query(key)
    let attributes: [String: Any] = [
      kSecValueData as String: value,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    var status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(q.merging(attributes) { _, b in b } as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw MobileError.credential }
  }
  public func remove(_ key: String) throws {
    let status = SecItemDelete(query(key) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw MobileError.credential
    }
  }
}

/// File locks cover complete operations, including their await points, across
/// app, provider, and authentication-extension processes. No main-thread waits.
public final class MobileLease: @unchecked Sendable {
  private let descriptor: Int32
  init(_ descriptor: Int32) { self.descriptor = descriptor }
  deinit {
    flock(descriptor, LOCK_UN)
    close(descriptor)
  }
}
public struct MobileRepository: Sendable {
  public let root: URL
  public init(root: URL) throws {
    self.root = root
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var value = root
    var resources = URLResourceValues()
    resources.isExcludedFromBackup = true
    try value.setResourceValues(resources)
    #if os(iOS)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.complete], ofItemAtPath: root.path)
    #endif
  }
  public func lease(_ name: String, timeout: TimeInterval = 30) async throws -> MobileLease {
    guard name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
      throw MobileError.invalidName
    }
    let path = root.appendingPathComponent(name + ".lock").path
    let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw MobileError.busy }
    let deadline = Date().addingTimeInterval(timeout)
    do {
      while flock(fd, LOCK_EX | LOCK_NB) != 0 {
        guard errno == EWOULDBLOCK, Date() < deadline else { throw MobileError.busy }
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      try Task.checkCancellation()
      return MobileLease(fd)
    } catch {
      close(fd)
      throw error
    }
  }
  public func read<T: Decodable>(_ name: String, default fallback: T) throws -> T {
    let url = try file(name)
    guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
    let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max
    guard size < 32 * 1_048_576 else { throw MobileError.incomplete }
    let data = try Data(contentsOf: url)
    guard data.count < 32 * 1_048_576 else { throw MobileError.incomplete }
    return try JSONDecoder().decode(T.self, from: data)
  }
  public func write<T: Encodable>(_ value: T, name: String) throws {
    let url = try file(name)
    let data = try JSONEncoder().encode(value)
    guard data.count < 32 * 1_048_576 else { throw MobileError.incomplete }
    try data.write(to: url, options: [.atomic])
    try protect(url)
  }
  public func file(_ name: String) throws -> URL {
    guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else {
      throw MobileError.invalidName
    }
    return root.appendingPathComponent(name, isDirectory: false)
  }
  public func protect(_ file: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    #if os(iOS)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
    #endif
    var value = file
    var resources = URLResourceValues()
    resources.isExcludedFromBackup = true
    try value.setResourceValues(resources)
  }
  public func configuration() throws -> MobileConfiguration {
    try read("configuration.json", default: MobileConfiguration())
  }
  public func catalog(_ id: UUID) throws -> MobileCatalog {
    try read("catalog-\(id).json", default: MobileCatalog())
  }
  public func saveCatalog(_ value: MobileCatalog, id: UUID) throws {
    try write(value, name: "catalog-\(id).json")
  }
  public func pending(_ id: UUID) throws -> [MobilePendingWrite] {
    try read("pending-\(id).json", default: [MobilePendingWrite]())
  }
  public func savePending(_ value: [MobilePendingWrite], id: UUID) throws {
    try write(value, name: "pending-\(id).json")
  }
}
