import CloudMountVaultCore
import Foundation
import XCTest

@testable import CloudMountMobileCore

final class DrimeIntegrationTests: XCTestCase {
  struct Fixture {
    let root: URL, repository: MobileRepository, connection: MobileConnection, plain: MobileLocation
    let store: DrimeStore, service: MobileService, keys: TestSecrets, prefix: String
    func anotherStore() throws -> DrimeStore {
      try DrimeStore(
        token: "isolated-drime-token", settings: DrimeSettings(), repository: repository,
        connectionID: connection.id, endpoint: URL(string: "http://127.0.0.1:19470/api/v1/")!,
        testing: true)
    }
  }
  func control(_ values: [String: Any] = [:]) async throws {
    var r = URLRequest(url: URL(string: "http://127.0.0.1:19470/__control")!)
    r.httpMethod = "POST"
    r.httpBody = try JSONSerialization.data(withJSONObject: values)
    let (_, response) = try await URLSession.shared.data(for: r)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
  }
  func fixture() async throws -> Fixture {
    guard ProcessInfo.processInfo.environment["CLOUDMOUNT_RUN_DRIME_TESTS"] == "1" else {
      throw XCTSkip("Opt in to loopback-only Drime REST fixture")
    }
    try await control()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "cloudmount-drime-test-" + UUID().uuidString)
    let repository = try MobileRepository(root: root)
    let connection = MobileConnection(
      name: "Drime fixture", endpoint: DrimeStore.endpoint, username: "", drime: DrimeSettings())
    let store = try DrimeStore(
      token: "isolated-drime-token", settings: DrimeSettings(), repository: repository,
      connectionID: connection.id,
      endpoint: URL(string: "http://127.0.0.1:19470/api/v1/")!, testing: true)
    let prefix = "isolated-" + UUID().uuidString
    try await store.mkdir(prefix)
    let keys = TestSecrets()
    let plain = MobileLocation(connectionID: connection.id, name: "Drime fixture", path: prefix)
    var config = MobileConfiguration()
    config.connections = [connection]
    config.locations = [plain]
    try repository.write(config, name: "configuration.json")
    let service = MobileService(repository: repository, secrets: keys, storeFactory: { _ in store })
    return Fixture(
      root: root, repository: repository, connection: connection, plain: plain, store: store,
      service: service, keys: keys, prefix: prefix)
  }
  func testUnicodeCrudMoveOverwriteAndConditionalConflict() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let input = f.root.appendingPathComponent("source")
    let path = f.prefix + "/私人文件 📁.txt"
    try Data("initial".utf8).write(to: input)
    try await f.store.put(input, path: path, expected: nil, requireNew: true)
    let old = try await f.store.stat(path)
    try Data("modified".utf8).write(to: input)
    try await f.store.put(input, path: path, expected: old.version, requireNew: false)
    let bytes = try await f.store.read(path, limit: 100)
    XCTAssertEqual(bytes, Data("modified".utf8))
    do {
      try await f.store.put(input, path: path, expected: old.version, requireNew: false)
      XCTFail("Stale revision")
    } catch MobileError.conflict {}
    do {
      try await f.store.put(input, path: path, expected: nil, requireNew: true)
      XCTFail("Create must not overwrite")
    } catch MobileError.conflict {}
    try await f.store.mkdir(f.prefix + "/另一層")
    try await f.store.move(path, to: f.prefix + "/另一層/改名.txt", directory: false, replace: false)
    try await f.store.move(
      f.prefix + "/另一層", to: f.prefix + "/新資料夾", directory: true, replace: false)
    let listed = try await f.store.list(f.prefix + "/新資料夾")
    XCTAssertEqual(listed.map(\.name), ["改名.txt"])
    try await f.store.delete(f.prefix + "/新資料夾/改名.txt", directory: false)
    try await f.store.delete(f.prefix + "/新資料夾", directory: true)
  }
  func testLocalized422OnlyAcceptedAfterConfirmedDeletion() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let input = f.root.appendingPathComponent("source")
    let path = f.prefix + "/file.txt"
    try Data("one".utf8).write(to: input)
    try await f.store.upload(input, to: path)
    try await control(["deleteMode": "422-present"])
    do {
      try await f.store.delete(path, directory: false)
      XCTFail("422 cannot imply success")
    } catch MobileError.network(let code) { XCTAssertEqual(code, 422) }
    let kept = try await f.store.read(path, limit: 100)
    XCTAssertEqual(kept, Data("one".utf8))
    try await control(["deleteMode": "422-absent"])
    try await f.store.delete(path, directory: false)
    let listed = try await f.store.list(f.prefix)
    XCTAssertTrue(listed.isEmpty)
  }
  func testCommittedReplacementIsNotReuploadedWhenOldCleanupFails() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let input = f.root.appendingPathComponent("source")
    let path = f.prefix + "/file.txt"
    try Data("one".utf8).write(to: input)
    try await f.store.upload(input, to: path)
    try await control(["deleteMode": "422-present"])
    try Data("two".utf8).write(to: input)
    try await f.store.upload(input, to: path)
    let kept = try await f.store.read(path, limit: 100)
    XCTAssertEqual(kept, Data("two".utf8))
    let visible = try await f.store.list(f.prefix)
    XCTAssertEqual(visible.map(\.name), ["file.txt"])
    try await control()
    try Data("three".utf8).write(to: input)
    try await f.anotherStore().upload(input, to: path)
    let final = try await f.store.list(f.prefix)
    XCTAssertEqual(final.map(\.name), ["file.txt"])
  }
  func testInterruptedOverwriteKeepsOriginalAndResumesFromPersistedPlan() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let input = f.root.appendingPathComponent("source")
    let path = f.prefix + "/file.txt"
    try Data("original".utf8).write(to: input)
    try await f.store.upload(input, to: path)
    let old = try await f.store.stat(path)
    try Data("replacement".utf8).write(to: input)
    try await control(["failFinalRename": true])
    do {
      try await f.store.put(input, path: path, expected: old.version, requireNew: false)
      XCTFail("Interrupted commit")
    } catch MobileError.network(503) {}
    let journal = try String(
      contentsOf: try f.repository.file("drime-\(f.connection.id).json"), encoding: .utf8)
    XCTAssertTrue(journal.contains(".cloudmount-previous-"))
    XCTAssertFalse(journal.contains("isolated-drime-token"))
    try await f.anotherStore().put(input, path: path, expected: old.version, requireNew: false)
    let result = try await f.store.read(path, limit: 100)
    XCTAssertEqual(result, Data("replacement".utf8))
  }
  func testLostUploadAndRenameRepliesRecoverWithoutDuplicateNames() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let input = f.root.appendingPathComponent("source")
    let path = f.prefix + "/file.txt"
    try Data("reply-lost".utf8).write(to: input)
    try await control(["uploadReplyLostOnce": true])
    do {
      try await f.store.put(input, path: path, expected: nil, requireNew: true)
      XCTFail("Ambiguous upload")
    } catch MobileError.network(503) {}
    try await f.anotherStore().put(input, path: path, expected: nil, requireNew: true)
    try await control(["renameReplyLostOnce": true])
    let renamed = f.prefix + "/renamed.txt"
    do {
      try await f.store.move(path, to: renamed, directory: false, replace: false)
      XCTFail("Ambiguous rename")
    } catch MobileError.network(503) {}
    try await f.anotherStore().move(path, to: renamed, directory: false, replace: false)
    let list = try await f.store.list(f.prefix)
    XCTAssertEqual(list.map(\.name), ["renamed.txt"])
  }
  func testIncompleteAndWrongParentListingsFailClosed() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    for mode in ["incomplete", "bad-parent"] {
      try await control(["listing": mode])
      do {
        _ = try await f.store.list("")
        XCTFail("Malformed listing cannot become authoritative")
      } catch MobileError.incomplete {}
    }
  }
  func testMultipartUsesUnsignedStorageRequestsAndRetriesFailedSession() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let input = f.root.appendingPathComponent("source")
    let path = f.prefix + "/large.bin"
    let data = Data(repeating: 0x6a, count: 6_000_001)
    try data.write(to: input)
    try await control(["failPartOnce": true])
    do {
      try await f.store.upload(input, to: path)
      XCTFail("Fail one part")
    } catch MobileError.network(503) {}
    try await f.anotherStore().upload(input, to: path)
    let output = f.root.appendingPathComponent("output")
    try await f.store.download(path, to: output)
    XCTAssertEqual(try Data(contentsOf: output), data)
  }
  func testStandardVaultCrossDeviceImportEditRecoveryLockDeleteRestore() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let (vault, words) = try await f.service.createVault(
      connectionID: f.connection.id, parent: f.prefix, name: "私人保險庫 中文",
      password: "shared-long-fixture-password", remember: true)
    XCTAssertEqual(words.split(separator: " ").count, 44)
    let input = f.root.appendingPathComponent("source")
    let output = f.root.appendingPathComponent("output")
    try Data("private original".utf8).write(to: input)
    let original = try await f.service.create(
      parent: "root", name: "秘密.txt", directory: false, contents: input,
      requestID: UUID().uuidString, location: vault.id)
    let repo2 = try MobileRepository(root: f.root.appendingPathComponent("device-two"))
    let keys2 = TestSecrets()
    var config = MobileConfiguration()
    config.connections = [f.connection]
    try repo2.write(config, name: "configuration.json")
    let store2 = try DrimeStore(
      token: "isolated-drime-token", settings: DrimeSettings(), repository: repo2,
      connectionID: f.connection.id, endpoint: URL(string: "http://127.0.0.1:19470/api/v1/")!,
      testing: true)
    let service2 = MobileService(repository: repo2, secrets: keys2, storeFactory: { _ in store2 })
    let discovered = try await service2.discover(connectionID: f.connection.id, parent: f.prefix)
    XCTAssertTrue(discovered.contains { $0.path == vault.path })
    let imported = try await service2.importVault(
      connectionID: f.connection.id, path: vault.path, password: "shared-long-fixture-password",
      remember: false)
    let items = try await service2.list("root", location: imported.id)
    let item = try XCTUnwrap(items.first { $0.name == "秘密.txt" })
    _ = try await service2.download(item.id, location: imported.id, to: output)
    XCTAssertEqual(try Data(contentsOf: output), Data("private original".utf8))
    try Data("edited on second device".utf8).write(to: input)
    _ = try await service2.modify(
      item.id, parent: nil, name: nil, contents: input, expected: item.version,
      location: imported.id)
    _ = try await f.service.list("root", location: vault.id)
    _ = try await f.service.download(original.id, location: vault.id, to: output)
    XCTAssertEqual(try Data(contentsOf: output), Data("edited on second device".utf8))
    let ciphertextNames = try await f.store.list(vault.path)
    XCTAssertFalse(ciphertextNames.contains { $0.name == "秘密.txt" })
    try await service2.lock(imported.id)
    try await f.service.lock(vault.id)
    XCTAssertFalse(try f.service.isUnlocked(vault.id))
    try await f.service.unlock(vault.id, password: nil)
    let exported = try await f.service.recovery(vault.id)
    XCTAssertEqual(exported, words)
    try await f.service.lock(vault.id)
    try await f.service.trashVault(vault.id)
    try await f.service.restoreVault(vault.id)
    try await f.service.unlock(vault.id, password: "shared-long-fixture-password")
    let restored = try await f.service.list("root", location: vault.id)
    XCTAssertEqual(restored.map(\.name), ["秘密.txt"])
  }
  func testOldConnectionsDecodeWithoutDrimeAndRejectUnsafeSecrets() throws {
    let bytes = Data(
      "{\"id\":\"\(UUID())\",\"name\":\"NAS\",\"endpoint\":\"https://nas.example.com/\",\"username\":\"user\"}"
        .utf8)
    let decoded = try JSONDecoder().decode(MobileConnection.self, from: bytes)
    XCTAssertNil(decoded.drime)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "cloudmount-drime-input-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try MobileRepository(root: root)
    for token in ["", "header\r\ninjection", "a b"] {
      XCTAssertThrowsError(try DrimeStore(token: token, repository: repo, connectionID: UUID()))
    }
    XCTAssertThrowsError(
      try DrimeStore(
        token: "valid", settings: DrimeSettings(workspaceID: -1), repository: repo,
        connectionID: UUID()))
  }
  func testVaultRetryWithFreshCiphertextDoesNotBlockAllFutureWrites() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let input = f.root.appendingPathComponent("source")
    try Data("first encryption nonce".utf8).write(to: input)
    try await control(["uploadReplyLostOnce": true])
    do {
      try await f.store.upload(input, to: f.prefix + "/old-staging.tmp")
      XCTFail("Reply lost")
    } catch MobileError.network(503) {}
    try Data("second encryption nonce".utf8).write(to: input)
    try await f.anotherStore().upload(input, to: f.prefix + "/new-staging.tmp")
    let result = try await f.store.list(f.prefix)
    XCTAssertEqual(result.map(\.name), ["new-staging.tmp"])
  }
  func testIntegrityMismatchRetainsOldFileAndFallbackStripsTokenOnRedirect() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let input = f.root.appendingPathComponent("source")
    let path = f.prefix + "/file.txt"
    try Data("original".utf8).write(to: input)
    try await f.store.upload(input, to: path)
    try Data("replacement".utf8).write(to: input)
    try await control(["corruptIntegrity": true])
    do {
      try await f.store.upload(input, to: path)
      XCTFail("Hash mismatch must not replace")
    } catch MobileError.incomplete {}
    let old = try await f.store.read(path, limit: 100)
    XCTAssertEqual(old, Data("original".utf8))
    try await control(["noIntegrityEndpoint": true, "redirectDownload": true])
    try await f.anotherStore().upload(input, to: path)
    let final = try await f.store.read(path, limit: 100)
    XCTAssertEqual(final, Data("replacement".utf8))
  }
  func testPaginationScopedRootAndAccountTokenMismatch() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try await f.store.mkdir(f.prefix + "/A")
    try await f.store.mkdir(f.prefix + "/B")
    let root = try await f.store.stat(f.prefix)
    let id = try XCTUnwrap(Int64(root.version.split(separator: ":")[0]))
    let scoped = try DrimeStore(
      token: "isolated-drime-token", settings: DrimeSettings(rootFolderID: id, accountID: 123),
      repository: f.repository, connectionID: UUID(),
      endpoint: URL(string: "http://127.0.0.1:19470/api/v1/")!, testing: true)
    let account = try await scoped.accountID()
    XCTAssertEqual(account, 123)
    try await control(["listing": "paginate"])
    let names = try await scoped.list("").map(\.name)
    XCTAssertEqual(Set(names), Set(["A", "B"]))
    let wrong = try DrimeStore(
      token: "isolated-drime-token", settings: DrimeSettings(accountID: 999),
      repository: f.repository, connectionID: UUID(),
      endpoint: URL(string: "http://127.0.0.1:19470/api/v1/")!, testing: true)
    do {
      _ = try await wrong.accountID()
      XCTFail("Do not replace credentials with another account")
    } catch MobileError.credential {}
  }
  func testFailedMultipartAbortIsRetainedWithoutBlockingNewCommittedFile() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let input = f.root.appendingPathComponent("source")
    let path = f.prefix + "/large.bin"
    try Data(repeating: 0x3b, count: 5_300_000).write(to: input)
    try await control(["failPartOnce": true])
    do {
      try await f.store.upload(input, to: path)
      XCTFail("Fail part")
    } catch MobileError.network(503) {}
    try await control(["abortFails": true])
    try await f.anotherStore().upload(input, to: path)
    let status = try DrimeStore.maintenanceStatus(
      repository: f.repository, connectionID: f.connection.id)
    XCTAssertEqual(status.pendingMultipartSessions, 1)
    XCTAssertFalse(status.interruptedOperation)
    try await control()
    try await f.store.retryMaintenance()
    let clean = try DrimeStore.maintenanceStatus(
      repository: f.repository, connectionID: f.connection.id)
    XCTAssertEqual(clean.pendingMultipartSessions, 0)
  }
}
