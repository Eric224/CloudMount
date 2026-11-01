import CloudMountMobileCore
import CloudMountVaultCore
import Foundation
import FileProvider
import XCTest

/// Explicit opt-in only. Uses the already-entered device Keychain credential;
/// it is never copied to the Mac, command arguments, screenshots or test logs.
final class PhysicalNASVaultTests: XCTestCase {
  func testIsolatedHomeVaultCreateEditLockRecoveryAndDelete() async throws {
    guard ProcessInfo.processInfo.environment["CLOUDMOUNT_DEVICE_NAS_TEST"] == "1",
      let allowedHost = ProcessInfo.processInfo.environment["CLOUDMOUNT_DEVICE_DAV_HOST"] else { throw XCTSkip("Opt-in physical NAS home fixture") }
    let service = try MobileEnvironment.service()
    let config = try await service.configuration()
    guard let connection = config.connections.first(where: { $0.s3 == nil && $0.fileServer == nil && $0.endpoint.scheme == "https" && $0.endpoint.host == allowedHost }) else { throw XCTSkip("Connect the authorized NAS in CloudMount first") }
    let base = connection.endpoint.path.trimmingCharacters(in: CharacterSet(charactersIn:"/"))
    guard base.isEmpty || base == "home" else { throw XCTSkip("Only the explicitly authorized home test area may be used") }
    try await exercise(service: service, connection: connection)
  }
  func testIsolatedConfiguredWebDAVVaultCreateEditLockRecoveryAndDelete() async throws {
    guard ProcessInfo.processInfo.environment["CLOUDMOUNT_DEVICE_DAV_FIXTURE"] == "1" else {
      throw XCTSkip("Opt-in isolated WebDAV fixture")
    }
    let service = try MobileEnvironment.service()
    let config = try await service.configuration()
    guard let connection = config.connections.first(where: {
      $0.s3 == nil && $0.drime == nil && $0.fileServer == nil && $0.endpoint.scheme == "https"
    }) else { throw XCTSkip("No configured HTTPS WebDAV connection") }
    try await exercise(service: service, connection: connection)
  }
  func testIsolatedConfiguredWebDAVPlainFileCRUD() async throws {
    guard ProcessInfo.processInfo.environment["CLOUDMOUNT_DEVICE_DAV_FIXTURE"] == "1" else { throw XCTSkip("Opt-in isolated plain DAV fixture") }
    let service = try MobileEnvironment.service()
    guard let c = try await service.configuration().connections.first(where: { $0.s3 == nil && $0.drime == nil && $0.fileServer == nil }),
      let secret = try service.secrets.read("connection-\(c.id)"), let password = String(data:secret,encoding:.utf8) else { throw XCTSkip("No configured WebDAV") }
    let native = try WebDAVStore(endpoint:c.endpoint,username:c.username,password:password)
    let parent = c.endpoint.host == "nas.example.test" && c.endpoint.path.trimmingCharacters(in:CharacterSet(charactersIn:"/")).isEmpty ? "home/" : ""
    let prefix = parent+".cloudmount-device-plain-"+UUID().uuidString
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:root) }
    let source = root.appendingPathComponent("source"), output = root.appendingPathComponent("readback")
    try await native.mkdir(prefix)
    print("PLAIN-FIXTURE-OWNED prefix=\(prefix)")
    try Data("first-plain-fixture".utf8).write(to:source)
    let path = prefix+"/中文檔案.txt"
    try await native.put(source,path:path,expected:nil,requireNew:true)
    let first = try await native.stat(path)
    try Data("updated-plain-fixture".utf8).write(to:source)
    try await native.put(source,path:path,expected:first.version,requireNew:false)
    do {
      try await native.put(source,path:path,expected:first.version,requireNew:false)
      XCTFail("A stale version was accepted")
    } catch MobileError.conflict {}
    try await native.download(path,to:output)
    XCTAssertEqual(try Data(contentsOf:output),Data("updated-plain-fixture".utf8))
    try await native.move(path,to:prefix+"/改名.txt",directory:false,replace:false)
    try await native.delete(prefix+"/改名.txt",directory:false)
    try await native.delete(prefix,directory:true)
    print("PLAIN-FIXTURE create-overwrite-conflict-read-rename-delete-cleanup passed")
  }
  /// Only fixtures positively owned by this test run may contain files.
  func testCleanupOwnedPhysicalFixtures() async throws {
    guard ProcessInfo.processInfo.environment["CLOUDMOUNT_DEVICE_DAV_FIXTURE"] == "1" else { throw XCTSkip("Explicit fixture cleanup opt-in") }
    let service = try MobileEnvironment.service()
    var config = try await service.configuration()
    let owned: Set<String> = [
      ".cloudmount-device-tests-206D7AB1-D248-4127-90EA-AE13CDD288DF",
      ".cloudmount-device-tests-5F31D43D-CF7E-4A91-9F45-6F660CA1FD57",
      ".cloudmount-device-tests-A06350E9-847A-4C9A-96F5-6531A50757B6",
      ".cloudmount-device-tests-849B69C2-0DC2-47E8-9CEE-E76C6F365FE9"
    ]
    for connection in config.connections where connection.s3 == nil && connection.drime == nil && connection.fileServer == nil {
      guard let data = try service.secrets.read("connection-\(connection.id)"), let password = String(data:data,encoding:.utf8) else { continue }
      let native = try WebDAVStore(endpoint:connection.endpoint,username:connection.username,password:password)
      for plainPrefix in [".cloudmount-device-plain-F6FBABE3-0F69-445F-AD1A-9C934BF08572", ".cloudmount-device-plain-F9529503-9FE9-419C-BA9A-FC761546E84B", ".cloudmount-device-plain-516E9F70-CBA9-410F-8F32-AEAC1E168632", ".cloudmount-device-plain-1DF6678B-0DE4-422C-9BC4-C8AA0DACCD6D", ".cloudmount-device-plain-B973BB98-0701-409C-BDF4-EE48F41FE1D0", ".cloudmount-device-plain-AF94F9A4-D0B7-4CFA-A155-E8379D2610C8", ".cloudmount-device-plain-A83CDC2C-A51C-46E8-9A03-372D6FFFCA33", ".cloudmount-device-plain-44055F64-49FE-4AAC-841B-8F70523749FE", ".cloudmount-device-plain-705B4366-CD1A-4FE9-B6E6-608314284D8B", ".cloudmount-device-plain-26BA91FD-638C-4D46-A020-3357AECB07FF", ".cloudmount-device-plain-9475BC27-49AC-47F2-8505-FB2B1CA6BDB2", ".cloudmount-commit-probe-50F65534-0F26-4E4E-8029-101939DB3A52"] {
      for attempt in 0..<6 {
        do {
          print("CLEANUP-OWNED prefix=\(plainPrefix) attempt=\(attempt)")
          let values = try await native.list(plainPrefix)
          guard values.allSatisfy({ !$0.isDirectory && ["中文檔案.txt","改名.txt","old.txt","stage.tmp"].contains($0.name) }) else { throw MobileError.conflict }
          for child in values {
            do { try await native.delete(MobilePath.join(plainPrefix,child.name),directory:false) }
            catch VaultCoreError.missing {}
            catch MobileError.forbidden {
              // pCloud may reject DELETE on an already absent old entry.
              // This is fixture cleanup only; never hide a live forbidden file.
              do { _ = try await native.stat(MobilePath.join(plainPrefix,child.name)); throw MobileError.forbidden }
              catch VaultCoreError.missing {}
            }
          }
          try await native.delete(plainPrefix,directory:true)
          break
        } catch VaultCoreError.missing { break }
          catch VaultCoreError.busy {
            guard attempt < 5 else { throw VaultCoreError.busy }
          }
      }
      }
      for prefix in owned {
        func remove(_ path:String) async throws {
          guard path == prefix || path.hasPrefix(prefix+"/") else { throw MobileError.invalidName }
          for entry in try await native.list(path) {
            let child = try MobilePath.join(path,entry.name)
            if entry.isDirectory { try await remove(child) } else { try await native.delete(child,directory:false) }
          }
          try await native.delete(path,directory:true)
        }
        do { try await remove(prefix) } catch VaultCoreError.missing {}
        for location in config.locations.filter({ $0.connectionID == connection.id && ($0.path == prefix || $0.path.hasPrefix(prefix+"/")) }) {
          let domains = try await NSFileProviderManager.domains()
          if let domain = domains.first(where:{$0.identifier.rawValue == location.id.uuidString}) { try await NSFileProviderManager.remove(domain) }
          for operation in try service.repository.pending(location.id) {
            let file = try service.repository.file("upload-"+operation.id)
            if FileManager.default.fileExists(atPath:file.path) { try FileManager.default.removeItem(at:file) }
          }
          try service.secrets.remove("active-\(location.id)")
          try service.secrets.remove("remembered-\(location.id)")
          for name in ["catalog-\(location.id).json","pending-\(location.id).json"] {
            let file = try service.repository.file(name)
            if FileManager.default.fileExists(atPath:file.path) { try FileManager.default.removeItem(at:file) }
          }
          config.locations.removeAll { $0.id == location.id }
        }
      }
      // Earlier failed creation attempts contain only empty directories.
      // Leave any unknown tree containing even one file completely untouched.
      for entry in try await native.list("") where entry.isDirectory && entry.name.hasPrefix(".cloudmount-device-tests-") && UUID(uuidString:String(entry.name.dropFirst(".cloudmount-device-tests-".count))) != nil {
        func emptyTree(_ path:String) async throws -> Bool {
          for child in try await native.list(path) {
            if !child.isDirectory { return false }
            if try await !emptyTree(MobilePath.join(path,child.name)) { return false }
          }
          return true
        }
        if try await emptyTree(entry.name) {
          func removeEmpty(_ path:String) async throws {
            for child in try await native.list(path) { try await removeEmpty(MobilePath.join(path,child.name)) }
            try await native.delete(path,directory:true)
          }
          try await removeEmpty(entry.name)
        }
      }
    }
    let lease = try await service.repository.lease("configuration")
    defer { withExtendedLifetime(lease) {} }
    try service.repository.write(config,name:"configuration.json")
    print("FIXTURE-CLEANUP completed")
  }
  private func exercise(service: MobileService, connection: MobileConnection) async throws {
    let base = connection.endpoint.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let credential = try service.secrets.read("connection-\(connection.id)"), let password = String(data:credential,encoding:.utf8) else { throw MobileError.credential }
    let native = try WebDAVStore(endpoint:connection.endpoint,username:connection.username,password:password)
    let parent = connection.endpoint.host == "nas.example.test" && base.isEmpty ? "home" : ""
    let prefix = (parent.isEmpty ? "" : parent+"/") + ".cloudmount-device-tests-" + UUID().uuidString
    let source = service.repository.root.appendingPathComponent("device-fixture-"+UUID().uuidString)
    let output = service.repository.root.appendingPathComponent("device-output-"+UUID().uuidString)
    defer {
      for file in [source,output] where FileManager.default.fileExists(atPath:file.path) {
        try? FileManager.default.removeItem(at:file)
      }
    }
    var created: MobileLocation?
    do {
      print("FIXTURE-STAGE begin-create-vault")
      let (vault,words) = try await service.createVault(connectionID:connection.id,parent:prefix,name:"跨裝置保險庫測試",password:"isolated-device-fixture-password",remember:true)
      created = vault
      print("FIXTURE-OWNED id=\(vault.id) prefix=\(prefix)")
      print("FIXTURE-STAGE create-vault")
      XCTAssertEqual(words.split(separator:" ").count,44)
      try Data("device-created-private-content".utf8).write(to:source)
      let item = try await service.create(parent:"root",name:"私人文件.txt",directory:false,contents:source,requestID:UUID().uuidString,location:vault.id)
      print("FIXTURE-STAGE create-file")
      try Data("device-updated-private-content".utf8).write(to:source)
      let changed = try await service.modify(item.id,parent:nil,name:nil,contents:source,expected:item.version,location:vault.id)
      print("FIXTURE-STAGE modify-file")
      _ = try await service.download(changed.id,location:vault.id,to:output)
      print("FIXTURE-STAGE download-file")
      XCTAssertEqual(try Data(contentsOf:output),Data("device-updated-private-content".utf8))
      try await service.lock(vault.id)
      XCTAssertFalse(try service.isUnlocked(vault.id))
      print("FIXTURE-STAGE lock")
      try await service.unlock(vault.id,password:nil)
      print("FIXTURE-STAGE unlock")
      let renamed = try await service.modify(item.id,parent:nil,name:"改名後.txt",contents:nil,expected:changed.version,location:vault.id)
      print("FIXTURE-STAGE rename")
      try await service.delete(renamed.id,expected:nil,recursive:false,location:vault.id)
      let empty = try await service.list("root",location:vault.id)
      XCTAssertTrue(empty.isEmpty,"An overwritten older revision must not reappear")
      try await service.lock(vault.id)
      print("FIXTURE-STAGE delete-file-and-lock")
      try await service.trashVault(vault.id)
      print("FIXTURE-STAGE trash")
      try await service.restoreVault(vault.id)
      print("FIXTURE-STAGE restore")
      try await service.unlock(vault.id,password:"isolated-device-fixture-password")
      try await service.lock(vault.id)
    } catch {
      // Keep a failed fixture recoverable if the network or device disappears.
      // Never clean an unrelated user path or conceal the original error.
      print("FIXTURE-FAIL domain=\((error as NSError).domain) code=\((error as NSError).code) advice=\(MobileMessage.describe(error))")
      throw error
    }
    func cleanup(_ path: String) async throws {
      guard path == prefix || path.hasPrefix(prefix+"/") else { throw MobileError.invalidName }
      for child in try await native.list(path) {
        let item = try MobilePath.join(path,child.name)
        if child.isDirectory { try await cleanup(item) } else { try await native.delete(item,directory:false) }
      }
      try await native.delete(path,directory:true)
    }
    try await cleanup(prefix)
    if let created {
      let lease = try await service.repository.lease("configuration")
      defer { withExtendedLifetime(lease) {} }
      var updated = try service.repository.configuration()
      updated.locations.removeAll { $0.id == created.id }
      try service.repository.write(updated,name:"configuration.json")
      try service.secrets.remove("active-\(created.id)")
      try service.secrets.remove("remembered-\(created.id)")
      for name in ["catalog-\(created.id).json","pending-\(created.id).json"] { try? FileManager.default.removeItem(at:service.repository.file(name)) }
    }
  }
}
