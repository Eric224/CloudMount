import XCTest
import Foundation
@testable import CloudMountMobileCore

final class ConnectionRemovalTests: XCTestCase {
  func testRemovalKeepsRemoteVaultAndRefusesUnlockedVault() async throws {
    let f = try MobileCoreTests().fixture()
    defer { try? FileManager.default.removeItem(at:f.root) }
    let (vault,_) = try await f.service.createVault(connectionID:f.connection.id,parent:"",name:"保留在雲端",password:"long-test-password",remember:true)
    do { try await f.service.removeConnection(f.connection.id);XCTFail("Unlocked vault must not be forgotten") }
    catch MobileError.busy {}
    let unchanged = try await f.service.configuration()
    XCTAssertEqual(unchanged.connections.count,1)
    try await f.service.lock(vault.id)
    do {
      try await f.service.removeConnection(f.connection.id) { _ in throw MobileError.network(503) }
      XCTFail("OS preflight error must preserve registration")
    } catch MobileError.network(503) {}
    XCTAssertEqual(try f.repository.configuration().connections.count,1)
    try await f.service.removeConnection(f.connection.id)
    XCTAssertTrue(try f.repository.configuration().connections.isEmpty)
    XCTAssertTrue(try f.repository.configuration().locations.isEmpty)
    XCTAssertNil(f.secrets.read("remembered-\(vault.id)"))
    XCTAssertTrue(FileManager.default.fileExists(atPath:f.cloud.appendingPathComponent(vault.path+"/vault.cryptomator").path))
  }
  func testPendingUploadPreventsRemovalAndRetainsItsOnlyLocalCopy() async throws {
    let f = try MobileCoreTests().fixture()
    defer { try? FileManager.default.removeItem(at:f.root) }
    let source=f.root.appendingPathComponent("edited")
    try Data("unsent edit".utf8).write(to:source)
    await f.store.setFailure(upload:true)
    do { _ = try await f.service.create(parent:"root",name:"edited.txt",directory:false,contents:source,requestID:"pending",location:f.plain.id);XCTFail("Fixture upload should fail") }
    catch MobileError.network(503) {}
    do { try await f.service.removeConnection(f.connection.id);XCTFail("Unsent edit must block removal") }
    catch MobileError.busy {}
    XCTAssertEqual(try f.repository.configuration().connections.count,1)
    XCTAssertEqual(try f.repository.pending(f.plain.id).count,1)
  }
}
