import CloudMountMobileCore
import CloudMountVaultCore
import FileProvider
import XCTest

/// Reads the user's existing configuration only after explicit physical-test opt-in.
/// Credentials remain in the device Keychain and names/contents are not logged.
final class PhysicalConnectionTests: XCTestCase {
  private func service() throws -> MobileService {
    guard ProcessInfo.processInfo.environment["CLOUDMOUNT_DEVICE_READ_TEST"] == "1" else {
      throw XCTSkip("Physical read-only connection diagnostics require opt-in")
    }
    return try MobileEnvironment.service()
  }
  func testConfiguredRemoteReadsAndRegisteredLocations() async throws {
    let service = try service()
    let configuration = try await service.configuration()
    let locations = configuration.locations.filter { $0.removedPath == nil }
    guard !locations.isEmpty else { throw XCTSkip("No configured locations on this device") }
    let registered = Set(try await NSFileProviderManager.domains().map { $0.identifier.rawValue })
    XCTAssertEqual(Set(configuration.connections.map(\.id)).count, configuration.connections.count)
    XCTAssertEqual(Set(locations.map(\.id)).count, locations.count)
    var read = 0, locked = 0
    for location in locations {
      XCTAssertTrue(registered.contains(location.id.uuidString), "An active location is not registered with Files")
      let root = try await service.item("root", location: location.id)
      XCTAssertTrue(root.directory)
      let pending = try service.repository.pending(location.id).count
      if location.isVault, try !service.isUnlocked(location.id) {
        locked += 1
        do {
          _ = try await service.list("root", location: location.id)
          XCTFail("A locked vault exposed contents")
        } catch MobileError.locked {}
      } else {
        do {
          let entries = try await service.list("root", location: location.id)
          XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
          await MobileEnvironment.didReadRemote(location.id)
          print("PHYSICAL-ENTRIES kind=\(location.isVault ? "vault" : "ordinary") count=\(entries.count)")
          read += 1
        } catch {
          XCTFail("Configured remote read failed: " + MobileMessage.describe(error))
        }
      }
      print("PHYSICAL-LOCATION kind=\(location.isVault ? "vault" : "ordinary") pending=\(pending) health=\((try service.providerHealth(location.id))?.issue.rawValue ?? "none")")
    }
    print("PHYSICAL-READ registered=\(locations.count) read=\(read) locked=\(locked)")
  }
  func testConfiguredOrdinaryLocationThroughSystemFileProvider() async throws {
    let service = try service()
    guard let location = try await service.configuration().locations.first(where: {
      !$0.isVault && $0.removedPath == nil
    }) else { throw XCTSkip("No ordinary location is configured") }
    let manager = try XCTUnwrap(NSFileProviderManager(for: MobileEnvironment.domain(location)))
    let url = try await manager.getUserVisibleURL(for: .rootContainer)
    let names = try await MobileProviderTests.coordinatedList(url)
    print("PHYSICAL-FILES ordinary_root_entries=\(names.count)")
    XCTAssertEqual(Set(names).count, names.count)
  }
}
