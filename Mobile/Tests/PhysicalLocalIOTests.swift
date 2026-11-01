import CloudMountMobileCore
import CloudMountVaultCore
import XCTest

final class PhysicalLocalIOTests: XCTestCase {
  func testLocalStreamAndVaultDownloadToNewFile() async throws {
    let service = try MobileEnvironment.service()
    let root = service.repository.root.appendingPathComponent("local-io-test-"+UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fresh = root.appendingPathComponent("fresh")
    let stream = try XCTUnwrap(OutputStream(url: fresh, append: false))
    stream.open()
    if let error = stream.streamError { throw error }
    let bytes = Array("local stream".utf8)
    XCTAssertEqual(stream.write(bytes,maxLength: bytes.count),bytes.count)
    stream.close()
    try service.repository.protect(fresh)
    XCTAssertEqual(try Data(contentsOf: fresh),Data(bytes))
    print("LOCAL-IO stream-and-protection=passed")
    let cloud = root.appendingPathComponent("cloud")
    try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
    let (descriptor,raw) = try VaultDescriptor.create(password:"isolated-device-fixture-password")
    let fs = try VaultFileSystem(store:LocalCiphertextStore(root:cloud),descriptor:descriptor,rawKey:raw,scratch:root.appendingPathComponent("scratch"))
    try await fs.initialize()
    try await fs.upload(fresh,to:"file.txt",requireNew:true)
    let output = root.appendingPathComponent("decrypted")
    _ = try await fs.download("file.txt",to:output)
    try service.repository.protect(output)
    XCTAssertEqual(try Data(contentsOf:output),Data(bytes))
    print("LOCAL-IO local-vault-download=passed")
  }
}
