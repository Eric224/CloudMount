import CloudMountVaultCore
import Foundation
import XCTest

@testable import CloudMountMobileCore

final class WebDAVIntegrationTests: XCTestCase {
  func testNativeDavCryptomatorUnicodeAndConditionalOverwrite() async throws {
    guard ProcessInfo.processInfo.environment["CLOUDMOUNT_RUN_LOCAL_DAV_TESTS"] == "1" else {
      throw XCTSkip("Start Mobile/Testing/dav-fixture.py on loopback port 19464 before opting in")
    }
    let base = try WebDAVStore(
      endpoint: URL(string: "http://127.0.0.1:19464/home/")!, username: "test", password: "test",
      allowLoopbackHTTP: true)
    let path = "mobile-" + UUID().uuidString
    try await base.mkdir(path)
    try await base.mkdir(path) // Existing collections must be idempotent.
    let raced = "race-created-" + UUID().uuidString
    try await base.mkdir(raced)
    try await base.delete(raced,directory:true)
    let store = try PrefixedCiphertextStore(store: base, prefix: path)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mobile-dav-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    try Data("first".utf8).write(to: source)
    try await base.put(source, path: path + "/plain.txt", expected: nil, requireNew: true)
    let original = try await base.stat(path + "/plain.txt")
    // The transport must reconcile an error after a committed MOVE, but must
    // never acknowledge a lying success response that left the source intact.
    if ProcessInfo.processInfo.environment["CLOUDMOUNT_DAV_MOVE_FAILURE_FIXTURE"] == "1" {
      do {
        try await base.move(path+"/plain.txt",to:path+"/reject-noop-file",directory:false,replace:false)
        XCTFail("A no-op success must not be acknowledged")
      } catch MobileError.conflict {}
      let preserved = try await base.stat(path+"/plain.txt")
      XCTAssertEqual(preserved.version,original.version)
    }

    try Data("other".utf8).write(to: source)
    try await base.put(
      source, path: path + "/plain.txt", expected: original.version, requireNew: false)
    do {
      try await base.put(
        source, path: path + "/plain.txt", expected: original.version, requireNew: false)
      XCTFail("Stale ETag must fail")
    } catch MobileError.conflict {}
    if ProcessInfo.processInfo.environment["CLOUDMOUNT_DAV_MOVE_FAILURE_FIXTURE"] == "1" {
      let raced = path+"/race-replace-file.txt"
      try await base.put(source,path:raced,expected:nil,requireNew:true)
      let version = try await base.stat(raced).version
      do {
        try await base.put(source,path:raced,expected:version,requireNew:false)
        XCTFail("Destination changed during staging; conditional MOVE must reject it")
      } catch MobileError.conflict {}
      let bytes = try await base.read(raced,limit:1024)
      XCTAssertEqual(bytes,Data("external-update".utf8))
    }
    let (descriptor, key) = try VaultDescriptor.create(password: "a-long-test-password")
    let fs = try VaultFileSystem(
      store: store, descriptor: descriptor, rawKey: key,
      scratch: root.appendingPathComponent("scratch"))
    try await fs.initialize()
    try await fs.mkdir("中文目錄")
    try await fs.upload(source, to: "中文目錄/秘密.txt", requireNew: true)
    let first = try await fs.stat("中文目錄/秘密.txt")
    try Data("third".utf8).write(to: source)
    try await fs.upload(source, to: "中文目錄/秘密.txt", expectedVersion: first.version)
    let decoded = root.appendingPathComponent("decoded")
    _ = try await fs.download("中文目錄/秘密.txt", to: decoded)
    XCTAssertEqual(try String(contentsOf: decoded, encoding: .utf8), "third")
    try await fs.move("中文目錄/秘密.txt", to: "中文目錄/moved.txt", replace: false)
    let list = try await fs.list("中文目錄")
    XCTAssertEqual(list.map(\.name), ["moved.txt"])
    try await fs.delete("中文目錄/moved.txt")
    try await fs.delete("中文目錄")
    // Remove only this fixture's known descendants, including Cryptomator's
    // directory-ID backups; never recursively delete a configured account.
    func removeTree(_ p: String) async throws {
      for value in try await base.list(p) {
        let child = try MobilePath.join(p, value.name)
        if value.isDirectory {
          try await removeTree(child)
        } else {
          try await base.delete(child, directory: false)
        }
      }
      try await base.delete(p, directory: true)
    }
    try await removeTree(path)
  }
}
