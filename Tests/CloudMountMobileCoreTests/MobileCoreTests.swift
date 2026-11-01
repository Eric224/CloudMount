import CloudMountVaultCore
import Foundation
import XCTest

@testable import CloudMountMobileCore

final class TestSecrets: MobileSecrets, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Data] = [:]
  func read(_ key: String) -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return values[key]
  }
  func save(_ value: Data, key: String) {
    lock.lock()
    defer { lock.unlock() }
    values[key] = value
  }
  func remove(_ key: String) {
    lock.lock()
    defer { lock.unlock() }
    values[key] = nil
  }
}
actor FaultStore: CiphertextStore {
  let base: LocalCiphertextStore
  var failUpload = false, failList = false
  init(_ root: URL) { base = LocalCiphertextStore(root: root) }
  func setFailure(upload: Bool = false, list: Bool = false) {
    failUpload = upload
    failList = list
  }
  func stat(_ p: String) async throws -> CipherItem { try await base.stat(p) }
  func list(_ p: String) async throws -> [CipherItem] {
    if failList { throw MobileError.network(503) }
    return try await base.list(p)
  }
  func read(_ p: String, limit: Int) async throws -> Data { try await base.read(p, limit: limit) }
  func download(_ p: String, to f: URL) async throws { try await base.download(p, to: f) }
  func upload(_ f: URL, to p: String) async throws {
    if failUpload { throw MobileError.network(503) }
    try await base.upload(f, to: p)
  }
  func mkdir(_ p: String) async throws { try await base.mkdir(p) }
  func move(_ p: String, to q: String, directory: Bool, replace: Bool) async throws {
    try await base.move(p, to: q, directory: directory, replace: replace)
  }
  func delete(_ p: String, directory: Bool) async throws {
    try await base.delete(p, directory: directory)
  }
}
final class MobileCoreTests: XCTestCase {
  struct Fixture {
    let root: URL, cloud: URL, repository: MobileRepository, secrets: TestSecrets,
      service: MobileService, connection: MobileConnection, plain: MobileLocation, store: FaultStore
  }
  func fixture() throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "cloudmount-mobile-test-" + UUID().uuidString, isDirectory: true)
    let cloud = root.appendingPathComponent("cloud", isDirectory: true)
    try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
    let repo = try MobileRepository(root: root.appendingPathComponent("device", isDirectory: true))
    let keys = TestSecrets()
    let store = FaultStore(cloud)
    let connection = MobileConnection(
      name: "isolated fixture", endpoint: URL(string: "https://fixture.invalid/")!, username: "test"
    )
    let plain = MobileLocation(connectionID: connection.id, name: "fixture")
    var config = MobileConfiguration()
    config.connections = [connection]
    config.locations = [plain]
    try repo.write(config, name: "configuration.json")
    let service = MobileService(repository: repo, secrets: keys, storeFactory: { _ in store })
    return Fixture(
      root: root, cloud: cloud, repository: repo, secrets: keys, service: service,
      connection: connection, plain: plain, store: store)
  }
  func testStandardVaultCrossDeviceCrudLockRecoveryAndRecoverableDelete() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let (vault, recovery) = try await f.service.createVault(
      connectionID: f.connection.id, parent: "", name: "私人保險庫", password: "long-fixture-password",
      remember: true)
    XCTAssertEqual(recovery.split(separator: " ").count, 44)
    let disk = f.cloud.appendingPathComponent(vault.path)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: disk.appendingPathComponent("vault.cryptomator").path))
    let source = f.root.appendingPathComponent("source")
    try Data("private first content".utf8).write(to: source)
    let folder = try await f.service.create(
      parent: "root", name: "中文目錄", directory: true, contents: nil, requestID: "folder",
      location: vault.id)
    let first = try await f.service.create(
      parent: folder.id, name: "秘密.txt", directory: false, contents: source, requestID: "document",
      location: vault.id)
    let replay = try await f.service.create(
      parent: folder.id, name: "秘密.txt", directory: false, contents: source, requestID: "document",
      location: vault.id)
    XCTAssertEqual(first.id, replay.id)
    try Data("private other content".utf8).write(to: source)
    let edited = try await f.service.modify(
      first.id, parent: nil, name: nil, contents: source, expected: first.version,
      location: vault.id)
    let renamed = try await f.service.modify(
      first.id, parent: nil, name: "renamed.txt", contents: nil, expected: edited.version,
      location: vault.id)
    XCTAssertEqual(renamed.id, first.id)
    let moved = try await f.service.modify(
      folder.id, parent: nil, name: "新名稱", contents: nil, expected: folder.version,
      location: vault.id)
    XCTAssertEqual(moved.id, folder.id)
    let listed = try await f.service.list(folder.id, location: vault.id)
    XCTAssertEqual(listed.map(\.name), ["renamed.txt"])
    XCTAssertEqual(listed.first?.id, first.id)
    try await f.service.lock(vault.id)
    do {
      _ = try await f.service.list("root", location: vault.id)
      XCTFail("Locked vault must not enumerate")
    } catch MobileError.locked {}
    try await f.service.unlock(vault.id, password: nil)
    let file = f.root.appendingPathComponent("download")
    _ = try await f.service.download(first.id, location: vault.id, to: file)
    XCTAssertEqual(try Data(contentsOf: file), Data("private other content".utf8))
    let otherRepo = try MobileRepository(root: f.root.appendingPathComponent("other-device"))
    var otherConfig = MobileConfiguration()
    otherConfig.connections = [f.connection]
    try otherRepo.write(otherConfig, name: "configuration.json")
    let other = MobileService(
      repository: otherRepo, secrets: TestSecrets(), storeFactory: { _ in f.store })
    let found = try await other.discover(connectionID: f.connection.id, parent: "")
    XCTAssertEqual(found.first?.path, "私人保險庫")
    let imported = try await other.importVault(
      connectionID: f.connection.id, path: vault.path, password: "long-fixture-password",
      remember: false)
    let otherFolders = try await other.list("root", location: imported.id)
    let children = try await other.list(try XCTUnwrap(otherFolders.first).id, location: imported.id)
    let otherFile = f.root.appendingPathComponent("other-download")
    _ = try await other.download(
      try XCTUnwrap(children.first).id, location: imported.id, to: otherFile)
    XCTAssertEqual(try Data(contentsOf: otherFile), try Data(contentsOf: source))
    try await other.lock(imported.id)
    try await f.service.delete(folder.id, expected: nil, recursive: true, location: vault.id)
    let empty = try await f.service.list("root", location: vault.id)
    XCTAssertTrue(empty.isEmpty)
    try await f.service.lock(vault.id)
    try await f.service.trashVault(vault.id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: disk.path))
    try await f.service.restoreVault(vault.id)
    XCTAssertTrue(FileManager.default.fileExists(atPath: disk.path))
    try await f.service.unlock(vault.id, password: "long-fixture-password")
  }
  func testFailedUploadPreservesEditBlocksLockAndRecovers() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let (vault, _) = try await f.service.createVault(
      connectionID: f.connection.id, parent: "", name: "vault", password: "long-fixture-password",
      remember: false)
    let source = f.root.appendingPathComponent("source")
    try Data("must survive failed upload".utf8).write(to: source)
    await f.store.setFailure(upload: true)
    do {
      _ = try await f.service.create(
        parent: "root", name: "edit.txt", directory: false, contents: source, requestID: "new-edit",
        location: vault.id)
      XCTFail("Expected an upload failure")
    } catch MobileError.network(503) {}
    do {
      _ = try await f.service.create(
        parent: "root", name: "edit.txt", directory: false, contents: source, requestID: "new-edit",
        location: vault.id)
      XCTFail("Repeated failure must preserve a single operation")
    } catch MobileError.network(503) {}
    let pending = try f.repository.pending(vault.id)
    XCTAssertEqual(pending.count, 1)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: try f.repository.file("upload-" + pending[0].id).path))
    do {
      try await f.service.lock(vault.id)
      XCTFail("Unsent data must prevent safe lock")
    } catch MobileError.busy {}
    await f.store.setFailure()
    try await f.service.retryPending(vault.id)
    XCTAssertTrue(try f.repository.pending(vault.id).isEmpty)
    let list = try await f.service.list("root", location: vault.id)
    XCTAssertEqual(list.first?.id, "new-edit")
    let replay = try await f.service.create(
      parent: "root", name: "edit.txt", directory: false, contents: source, requestID: "new-edit",
      location: vault.id)
    XCTAssertEqual(replay.id, "new-edit")
    let file = f.root.appendingPathComponent("recovered")
    _ = try await f.service.download(try XCTUnwrap(list.first).id, location: vault.id, to: file)
    XCTAssertEqual(try Data(contentsOf: file), try Data(contentsOf: source))
    try await f.service.lock(vault.id)
  }
  func testFailedListingNeverGeneratesDeletionEventsAndConflictPreservesSource() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let source = f.root.appendingPathComponent("source")
    try Data("before".utf8).write(to: source)
    let node = try await f.service.create(
      parent: "root", name: "file.txt", directory: false, contents: source, requestID: "stable-id",
      location: f.plain.id)
    _ = try await f.service.list("root", location: f.plain.id)
    let before = try f.repository.catalog(f.plain.id)
    await f.store.setFailure(list: true)
    do {
      _ = try await f.service.list("root", location: f.plain.id)
      XCTFail("Expected failed listing")
    } catch MobileError.network(503) {}
    XCTAssertEqual(try f.repository.catalog(f.plain.id).generation, before.generation)
    XCTAssertNotNil(try f.repository.catalog(f.plain.id).nodes[node.id])
    await f.store.setFailure()
    try Data("remote edit".utf8).write(to: f.cloud.appendingPathComponent("file.txt"))
    try Data("local edit".utf8).write(to: source)
    do {
      _ = try await f.service.modify(
        node.id, parent: nil, name: nil, contents: source, expected: node.version,
        location: f.plain.id)
      XCTFail("Conflict must not overwrite")
    } catch MobileError.conflict {}
    XCTAssertEqual(
      try String(contentsOf: f.cloud.appendingPathComponent("file.txt"), encoding: .utf8),
      "remote edit")
    XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "local edit")
  }
  func testCrossProcessStyleLeaseExcludesReentrantMutations() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let lease = try await f.repository.lease("same")
    do {
      _ = try await f.repository.lease("same", timeout: 0.2)
      XCTFail("Lease must serialize across awaits")
    } catch MobileError.busy {}
    withExtendedLifetime(lease) {}
  }
  func testPathAndCredentialTransportRestrictions() throws {
    for path in ["../other", "/absolute", "a/../../b", "a\\b", "a//b", "a/./b", "a\u{0}b"] {
      XCTAssertThrowsError(try MobilePath.checked(path))
    }
    for endpoint in [
      "http://nas.example.com/", "https://user:pass@example.com/",
      "https://example.com/?token=secret", "file:///tmp",
    ] {
      XCTAssertThrowsError(
        try WebDAVStore(endpoint: URL(string: endpoint)!, username: "x", password: "y"))
    }
    XCTAssertEqual(try MobilePath.join("folder", " e\u{301}.txt "), "folder/ e\u{301}.txt ")
    XCTAssertNoThrow(
      try WebDAVStore(
        endpoint: URL(string: "https://nas.example.com:5006/home/")!, username: "user",
        password: "password"))
  }
}
