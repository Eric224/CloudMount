import CloudMountMobileCore
import CloudMountVaultCore
import FileProvider
import XCTest

final class ProviderEnumerationTests: XCTestCase {
  func testSimulatorDisconnectReconnectUsesOSDomainsAndPreservesSettings() async throws {
    #if !targetEnvironment(simulator)
      throw XCTSkip("Registration lifecycle fixture is restricted to the dedicated simulator")
    #else
      guard ProcessInfo.processInfo.environment["CLOUDMOUNT_DEVICE_DAV_FIXTURE"] == "1" else {
        throw XCTSkip("Start and trust the dedicated loopback TLS DAV fixture")
      }
      let service = try MobileEnvironment.service()
      let connection = MobileConnection(
        name: "Temporary lifecycle test", endpoint: URL(string: "https://127.0.0.1:19463/home/")!,
        username: "test")
      var location = MobileLocation(connectionID: connection.id, name: "Temporary lifecycle test")
      location.suspended = true
      do {
        let lease = try await service.repository.lease("configuration")
        defer { withExtendedLifetime(lease) {} }
        var config = try service.repository.configuration()
        config.connections.append(connection)
        config.locations.append(location)
        try service.repository.write(config, name: "configuration.json")
        try service.secrets.save(Data("test".utf8), key: "connection-\(connection.id)")
      }
      func cleanup() async throws {
        if try await NSFileProviderManager.domains().contains(where: {
          $0.identifier.rawValue == location.id.uuidString
        }) {
          try await NSFileProviderManager.remove(MobileEnvironment.domain(location))
        }
        try await service.removeConnection(connection.id)
      }
      do {
        try await MobileEnvironment.resume(location)
        var registered = try await NSFileProviderManager.domains()
        XCTAssertTrue(registered.contains { $0.identifier.rawValue == location.id.uuidString })
        XCTAssertEqual(
          try service.repository.configuration().locations.first(where: { $0.id == location.id })?
            .suspended, false)
        try await MobileEnvironment.suspend(location)
        registered = try await NSFileProviderManager.domains()
        XCTAssertFalse(registered.contains { $0.identifier.rawValue == location.id.uuidString })
        XCTAssertEqual(
          try service.repository.configuration().locations.first(where: { $0.id == location.id })?
            .suspended, true)
        XCTAssertNotNil(try service.secrets.read("connection-\(connection.id)"))
        try await MobileEnvironment.resume(location)
        registered = try await NSFileProviderManager.domains()
        XCTAssertTrue(registered.contains { $0.identifier.rawValue == location.id.uuidString })
        try await MobileEnvironment.suspend(location)
        try await cleanup()
      } catch {
        try? await cleanup()
        throw error
      }
    #endif
  }
  func testSystemBarrierTimeoutPreventsUnregisteringAndIgnoresLateReply() async throws {
    var late: ((Error?) -> Void)?
    var didUnregister = false
    do {
      try await SystemSyncBarrier.wait(timeout: 0.02) { late = $0 }
      didUnregister = true
      XCTFail("A pending barrier cannot authorize unregistering")
    } catch MobileError.busy {}
    XCTAssertFalse(didUnregister)
    late?(nil)
    late?(MobileError.busy)
    try await SystemSyncBarrier.wait(timeout: 1) { $0(nil) }
  }
  func testWorkingSetEnumeratesThousandsOfflineWithBoundedPages() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "provider-pages-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try MobileRepository(root: root)
    let connection = MobileConnection(
      name: "test", endpoint: URL(string: "https://offline.invalid")!, username: "")
    let location = MobileLocation(connectionID: connection.id, name: "test")
    var config = MobileConfiguration()
    config.connections = [connection]
    config.locations = [location]
    try repo.write(config, name: "configuration.json")
    var catalog = MobileCatalog()
    for i in 0..<6490 {
      catalog.record(
        MobileNode(
          id: "id-\(i)", parent: "root", path: "file-\(i)", name: "file-\(i)", directory: false,
          size: 1, modified: .distantPast, version: "v1"))
    }
    try repo.saveCatalog(catalog, id: location.id)
    let service = MobileService(
      repository: repo, secrets: NoSecrets(),
      storeFactory: { _ in
        XCTFail("Working-set enumeration must never contact a transport")
        return LocalCiphertextStore(root: root)
      })
    let enumerator = FileProviderEnumerator(
      service: service, location: location.id, container: .workingSet)
    let done = expectation(description: "Paged cached working set")
    let observer = PageObserver(enumerator: enumerator, completion: { done.fulfill() })
    enumerator.enumerateItems(
      for: observer,
      startingAt: NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data))
    await fulfillment(of: [done], timeout: 15)
    enumerator.invalidate()
    XCTAssertEqual(observer.count, 6490)
    XCTAssertEqual(observer.ids.count, 6490)
    XCTAssertGreaterThan(observer.pages, 30)
    XCTAssertNil(observer.failure)
    XCTAssertNil(
      try service.providerHealth(location.id), "A cached read must not signal remote recovery")
  }
}
private struct NoSecrets: MobileSecrets {
  func read(_ key: String) throws -> Data? { nil }
  func save(_ value: Data, key: String) throws {}
  func remove(_ key: String) throws {}
}
private final class PageObserver: NSObject, NSFileProviderEnumerationObserver {
  let enumerator: FileProviderEnumerator, completion: () -> Void
  var ids = Set<String>(), count = 0, pages = 0, failure: Error?
  let suggestedPageSize: Int = 127
  init(enumerator: FileProviderEnumerator, completion: @escaping () -> Void) {
    self.enumerator = enumerator
    self.completion = completion
  }
  func didEnumerate(_ items: [NSFileProviderItem]) {
    XCTAssertLessThanOrEqual(items.count, 127)
    count += items.count
    ids.formUnion(items.map { $0.itemIdentifier.rawValue })
  }
  func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
    pages += 1
    if let nextPage {
      Task {
        await Task.yield()
        enumerator.enumerateItems(for: self, startingAt: nextPage)
      }
    } else {
      completion()
    }
  }
  func finishEnumeratingWithError(_ error: Error) {
    failure = error
    completion()
  }
}
