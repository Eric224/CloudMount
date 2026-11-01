import CloudMountVaultCore
import Foundation
import XCTest

@testable import CloudMountMobileCore

final class ResourceSafetyTests: XCTestCase {
  func testServiceRecipesPreserveServerPrefixesAndEncodeUsernames() throws {
    XCTAssertEqual(
      try StorageServicePreset.nextcloud.webDAVURL(
        address: "https://example.com/cloud/", username: "a+b@example.com"
      ).absoluteString, "https://example.com/cloud/remote.php/dav/files/a%2Bb%40example.com/")
    XCTAssertEqual(
      try StorageServicePreset.owncloud.webDAVURL(address: "https://example.com/own", username: "")
        .absoluteString, "https://example.com/own/remote.php/webdav/")
    let full = "https://example.com/cloud/remote.php/dav/files/alice/Documents/"
    XCTAssertEqual(
      try StorageServicePreset.nextcloud.webDAVURL(address: full, username: "other").absoluteString,
      full)
    for bad in [
      "http://example.com", "https://user:secret@example.com", "https://example.com/?a=1",
      "https://example.com/a/../b", "https://example.com/%2e%2e/b",
    ] {
      XCTAssertThrowsError(
        try StorageServicePreset.webdav.webDAVURL(address: bad, username: ""), bad)
    }
    let b2 = try StorageServicePreset.s3Connection(
      preset: "B2", address: "", region: "us-west-004", account: "")
    XCTAssertEqual(b2.endpoint.absoluteString, "https://s3.us-west-004.backblazeb2.com")
    let spaces = try StorageServicePreset.s3Connection(
      preset: "Spaces", address: "", region: "nyc3", account: "")
    XCTAssertEqual(spaces.region, "us-east-1")
    XCTAssertEqual(spaces.endpoint.host, "nyc3.digitaloceanspaces.com")
    XCTAssertThrowsError(
      try StorageServicePreset.s3Connection(
        preset: "AWS", address: "", region: "us-east-1.attacker.com/", account: ""))
    XCTAssertThrowsError(
      try StorageServicePreset.s3Connection(
        preset: "R2", address: "", region: "", account: "bad-account"))
    XCTAssertEqual(StorageServicePreset.allCases.count, 18)
  }
  func testTaskRegistryReleasesFinishedTasksAndCapsPendingWork() async throws {
    let registry = MobileTaskRegistry(maximum: 2)
    for _ in 0..<100 {
      let task = try XCTUnwrap(registry.start {})
      await task.value
      XCTAssertEqual(registry.activeCount, 0)
    }
    let first = try XCTUnwrap(registry.start { try? await Task.sleep(for: .seconds(20)) })
    let second = try XCTUnwrap(registry.start { try? await Task.sleep(for: .seconds(20)) })
    XCTAssertNil(registry.start {})
    XCTAssertEqual(registry.activeCount, 2)
    registry.invalidate()
    await first.value
    await second.value
    XCTAssertEqual(registry.activeCount, 0)
    XCTAssertNil(registry.start {})
  }
  func testResourceSlotsAreSharedAcrossRepositoryInstancesAndCancelPromptly() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "cloudmount-budget-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = try MobileRepository(root: root)
    let b = try MobileRepository(root: root)
    let first = try await MobileResourceGate.shared.acquire(a)
    let second = try await MobileResourceGate.shared.acquire(b)
    do {
      _ = try await MobileResourceGate.shared.acquire(a, timeout: 0)
      XCTFail("Two shared cloud slots already occupied")
    } catch MobileError.busy {}
    let waiting = Task { try await MobileResourceGate.shared.acquire(b) }
    waiting.cancel()
    do {
      _ = try await waiting.value
      XCTFail("Cancellation must release the waiter")
    } catch is CancellationError {}
    withExtendedLifetime((first, second)) {}
    let crypto = try await MobileResourceGate.shared.acquire(a, crypto: true)
    do {
      _ = try await MobileResourceGate.shared.acquire(b, crypto: true, timeout: 0)
      XCTFail("One shared crypto slot")
    } catch MobileError.busy {}
    withExtendedLifetime(crypto) {}
  }
  func testReadOnlyBlocksMutationsButAllowsListing() async throws {
    let f = try MobileCoreTests().fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    var config = try f.repository.configuration()
    config.connections[0].readOnly = true
    try f.repository.write(config, name: "configuration.json")
    _ = try await f.service.list("root", location: f.plain.id)
    do {
      _ = try await f.service.create(
        parent: "root", name: "blocked", directory: true, contents: nil, requestID: "blocked",
        location: f.plain.id)
      XCTFail("Read-only must not write")
    } catch MobileError.unsafeWrites {}
    do {
      _ = try await f.service.createVault(
        connectionID: f.connection.id, parent: "", name: "blocked vault",
        password: "long-test-password", remember: false)
      XCTFail("Read-only must not initialize a vault")
    } catch MobileError.unsafeWrites {}
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.cloud.path).isEmpty)
    XCTAssertTrue(try f.repository.pending(f.plain.id).isEmpty)
    // Old configuration files with no readOnly field remain decodable.
    let bytes = try JSONEncoder().encode(
      MobileConnection(name: "legacy", endpoint: URL(string: "https://example.com")!, username: ""))
    XCTAssertNil(try JSONDecoder().decode(MobileConnection.self, from: bytes).readOnly)
  }
  func testOversizedImportedVaultKDFIsRejectedBeforeDerivation() async throws {
    let f = try MobileCoreTests().fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let (vault, _) = try await f.service.createVault(
      connectionID: f.connection.id, parent: "", name: "test", password: "long-test-password",
      remember: false)
    try await f.service.lock(vault.id)
    var config = try f.repository.configuration()
    let index = try XCTUnwrap(config.locations.firstIndex(where: { $0.id == vault.id }))
    let original = try XCTUnwrap(config.locations[index].descriptor)
    var fields = try XCTUnwrap(
      JSONSerialization.jsonObject(with: original.masterkeyFile) as? [String: Any])
    fields["scryptCostParam"] = 131_072
    fields["scryptBlockSize"] = 8
    config.locations[index].descriptor = try VaultDescriptor.parse(
      masterkeyFile: JSONSerialization.data(withJSONObject: fields),
      vaultConfig: original.vaultConfig)
    try f.repository.write(config, name: "configuration.json")
    try config.locations[index].descriptor!.masterkeyFile.write(
      to: f.cloud.appendingPathComponent(vault.path).appendingPathComponent(VaultDescriptor.keyName)
    )
    do {
      try await f.service.unlock(vault.id, password: "long-test-password")
      XCTFail("128 MiB KDF must be refused before allocation")
    } catch MobileError.vaultMemoryLimit {}
    XCTAssertFalse(try f.service.isUnlocked(vault.id))
  }
  func testOversizedJournalIsRejectedBeforeLoading() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "cloudmount-large-journal-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try MobileRepository(root: root)
    let file = try repo.file("large.json")
    FileManager.default.createFile(atPath: file.path, contents: Data())
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 64 * 1_048_576)
    try handle.close()
    XCTAssertThrowsError(try repo.read("large.json", default: [String: String]()))
  }
}

final class ResourceHTTPIntegrationTests: XCTestCase {
  private func checkFixture() throws {
    guard ProcessInfo.processInfo.environment["CLOUDMOUNT_RUN_RESOURCE_TESTS"] == "1" else {
      throw XCTSkip("Start Mobile/Testing/resource-fixture.py before opting in")
    }
  }
  func testBoundedDownloadAndUploadResponseWithAndWithoutContentLength() async throws {
    try checkFixture()
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let source = FileManager.default.temporaryDirectory.appendingPathComponent(
      "cloudmount-http-" + UUID().uuidString)
    try Data("small request".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    for route in ["large", "chunked"] {
      let request = URLRequest(url: URL(string: "http://127.0.0.1:19471/bounded/" + route)!)
      do {
        let (file, _) = try await BoundedHTTP.download(session, request: request, maximum: 1024)
        try? FileManager.default.removeItem(at: file)
        XCTFail("Oversized download must abort: " + route)
      } catch MobileError.incomplete {}
      var post = request
      post.httpMethod = "POST"
      do {
        _ = try await BoundedHTTP.upload(session, request: post, file: source, maximum: 1024)
        XCTFail("Oversized upload reply must abort: " + route)
      } catch MobileError.incomplete {}
    }
    let request = URLRequest(url: URL(string: "http://127.0.0.1:19471/bounded/small")!)
    let (file, _) = try await BoundedHTTP.download(session, request: request, maximum: 1024)
    defer { try? FileManager.default.removeItem(at: file) }
    XCTAssertEqual(try Data(contentsOf: file), Data("ok".utf8))
    var post = request
    post.httpMethod = "POST"
    let (data, _) = try await BoundedHTTP.upload(
      session, request: post, file: source, maximum: 1024)
    XCTAssertEqual(data, Data("ok".utf8))
  }
  func testResponseRedirectsAreNeverAutomaticallyFollowedAndCancellationWorks() async throws {
    try checkFixture()
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let redirect = URLRequest(url: URL(string: "http://127.0.0.1:19471/bounded/redirect")!)
    let (file, response) = try await BoundedHTTP.download(session, request: redirect, maximum: 1024)
    defer { try? FileManager.default.removeItem(at: file) }
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 302)
    let source = FileManager.default.temporaryDirectory.appendingPathComponent(
      "cloudmount-cancel-" + UUID().uuidString)
    try Data("body".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    var slow = URLRequest(url: URL(string: "http://127.0.0.1:19471/bounded/slow")!)
    slow.httpMethod = "POST"
    let task = Task {
      try await BoundedHTTP.upload(session, request: slow, file: source, maximum: 1024)
    }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Cancelled upload must finish with error")
    } catch is CancellationError {} catch let error as URLError {
      XCTAssertEqual(error.code, .cancelled)
    }
  }
  func testS3ProbeRejectsIgnoredConditionsAndJournalsForbiddenCleanup() async throws {
    try checkFixture()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "cloudmount-s3-probe-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try MobileRepository(root: root)
    for (mode, expected, retained) in [
      ("safe", true, false), ("ignores", false, false), ("ignore-copy",false,false), ("ignore-delete",false,false), ("reject-valid-delete",false,false), ("no-delete", false, true),
    ] {
      let native = try S3Store(
        endpoint: URL(string: "http://127.0.0.1:19471")!,
        settings: S3Settings(bucket: mode, region: "us-east-1"),
        credentials: S3Credentials(accessKey: "test", secretKey: "test"), journal: repo,
        allowLoopbackHTTP: true)
      let result = try await native.verifyWriteSupport(force: true)
      XCTAssertEqual(result.supported, expected, mode)
      XCTAssertEqual(result.retainedProbeKey != nil, retained, mode)
      let retry = try await native.verifyWriteSupport(force: true)
      XCTAssertEqual(retry.supported, expected)
      if retained {
        XCTAssertEqual(
          result.retainedProbeKey, retry.retainedProbeKey,
          "Failed cleanup must never accumulate new probe objects")
      }
      if !expected {
        let source = try repo.file("source")
        try Data("blocked".utf8).write(to: source)
        do {
          try await native.put(source, path: "user-object", expected: nil, requireNew: true)
          XCTFail("Unverified writes must be blocked")
        } catch MobileError.unsafeWrites {}
      }
    }
  }
}
