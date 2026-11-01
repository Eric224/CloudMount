import CloudMountVaultCore
import Foundation
import XCTest
@testable import CloudMountMobileCore

final class FileServerIntegrationTests: XCTestCase {
  private func fixture(_ kind: FileServerKind) throws -> any NativeConditionalStore {
    guard ProcessInfo.processInfo.environment["CLOUDMOUNT_RUN_FILE_SERVER_TESTS"] == "1" else { throw XCTSkip("Opt in to loopback-only FTP/SFTP fixtures") }
    if kind == .sftp {
      let pin = try String(contentsOfFile: "/private/tmp/cloudmount-file-server-fixture-20261022/fingerprint.txt", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
      return try SFTPStore(endpoint: URL(string: "sftp://127.0.0.1:19469/")!, settings: FileServerSettings(kind: .sftp, hostKeyFingerprint: pin), username: "test", password: "test")
    }
    return try FTPStore(endpoint: URL(string: kind == .ftp ? "ftp://127.0.0.1:19467/" : "ftps://127.0.0.1:19468/")!, settings: FileServerSettings(kind: kind), username: "test", password: "test")
  }
  func testFTPUnicodeCrudOverwriteAndVaultLifecycle() async throws { try await lifecycle(try fixture(.ftp)) }
  func testFTPSUnicodeCrudOverwriteAndVaultLifecycleWithIsolatedTrustAnchor() async throws {
    _ = try fixture(.ftps)
    let pem = try String(contentsOfFile: "/private/tmp/cloudmount-file-server-fixture-20261022/test-ca.pem", encoding: .utf8)
    let encoded = pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
    let anchor = try XCTUnwrap(Data(base64Encoded: encoded))
    let store = try FTPStore(endpoint: URL(string: "ftps://127.0.0.1:19468/")!, settings: FileServerSettings(kind: .ftps), username: "test", password: "test", testingAnchor: anchor)
    try await lifecycle(store)
  }
  func testSFTPUnicodeCrudOverwriteAndVaultLifecycle() async throws { try await lifecycle(try fixture(.sftp)) }
  func testSFTPUnknownOrChangedHostKeyFailsBeforePasswordAuthentication() async throws {
    _ = try fixture(.sftp)
    for pin in [nil, "SHA256:invalid"] as [String?] {
      let store = try SFTPStore(endpoint: URL(string:"sftp://127.0.0.1:19469/")!, settings: FileServerSettings(kind:.sftp,hostKeyFingerprint:pin),username:"test",password:"test")
      do { _ = try await store.list(""); XCTFail("Unconfirmed host must fail") }
      catch let error as SSHHostVerification { XCTAssertEqual(error.changed,pin != nil); XCTAssertTrue(error.fingerprint.hasPrefix("SHA256:")) }
    }
  }
  func testFTPSRejectsUntrustedCertificateWithoutPlaintextFallback() async throws {
    let store = try fixture(.ftps)
    do { _ = try await store.list(""); XCTFail("Self-signed fixture must not be trusted") }
    catch let error as URLError { XCTAssertTrue([.serverCertificateUntrusted,.serverCertificateHasUnknownRoot,.secureConnectionFailed].contains(error.code),error.localizedDescription) }
  }
  func testFTPSNeverSendsLoginToPlaintextOnlyServer() async throws {
    _ = try fixture(.ftp)
    let store = try FTPStore(endpoint: URL(string: "ftps://127.0.0.1:19467/")!, settings: FileServerSettings(kind: .ftps), username: "test", password: "test")
    do { _ = try await store.list(""); XCTFail("AUTH TLS refusal must not fall back") }
    catch MobileError.network(let status) { XCTAssertEqual(status, 500) }
  }
  func testMissingNetworkCallbackStillTimesOutAndDuplicateCompletionIsIgnored() async throws {
    let cancellation = TransferCancellation()
    do {
      let _: Int = try await transferReply(cancellation, timeout: 0.05) { _ in }
      XCTFail("Missing callback must not hang")
    } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
    let result: Int = try await transferReply(TransferCancellation(), timeout: 1) { done in done(.success(1)); done(.success(2)) }
    XCTAssertEqual(result, 1)
  }
  private func lifecycle(_ store: any NativeConditionalStore) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloudmount-file-server-test-"+UUID().uuidString)
    try FileManager.default.createDirectory(at: root,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:root) }
    let prefix="fixture-"+UUID().uuidString
    try await store.mkdir(prefix+"/nested")
    let source=root.appendingPathComponent("source"), output=root.appendingPathComponent("output")
    try Data("first".utf8).write(to:source)
    let path=prefix+"/nested/ 私人 +%.txt "
    try await store.put(source,path:path,expected:nil,requireNew:true)
    let previous=try await store.stat(path)
    XCTAssertEqual(previous.size,5)
    try Data("updated content".utf8).write(to:source)
    try await store.put(source,path:path,expected:previous.version,requireNew:false)
    do { try await store.put(source,path:path,expected:previous.version,requireNew:false);XCTFail("Stale revision must fail") } catch MobileError.conflict {}
    let names = try await store.list(prefix+"/nested").map(\.name)
    XCTAssertEqual(names,[" 私人 +%.txt "])
    try await store.download(path,to:output)
    XCTAssertEqual(try Data(contentsOf:output),Data("updated content".utf8))
    try await store.move(path,to:prefix+"/nested/改名.txt",directory:false,replace:false)
    let repo=try MobileRepository(root:root.appendingPathComponent("device"))
    let connection=MobileConnection(name:"fixture",endpoint:URL(string:"https://fixture.invalid")!,username:"test")
    var config=MobileConfiguration();config.connections=[connection];try repo.write(config,name:"configuration.json")
    let service=MobileService(repository:repo,secrets:TestSecrets(),storeFactory:{ _ in store })
    let (vault,words)=try await service.createVault(connectionID:connection.id,parent:prefix,name:"私人保險庫",password:"long-test-password",remember:true)
    XCTAssertEqual(words.split(separator:" ").count,44)
    let item=try await service.create(parent:"root",name:"秘密.txt",directory:false,contents:source,requestID:"file",location:vault.id)
    try Data("vault update".utf8).write(to:source)
    let modified=try await service.modify(item.id,parent:nil,name:nil,contents:source,expected:item.version,location:vault.id)
    try? FileManager.default.removeItem(at:output)
    _=try await service.download(modified.id,location:vault.id,to:output)
    XCTAssertEqual(try Data(contentsOf:output),Data("vault update".utf8))
    try await service.lock(vault.id);try await service.unlock(vault.id,password:nil)
    try await service.delete(item.id,expected:nil,recursive:false,location:vault.id)
    try await service.lock(vault.id);try await service.trashVault(vault.id);try await service.restoreVault(vault.id)
    func cleanup(_ path:String) async throws {
      for entry in try await store.list(path) {
        let child=try MobilePath.join(path,entry.name)
        if entry.isDirectory { try await cleanup(child) } else { try await store.delete(child,directory:false) }
      }
      try await store.delete(path,directory:true)
    }
    try await cleanup(prefix)
  }
}
