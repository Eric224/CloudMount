import CloudMountVaultCore
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct MobileBrowsingPolicy: Codable, Sendable {
  public var thumbnailsEnabled = true
  public var maximumMB = 64
  public var retentionDays = 7
  public init() {}
  var safeMB: Int { max(16, min(maximumMB, 128)) }
  var safeDays: Int { max(1, min(retentionDays, 30)) }
}

/// Contains disposable previews only. Pending uploads and materialized Files
/// documents are outside this directory and are never touched by cleanup.
struct MobileThumbnailCache {
  let repository: MobileRepository
  let policy: MobileBrowsingPolicy
  private struct Entry: Codable { let created: Date; let jpeg: Data }
  static func key(location: UUID, node: MobileNode, pixels: Int, vault: Bool) -> String {
    let context = ["thumbnail-v1", location.uuidString, node.id, node.path, node.version,
      String(node.size), String(node.modified.timeIntervalSince1970), String(pixels), String(vault)]
    return S3Signature.hex(SHA256.hash(data: Data(context.joined(separator: "\u{0}").utf8)))
  }
  static func encryptionKey(raw: Data, location: UUID) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: raw), salt: Data(location.uuidString.utf8),
      info: Data("CloudMount local thumbnail cache v1".utf8), outputByteCount: 32)
  }
  private func directory() throws -> URL {
    let url = try repository.file("preview-cache-v1")
    if FileManager.default.fileExists(atPath: url.path) {
      guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory else { throw MobileError.incomplete }
    } else {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    try repository.protect(url)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
  }
  private func file(_ key: String) throws -> URL {
    guard key.utf8.count == 64, key.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw MobileError.incomplete }
    return try directory().appendingPathComponent(key + ".thumb")
  }
  func read(_ key: String, encryptionKey: SymmetricKey?, now: Date = Date()) throws -> (data: Data, fresh: Bool)? {
    let url = try file(key)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attrs[.type] as? FileAttributeType == .typeRegular,
      let size = (attrs[.size] as? NSNumber)?.intValue, size <= 800_000 else { return nil }
    let stored = try Data(contentsOf: url)
    let bytes: Data
    if let encryptionKey {
      guard let box = try? AES.GCM.SealedBox(combined: stored),
        let clear = try? AES.GCM.open(box, using: encryptionKey, authenticating: Data(key.utf8)) else { return nil }
      bytes = clear
    } else { bytes = stored }
    guard let entry = try? JSONDecoder().decode(Entry.self, from: bytes), entry.jpeg.count <= 524_288 else { return nil }
    let age = now.timeIntervalSince(entry.created)
    let idle = now.timeIntervalSince(attrs[.modificationDate] as? Date ?? .distantPast)
    guard age >= 0, idle >= 0, idle < Double(policy.safeDays * 86_400) else { return nil }
    try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
    return (entry.jpeg, age < 60)
  }
  func save(_ jpeg: Data, key: String, encryptionKey: SymmetricKey?, now: Date = Date()) throws {
    guard jpeg.count <= 524_288 else { throw MobileError.incomplete }
    let clear = try JSONEncoder().encode(Entry(created: now, jpeg: jpeg))
    let stored: Data
    if let encryptionKey {
      guard let encrypted = try AES.GCM.seal(clear, using: encryptionKey, authenticating: Data(key.utf8)).combined else { throw MobileError.incomplete }
      stored = encrypted
    } else { stored = clear }
    let url = try file(key)
    try stored.write(to: url, options: .atomic)
    try repository.protect(url)
    try prune(now: now)
  }
  func prune(now: Date = Date(), all: Bool = false) throws {
    let root = try directory()
    let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    var files: [(URL, Int, Date)] = []
    for url in urls {
      guard url.pathExtension == "thumb", url.deletingPathExtension().lastPathComponent.count == 64,
        url.deletingPathExtension().lastPathComponent.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { continue }
      let a = try FileManager.default.attributesOfItem(atPath: url.path)
      guard a[.type] as? FileAttributeType == .typeRegular else { continue }
      files.append((url, (a[.size] as? NSNumber)?.intValue ?? 0, a[.modificationDate] as? Date ?? .distantPast))
    }
    var total = files.reduce(0) { $0 + $1.1 }, count = files.count
    for (url, size, accessed) in files.sorted(by: { $0.2 < $1.2 }) {
      if all || total > policy.safeMB * 1_048_576 || count > 512 || now.timeIntervalSince(accessed) > Double(policy.safeDays * 86_400) {
        try FileManager.default.removeItem(at: url); total -= size; count -= 1
      }
    }
  }
}

/// This adapter deliberately offers no writes. Even vault ciphertext downloads
/// must go through each transport's bounded read before reaching the decoder.
struct PreviewReadStore: CiphertextStore {
  let base: any CiphertextStore
  let limit: Int
  func stat(_ p: String) async throws -> CipherItem { try await base.stat(p) }
  func list(_ p: String) async throws -> [CipherItem] { try await base.list(p) }
  func read(_ p: String, limit: Int) async throws -> Data { try await base.read(p, limit: min(limit, self.limit)) }
  func download(_ p: String, to file: URL) async throws {
    let bytes = try await base.read(p, limit: limit)
    guard bytes.count <= limit else { throw MobileError.incomplete }
    try Task.checkCancellation()
    try bytes.write(to: file, options: .atomic)
    #if os(iOS)
    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
    #endif
  }
  func upload(_ file: URL, to p: String) async throws { throw MobileError.unsupported }
  func mkdir(_ p: String) async throws { throw MobileError.unsupported }
  func move(_ p: String, to q: String, directory: Bool, replace: Bool) async throws { throw MobileError.unsupported }
  func delete(_ p: String, directory: Bool) async throws { throw MobileError.unsupported }
}

enum MobileThumbnailRenderer {
  static let maximumSourceBytes: Int64 = 8_388_608
  static func pixels(_ size: Double) throws -> Int {
    guard size.isFinite, size > 0 else { throw MobileError.unsupported }
    return size <= 128 ? 128 : size <= 256 ? 256 : 512
  }
  static func supports(_ name: String) -> Bool {
    ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tif", "tiff", "bmp", "avif"].contains((name as NSString).pathExtension.lowercased())
  }
  static func render(_ file: URL, pixels: Int) throws -> Data? {
    try Task.checkCancellation()
    guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
      CGImageSourceGetCount(source) > 0,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0, width <= 20_000, height <= 20_000,
      Int64(width) * Int64(height) <= 60_000_000 else { return nil }
    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: pixels,
      kCGImageSourceShouldCacheImmediately: false, kCGImageSourceShouldCache: false]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    try Task.checkCancellation()
    let bytes = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
    guard CGImageDestinationFinalize(destination), bytes.length <= 524_288 else { return nil }
    return bytes as Data
  }
}
