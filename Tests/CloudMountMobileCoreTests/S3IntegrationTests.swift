import CloudMountVaultCore
import Foundation
import XCTest

@testable import CloudMountMobileCore

final class S3IntegrationTests: XCTestCase {
  func testConditionalRenameAndDeletePreserveConcurrentExternalEdits() async throws {
    guard ProcessInfo.processInfo.environment["CLOUDMOUNT_RUN_LOCAL_S3_TESTS"] == "1" else { throw XCTSkip("Start the isolated S3 fixture") }
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("cloudmount-s3-race-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let repo=try MobileRepository(root:root)
    let store=try S3Store(endpoint:URL(string:"http://127.0.0.1:19466")!,settings:S3Settings(bucket:"mobile-tests",region:"us-east-1"),credentials:S3Credentials(accessKey:"cloudmount-test-access",secretKey:"cloudmount-test-secret"),journal:repo,allowLoopbackHTTP:true)
    let id=UUID().uuidString,source="race-source-"+id,destination="race-copy-destination-"+id,deleting="race-delete-source-"+id
    let file=try repo.file("source");try Data("original".utf8).write(to:file)
    try await store.put(file,path:source,expected:nil,requireNew:true)
    do { try await store.move(source,to:destination,directory:false,replace:false);XCTFail("A destination created after HEAD must not be overwritten") } catch MobileError.conflict {}
    let preserved=try await store.read(source,limit:64),external=try await store.read(destination,limit:64)
    XCTAssertEqual(preserved,Data("original".utf8));XCTAssertEqual(external,Data("external-edit".utf8))
    try await store.put(file,path:deleting,expected:nil,requireNew:true)
    do { try await store.delete(deleting,directory:false);XCTFail("A source changed after HEAD must not be deleted") } catch MobileError.conflict {}
    let latest=try await store.read(deleting,limit:64);XCTAssertEqual(latest,Data("external-edit".utf8))
    for key in [source,destination,deleting] { try await store.delete(key,directory:false) }
  }
  func testNativeS3SignatureCrudAndStandardVaultLifecycle() async throws {
    guard ProcessInfo.processInfo.environment["CLOUDMOUNT_RUN_LOCAL_S3_TESTS"] == "1" else {
      throw XCTSkip("Start the isolated S3 server on 127.0.0.1:19465 before opting in")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "cloudmount-s3-test-" + UUID().uuidString)
    let repo = try MobileRepository(root: root)
    let keys = TestSecrets()
    defer { try? FileManager.default.removeItem(at: root) }
    let settings = S3Settings(bucket: "mobile-tests", region: "us-east-1")
    let credentials = S3Credentials(
      accessKey: "cloudmount-test-access", secretKey: "cloudmount-test-secret")
    let native = try S3Store(
      endpoint: URL(string: "http://127.0.0.1:19466")!, settings: settings,
      credentials: credentials, journal: repo, allowLoopbackHTTP: true)
    let id = "fixture-" + UUID().uuidString
    try await native.mkdir(id)
    let source = root.appendingPathComponent("source")
    try Data("first".utf8).write(to: source)
    let name = id + "/中文 +%.txt"
    try await native.put(source, path: name, expected: nil, requireNew: true)
    let original = try await native.stat(name)
    XCTAssertEqual(original.size, 5)
    try Data("other".utf8).write(to: source)
    try await native.put(source, path: name, expected: original.version, requireNew: false)
    do {
      try await native.put(source, path: name, expected: original.version, requireNew: false)
      XCTFail("Stale ETag must not overwrite")
    } catch MobileError.conflict {}
    let listed = try await native.list(id)
    XCTAssertEqual(listed.map(\.name), ["中文 +%.txt"])
    let decomposed = " e\u{301}.txt "
    try await native.put(source, path: id + "/" + decomposed, expected: nil, requireNew: true)
    let exactNames = try await native.list(id)
    XCTAssertTrue(exactNames.contains { Array($0.name.utf8) == Array(decomposed.utf8) })
    let rawNameData = try await native.read(id + "/" + decomposed, limit: 32)
    XCTAssertEqual(rawNameData, Data("other".utf8))
    try await native.delete(id + "/" + decomposed, directory: false)
    try await native.move(name, to: id + "/renamed.txt", directory: false, replace: false)
    let decoded = root.appendingPathComponent("decoded")
    try await native.download(id + "/renamed.txt", to: decoded)
    XCTAssertEqual(try String(contentsOf: decoded, encoding: .utf8), "other")
    let connection = MobileConnection(
      name: "S3 fixture", endpoint: URL(string: "https://fixture.invalid")!,
      username: credentials.accessKey, s3: settings)
    var config = MobileConfiguration()
    config.connections = [connection]
    try repo.write(config, name: "configuration.json")
    let service = MobileService(repository: repo, secrets: keys, storeFactory: { _ in native })
    let (vault, recovery) = try await service.createVault(
      connectionID: connection.id, parent: id, name: "私人保險庫", password: "long-test-password",
      remember: true)
    XCTAssertEqual(recovery.split(separator: " ").count, 44)
    let file = try await service.create(
      parent: "root", name: "秘密.txt", directory: false, contents: source, requestID: "s3-file",
      location: vault.id)
    try Data("third".utf8).write(to: source)
    let edited = try await service.modify(
      file.id, parent: nil, name: nil, contents: source, expected: file.version, location: vault.id)
    let download = root.appendingPathComponent("plain")
    _ = try await service.download(edited.id, location: vault.id, to: download)
    XCTAssertEqual(try String(contentsOf: download, encoding: .utf8), "third")
    try await service.lock(vault.id)
    try await service.trashVault(vault.id)
    try await service.restoreVault(vault.id)
    try await service.unlock(vault.id, password: "long-test-password")
    _ = try await service.list("root", location: vault.id)
    try await service.delete(file.id, expected: nil, recursive: false, location: vault.id)
    try await service.lock(vault.id)
    let independent = try S3Store(
      endpoint: URL(string: "http://127.0.0.1:19465")!, settings: settings,
      credentials: credentials, allowLoopbackHTTP: true)
    _ = try await independent.list("")
    // The independent server verifies SigV4 but does not implement all write
    // preconditions. Its normal adapter must therefore stay read-only.
    let signatureServerSupport = try await independent.verifyWriteSupport(force:true)
    XCTAssertFalse(signatureServerSupport.supported)
    let invalid = try S3Store(
      endpoint: URL(string: "http://127.0.0.1:19465")!, settings: settings,
      credentials: S3Credentials(accessKey: credentials.accessKey, secretKey: "incorrect-secret"),
      allowLoopbackHTTP: true)
    do {
      _ = try await invalid.list("")
      XCTFail("Wrong SigV4 must fail")
    } catch MobileError.credential {}
    // Only this run's explicitly created prefix can be recursively cleaned.
    func cleanup(_ path: String) async throws {
      for item in try await native.list(path) {
        let child = try MobilePath.join(path, item.name)
        if item.isDirectory {
          try await cleanup(child)
        } else {
          try await native.delete(child, directory: false)
        }
      }
      try await native.delete(path, directory: true)
    }
    try await cleanup(id)
  }
}
