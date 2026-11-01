import FileProvider
import CloudMountVaultCore
import UIKit
import ImageIO
import XCTest

@testable import CloudMountMobileCore

final class MobileProviderTests: XCTestCase {
  func testProviderItemsHaveStableOpaqueIdentifiersAndContentVersions() {
    let node = MobileNode(
      id: "opaque-id", parent: "root", path: "私人.txt", name: "私人.txt", directory: false, size: 42,
      modified: Date(timeIntervalSince1970: 0), version: "revision-1")
    let first = FileProviderItem(node)
    let second = FileProviderItem(node)
    XCTAssertEqual(first.itemIdentifier, second.itemIdentifier)
    XCTAssertEqual(first.parentItemIdentifier, .rootContainer)
    XCTAssertEqual(first.itemVersion, second.itemVersion)
    XCTAssertTrue(first.capabilities.contains(.allowsWriting))
  }
  func testReadOnlyCapabilitiesAndUnsupportedWritesNeverBecomeNetworkRetryErrors() {
    let node = MobileNode(
      id: "file", parent: "root", path: "file.txt", name: "file.txt", directory: false, size: 1,
      modified: Date(timeIntervalSince1970: 0), version: "v1")
    let normal = FileProviderItem(node)
    let readOnly = FileProviderItem(node, readOnly: true)
    XCTAssertTrue(readOnly.capabilities.contains(.allowsReading))
    for capability in [
      NSFileProviderItemCapabilities.allowsWriting, .allowsDeleting, .allowsRenaming,
      .allowsReparenting,
    ] { XCTAssertFalse(readOnly.capabilities.contains(capability)) }
    XCTAssertEqual(normal.itemVersion.contentVersion, readOnly.itemVersion.contentVersion)
    XCTAssertNotEqual(normal.itemVersion.metadataVersion, readOnly.itemVersion.metadataVersion)
    for error in [MobileError.unsafeWrites, .vaultMemoryLimit] {
      let mapped = MobileEnvironment.providerError(error, location: UUID())
      XCTAssertEqual(mapped.domain, NSCocoaErrorDomain)
      XCTAssertEqual(mapped.code, NSFeatureUnsupportedError)
    }
  }
  func testSharedAppGroupIsAvailable() throws { _ = try MobileEnvironment.service() }
  func testExpiredAnchorsAndPagesArePreservedInsteadOfCreatingStickyNetworkWarnings() {
    for code in [NSFileProviderError.Code.syncAnchorExpired, .pageExpired, .noSuchItem] {
      let original = NSError(
        domain: NSFileProviderErrorDomain, code: code.rawValue, userInfo: ["fixture": "kept"])
      let result = MobileEnvironment.providerError(original, location: UUID())
      XCTAssertEqual(result.domain, original.domain)
      XCTAssertEqual(result.code, original.code)
      XCTAssertEqual(result.userInfo["fixture"] as? String, "kept")
      XCTAssertNil(ProviderErrorPolicy.issue(original))
    }
    let cancelled = MobileEnvironment.providerError(URLError(.cancelled), location: UUID())
    XCTAssertEqual(cancelled.domain, NSCocoaErrorDomain)
    XCTAssertEqual(cancelled.code, NSUserCancelledError)
    let locked = MobileEnvironment.providerError(MobileError.deviceLocked, location: UUID())
    XCTAssertEqual(locked.code, NSFileProviderError.notAuthenticated.rawValue)
    XCTAssertEqual(locked.userInfo["CloudMountReason"] as? String, "deviceLocked")
  }
}

extension MobileProviderTests {
  @MainActor func testSystemFileProviderMaterializesDecryptsAndLocks() async throws {
    let service = try MobileEnvironment.service()
    let config = try await service.configuration()
    let vault: MobileLocation
    if let existing = config.locations.first(where: {
      $0.name.hasPrefix("Files Test Vault ") && $0.removedPath == nil
    }) {
      vault = existing
      if try !service.isUnlocked(vault.id) {
        try await service.unlock(vault.id, password: "long-test-password", remember: true)
      }
      await MobileEnvironment.didUnlock(vault.id)
    } else {
      let plain = try await service.addWebDAV(
        name: "Provider Fixture " + UUID().uuidString.prefix(4),
        endpoint: URL(string: "https://127.0.0.1:19463/home/")!, username: "test", password: "test")
      vault = try await service.createVault(
        connectionID: plain.connectionID, parent: "",
        name: "Files Test Vault " + UUID().uuidString.prefix(4), password: "long-test-password",
        remember: true
      ).0
    }
    let source = service.repository.root.appendingPathComponent(
      "provider-source-" + UUID().uuidString)
    try Data("This is decrypted by the real iOS File Provider.".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let nodes = try await service.list("root", location: vault.id)
    let node: MobileNode
    if let old = nodes.first(where: { $0.name == "Hello.txt" }) {
      node = old
    } else {
      node = try await service.create(
        parent: "root", name: "Hello.txt", directory: false, contents: source,
        requestID: UUID().uuidString, location: vault.id)
    }
    try await MobileEnvironment.publish(vault)
    let manager = try XCTUnwrap(NSFileProviderManager(for: MobileEnvironment.domain(vault)))
    try await manager.waitForStabilization()
    let rootURL = try await manager.getUserVisibleURL(for: .rootContainer)
    let files = try await Self.coordinatedList(rootURL)
    XCTAssertTrue(files.contains("Hello.txt"), files.description)
    let itemURL = try await manager.getUserVisibleURL(for: NSFileProviderItemIdentifier(node.id))
    let data = try await Self.coordinatedRead(itemURL)
    XCTAssertEqual(
      String(data: data, encoding: .utf8), "This is decrypted by the real iOS File Provider.")
    try await MobileEnvironment.lock(vault)
    XCTAssertFalse(try service.isUnlocked(vault.id))
    do {
      _ = try await service.item(node.id, location: vault.id)
      XCTFail("Locked provider must require authentication")
    } catch MobileError.locked {}
    try await service.unlock(vault.id, password: nil)
    await MobileEnvironment.didUnlock(vault.id)
    let reopened = try await Self.coordinatedRead(itemURL)
    XCTAssertEqual(reopened, data)
    try await MobileEnvironment.lock(vault)
    // Retain this disposable, locked fixture for the Files authentication UI
    // test. It contains no user data and lives only on the loopback server.
  }
  nonisolated static func coordinatedRead(_ url: URL) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var error: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) {
          coordinated in result = Result { try Data(contentsOf: coordinated) }
        }
        if let error {
          continuation.resume(throwing: error)
        } else if let result {
          continuation.resume(with: result)
        } else {
          continuation.resume(throwing: MobileError.incomplete)
        }
      }
    }
  }
  nonisolated static func coordinatedList(_ url: URL) async throws -> [String] {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var error: NSError?
        var result: Result<[String], Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) {
          coordinated in
          result = Result { try FileManager.default.contentsOfDirectory(atPath: coordinated.path) }
        }
        if let error {
          continuation.resume(throwing: error)
        } else if let result {
          continuation.resume(with: result)
        } else {
          continuation.resume(throwing: MobileError.incomplete)
        }
      }
    }
  }
}

extension MobileProviderTests {
  func testThumbnailCallbacksFinishExactlyOnceAndCancellationRejectsLateImages() async throws {
    let recorder = PreviewCallbackRecorder()
    let progress = Progress(totalUnitCount: 2)
    let callbacks = ThumbnailBatchCallbacks(progress: progress,
      perItem: { _, _, _ in recorder.add("item") }, completion: { _ in recorder.add("finish") })
    await callbacks.item(NSFileProviderItemIdentifier("first"), Data([1]), nil)
    await callbacks.finish(nil)
    await callbacks.finish(nil)
    await callbacks.item(NSFileProviderItemIdentifier("late"), Data([2]), nil)
    XCTAssertEqual(recorder.events, ["item", "finish"])
    let work = Task<Void, Never> { do { try await Task.sleep(for: .seconds(5)) } catch {} }
    await callbacks.installCancellation(work)
    XCTAssertNil(progress.cancellationHandler, "A completed task must not retain a new cancellation closure")
    work.cancel(); await work.value
    let cancelled = Progress(totalUnitCount: 1)
    cancelled.cancel()
    let second = ThumbnailBatchCallbacks(progress: cancelled,
      perItem: { _, _, _ in recorder.add("unexpected") }, completion: { error in
        recorder.add((error as NSError?)?.code == NSUserCancelledError ? "cancel" : "wrong")
      })
    let waiting = Task<Void, Never> { do { try await Task.sleep(for: .seconds(5)) } catch {} }
    await second.installCancellation(waiting)
    await waiting.value
    await second.finish(nil)
    XCTAssertEqual(recorder.events, ["item", "finish", "cancel"])
  }
  func testInvalidThumbnailDimensionsCompleteWithoutAccessingCloud() async throws {
    let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(UUID().uuidString), displayName: "Preview test")
    let provider = FileProviderExtension(domain: domain)
    let done = expectation(description: "Invalid dimensions finish")
    _ = provider.fetchThumbnails(for: [NSFileProviderItemIdentifier("unused")], requestedSize: CGSize(width: Double.nan, height: 256),
      perThumbnailCompletionHandler: { _, _, _ in XCTFail("An invalid request must not read an item") },
      completionHandler: { error in
        XCTAssertEqual((error as NSError?)?.code, NSUserCancelledError)
        done.fulfill()
      })
    await fulfillment(of: [done], timeout: 2)
    provider.invalidate()
  }
}
private final class PreviewCallbackRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values = [String]()
  var events: [String] { lock.lock(); defer { lock.unlock() }; return values }
  func add(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
}

extension MobileProviderTests {
  @MainActor func testRealThumbnailCallbackSuppliesSmallImageAndUsesProtectedCache() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ios-preview-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try MobileRepository(root: root.appendingPathComponent("device"))
    let cloud = root.appendingPathComponent("cloud")
    try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
    let png = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600)).image { context in
      UIColor.systemGreen.setFill(); context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
    }.pngData()!
    try png.write(to: cloud.appendingPathComponent("photo.png"))
    let connection = MobileConnection(name: "test", endpoint: URL(string: "https://fixture.invalid")!, username: "")
    let location = MobileLocation(connectionID: connection.id, name: "test")
    var config = MobileConfiguration(); config.connections = [connection]; config.locations = [location]
    try repo.write(config, name: "configuration.json")
    let local = LocalCiphertextStore(root: cloud)
    let service = MobileService(repository: repo, secrets: PreviewNoSecrets(), storeFactory: { _ in local })
    let nodes = try await service.list("root", location: location.id)
    let item = try XCTUnwrap(nodes.first)
    let provider = FileProviderExtension(domain: NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(location.id.uuidString), displayName: "Preview test"), service: service)
    let gotImage = expectation(description: "Real image callback"), done = expectation(description: "Batch complete")
    let progress = provider.fetchThumbnails(for: [NSFileProviderItemIdentifier(item.id)], requestedSize: CGSize(width: 256, height: 256),
      perThumbnailCompletionHandler: { id, data, error in
        XCTAssertEqual(id.rawValue, item.id); XCTAssertNil(error)
        if let data, let image = CGImageSourceCreateWithData(data as CFData, nil), let thumbnail = CGImageSourceCreateImageAtIndex(image, 0, nil) {
          XCTAssertLessThanOrEqual(thumbnail.width, 256); XCTAssertLessThanOrEqual(thumbnail.height, 256)
          XCTAssertLessThan(data.count, png.count + 4096)
        } else { XCTFail("Expected valid image data") }
        gotImage.fulfill()
      }, completionHandler: { error in XCTAssertNil(error); done.fulfill() })
    await fulfillment(of: [gotImage, done], timeout: 10)
    XCTAssertEqual(progress.completedUnitCount, 1)
    let files = try FileManager.default.contentsOfDirectory(at: repo.root.appendingPathComponent("preview-cache-v1"), includingPropertiesForKeys: nil)
    let stored = try XCTUnwrap(files.first)
    #if targetEnvironment(simulator)
      // Simulator does not emulate the device's hardware data-protection class.
      XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: stored.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    #else
      XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: stored.path)[.protectionKey] as? FileProtectionType, .complete)
    #endif
    provider.invalidate()
  }
}
private struct PreviewNoSecrets: MobileSecrets {
  func read(_ key: String) throws -> Data? { nil }
  func save(_ value: Data, key: String) throws {}
  func remove(_ key: String) throws {}
}
