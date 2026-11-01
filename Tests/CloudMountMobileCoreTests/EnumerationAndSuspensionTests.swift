import CloudMountVaultCore
import Foundation
import XCTest

@testable import CloudMountMobileCore

final class EnumerationAndSuspensionTests: XCTestCase {
  func testThousandsOfItemsArePagedWithoutDuplicatesAndSnapshotsAreReleased() async throws {
    let pages = MobileEnumerationPages()
    let nodes = (0..<6490).map {
      MobileNode(
        id: String($0), parent: "root", path: String($0), name: String($0), directory: false,
        size: 1, modified: .distantPast, version: "v1")
    }
    var page = try await pages.start(nodes, size: 99999)
    var ids = [String]()
    var firstToken: String?
    while true {
      XCTAssertLessThanOrEqual(page.nodes.count, 200)
      ids += page.nodes.map(\.id)
      guard let next = page.next else { break }
      firstToken = firstToken ?? next
      page = try await pages.next(next, size: 200)
    }
    XCTAssertEqual(ids, nodes.map(\.id))
    XCTAssertEqual(Set(ids).count, nodes.count)
    do {
      _ = try await pages.next(firstToken!, size: 200)
      XCTFail("Finished snapshots must be released")
    } catch MobileError.expiredPage {}
    for bad in ["", "../secret", UUID().uuidString + ":9223372036854775807"] {
      do {
        _ = try await pages.next(bad, size: 200)
        XCTFail("Invalid token")
      } catch MobileError.expiredPage {}
    }
    let outstanding = try await pages.start(nodes, size: 1)
    await pages.invalidate()
    do {
      _ = try await pages.next(outstanding.next!, size: 1)
      XCTFail("Invalidated snapshots must be released")
    } catch MobileError.expiredPage {}
  }
  func testCachedCatalogRemainsReadableOfflineButNeverUnlocksALockedVault() async throws {
    let f = try MobileCoreTests().fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let (vault, _) = try await f.service.createVault(
      connectionID: f.connection.id, parent: "", name: "vault", password: "long-test-password",
      remember: false)
    let created = try await f.service.create(
      parent: "root", name: "folder", directory: true, contents: nil, requestID: "folder",
      location: vault.id)
    await f.store.setFailure(list: true)
    let cached = try await f.service.catalog(vault.id)
    XCTAssertNotNil(cached.nodes[created.id])
    try await f.service.recordProviderFailure(.offline, location: vault.id)
    _ = try await f.service.catalog(vault.id)
    XCTAssertEqual(
      try f.service.providerHealth(vault.id)?.issue, .offline,
      "Cache is not evidence of a successful remote connection")
    try await f.service.lock(vault.id)
    do {
      _ = try await f.service.catalog(vault.id)
      XCTFail("A working-set snapshot must not grant access after lock")
    } catch MobileError.locked {}
  }
  func testSuspendAndResumeRetainConfigurationCredentialsCatalogAndCloudData() async throws {
    let f = try MobileCoreTests().fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    f.secrets.save(Data("credential".utf8), key: "connection-\(f.connection.id)")
    let file = f.cloud.appendingPathComponent("preserve.txt")
    try Data("original".utf8).write(to: file)
    _ = try await f.service.list("root", location: f.plain.id)
    let before = try f.repository.catalog(f.plain.id)
    do {
      try await f.service.setLocationSuspended(f.plain.id, suspended: true) { _ in
        throw MobileError.busy
      }
      XCTFail("A failed OS drain must not mark the location suspended")
    } catch MobileError.busy {}
    XCTAssertNotEqual(try f.repository.configuration().locations[0].suspended, true)
    try await f.service.setLocationSuspended(f.plain.id, suspended: true)
    XCTAssertEqual(try f.repository.configuration().locations[0].suspended, true)
    XCTAssertNotNil(f.secrets.read("connection-\(f.connection.id)"))
    XCTAssertEqual(try f.repository.catalog(f.plain.id).nodes, before.nodes)
    XCTAssertEqual(try Data(contentsOf: file), Data("original".utf8))
    do {
      _ = try await f.service.list("root", location: f.plain.id)
      XCTFail("Suspended domains must not perform remote work")
    } catch MobileError.missing {}
    try await f.service.setLocationSuspended(f.plain.id, suspended: false)
    let resumed = try await f.service.list("root", location: f.plain.id)
    XCTAssertEqual(resumed.map(\.id).sorted(), before.nodes.keys.sorted())
  }
  func testSuspendRejectsPendingEditsAndUnlockedVaults() async throws {
    let f = try MobileCoreTests().fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let (vault, _) = try await f.service.createVault(
      connectionID: f.connection.id, parent: "", name: "vault", password: "long-test-password",
      remember: true)
    do {
      try await f.service.setLocationSuspended(vault.id, suspended: true)
      XCTFail("Lock the vault before unregistering it")
    } catch MobileError.busy {}
    let source = f.root.appendingPathComponent("source")
    try Data("unsent".utf8).write(to: source)
    await f.store.setFailure(upload: true)
    do {
      _ = try await f.service.create(
        parent: "root", name: "pending.txt", directory: false, contents: source,
        requestID: "pending", location: f.plain.id)
    } catch {}
    do {
      try await f.service.setLocationSuspended(f.plain.id, suspended: true)
      XCTFail("Unsent edits must prevent suspension")
    } catch MobileError.busy {}
    XCTAssertEqual(try f.repository.pending(f.plain.id).count, 1)
    XCTAssertNotEqual(
      try f.repository.configuration().locations.first(where: { $0.id == f.plain.id })?.suspended,
      true)
    await f.store.setFailure()
    try await f.service.retryPending(f.plain.id)
    try await f.service.setLocationSuspended(vault.id, suspended: true) { _ in
      try await f.service.lock(vault.id)
    }
    XCTAssertFalse(try f.service.isUnlocked(vault.id))
    XCTAssertTrue(try f.service.canUnlockWithoutPassword(vault.id))
    try await f.service.unlock(vault.id, password: nil)
    try await f.service.setLocationSuspended(vault.id, suspended: false)
    _ = try await f.service.list("root", location: vault.id)
  }
}
