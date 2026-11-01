import CloudMountVaultCore
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CloudMountMobileCore

final class MobileBrowsingTests: XCTestCase {
  func image(_ red: CGFloat, _ blue: CGFloat) throws -> Data {
    let ctx = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
      bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    ctx.setFillColor(red: red, green: 0, blue: blue, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    let bytes = NSMutableData()
    let dst = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dst, try XCTUnwrap(ctx.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(dst))
    return bytes as Data
  }
  func testLegacyS3SettingsAndBothURLStylesPreserveEncodedPrefixAndPorts() throws {
    let legacy = try JSONDecoder().decode(S3Settings.self, from: Data("{\"bucket\":\"photos\",\"region\":\"us-east-1\"}".utf8))
    XCTAssertEqual(legacy.prefix, ""); XCTAssertEqual(legacy.urlStyle, .path)
    let credentials = S3Credentials(accessKey: "test", secretKey: "secret")
    for style in S3URLStyle.allCases {
      let settings = S3Settings(bucket: "photos", region: "us-east-1", prefix: "私人 +%/images", urlStyle: style)
      let store = try S3Store(endpoint: URL(string: "https://s3.example:9443/api")!, settings: settings, credentials: credentials)
      let request = try store.request("GET", "中文 +%.png")
      let parts = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
      XCTAssertEqual(parts.host, style == .path ? "s3.example" : "photos.s3.example")
      XCTAssertEqual(parts.port, 9443)
      XCTAssertEqual(parts.path, style == .path ? "/api/photos/私人 +%/images/中文 +%.png" : "/api/私人 +%/images/中文 +%.png")
      XCTAssertTrue(parts.percentEncodedPath.contains("%25"))
      let list = try store.request("GET", "", query: ["prefix": "私人 +%/images/"])
      XCTAssertEqual(list.url?.path, style == .path ? "/api/photos" : "/api")
      XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("SignedHeaders=") == true)
    }
    for prefix in ["/outside", "a/../b", "folder/", "a//b"] {
      XCTAssertThrowsError(try S3Store(endpoint: URL(string: "https://s3.example")!,
        settings: S3Settings(bucket: "bucket", region: "auto", prefix: prefix), credentials: credentials))
    }
    for bucket in ["", " ", "folder/name", "bad\nname"] {
      XCTAssertThrowsError(try S3Store(endpoint: URL(string: "https://s3.example")!, settings: S3Settings(bucket: bucket, region: "auto"), credentials: credentials))
    }
    XCTAssertThrowsError(try S3Store(endpoint: URL(string: "https://s3.example")!, settings: S3Settings(bucket: "中文", region: "auto", urlStyle: .virtualHosted), credentials: credentials))
  }
  func pageFixture() throws -> (URL, MobileRepository, MobileService, MobileLocation, BrowsingStore) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("browsing-" + UUID().uuidString)
    let repo = try MobileRepository(root: root)
    let store = BrowsingStore(root: root)
    let connection = MobileConnection(name: "test", endpoint: URL(string: "https://test.invalid")!, username: "",
      s3: S3Settings(bucket: "bucket", region: "auto"))
    let location = MobileLocation(connectionID: connection.id, name: "test")
    var config = MobileConfiguration(); config.connections = [connection]; config.locations = [location]
    try repo.write(config, name: "configuration.json")
    return (root, repo, MobileService(repository: repo, secrets: TestSecrets(), storeFactory: { _ in store }), location, store)
  }
  func testFirstS3PageIsReturnedBeforeLaterPagesAndCompletedScanIsReused() async throws {
    let (root, repo, service, location, store) = try pageFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var catalog = MobileCatalog()
    catalog.record(MobileNode(id: "gone", parent: "root", path: "gone", name: "gone", directory: false, size: 1, modified: .distantPast, version: "v1"))
    try repo.saveCatalog(catalog, id: location.id)
    let pages = MobileProviderDirectoryPages(service: service, location: location.id, parent: "root")
    let first = try await pages.first(size: 2)
    XCTAssertEqual(first.nodes.map(\.name), ["a.png", "b.png"])
    let firstCalls = await store.calls(); XCTAssertEqual(firstCalls, 1)
    XCTAssertNotNil(try repo.catalog(location.id).nodes["gone"], "A partial page must not delete an unseen item")
    let firstMetadata = try await service.providerItem(first.nodes[0].id, location: location.id)
    XCTAssertFalse(firstMetadata.verifiedRemote, "Even the first page already supplies verified metadata")
    let last = try await pages.next(try XCTUnwrap(first.next), size: 2)
    XCTAssertEqual(last.nodes.map(\.name), ["c.png"]); XCTAssertNil(last.next)
    XCTAssertNil(try repo.catalog(location.id).nodes["gone"])
    let cached = MobileProviderDirectoryPages(service: service, location: location.id, parent: "root")
    let hit = try await cached.first(size: 10)
    XCTAssertEqual(hit.nodes.count, 3); XCTAssertFalse(hit.verifiedRemote)
    let totalCalls = await store.calls(); XCTAssertEqual(totalCalls, 2)
    let metadata = try await service.providerItem(first.nodes[0].id, location: location.id)
    XCTAssertFalse(metadata.verifiedRemote, "Fresh list metadata should not cause per-file HEAD requests")
  }
  func testFailedOrCancelledPagesDoNotProduceTombstonesOrDeleteLocalEdits() async throws {
    let (root, repo, service, location, store) = try pageFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var catalog = MobileCatalog()
    let initial = MobileNode(id: "old", parent: "root", path: "old", name: "old", directory: false, size: 1, modified: .distantPast, version: "v1")
    catalog.record(initial); try repo.saveCatalog(catalog, id: location.id)
    let failed = MobileProviderDirectoryPages(service: service, location: location.id, parent: "root")
    let first = try await failed.first(size: 2)
    await store.failSecond(true)
    do { _ = try await failed.next(try XCTUnwrap(first.next), size: 2); XCTFail("Must fail") } catch MobileError.network(503) {}
    XCTAssertEqual(try repo.catalog(location.id).nodes["old"], initial)
    let hasCache = try await service.cachedProviderDirectoryForChanges("root", location: location.id); XCTAssertFalse(hasCache)
    await store.failSecond(false)
    let retry = MobileProviderDirectoryPages(service: service, location: location.id, parent: "root")
    let partial = try await retry.first(size: 2)
    catalog = try repo.catalog(location.id)
    var edited = initial; edited.version = "local-edit"; catalog.record(edited)
    try repo.saveCatalog(catalog, id: location.id)
    _ = try await retry.next(try XCTUnwrap(partial.next), size: 2)
    XCTAssertEqual(try repo.catalog(location.id).nodes["old"]?.version, "local-edit")
    let cancelled = MobileProviderDirectoryPages(service: service, location: location.id, parent: "root")
    await cancelled.invalidate()
    do { _ = try await cancelled.first(size: 2); XCTFail("Invalidated scan must not start") } catch MobileError.busy {}
  }
  func testThumbnailsReuseLocalDataInvalidateOnOverwriteAndDoNotChangeHealth() async throws {
    let f = try MobileCoreTests().fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try image(1, 0).write(to: f.cloud.appendingPathComponent("photo.png"))
    let nodes = try await f.service.list("root", location: f.plain.id)
    let node = try XCTUnwrap(nodes.first)
    let firstData = try await f.service.thumbnail(node.id, location: f.plain.id, dimension: 256)
    let first = try XCTUnwrap(firstData)
    try await f.service.recordProviderFailure(.offline, location: f.plain.id)
    let second = try await f.service.thumbnail(node.id, location: f.plain.id, dimension: 256)
    XCTAssertEqual(second, first)
    XCTAssertEqual(try f.service.providerHealth(f.plain.id)?.issue, .offline)
    try image(0, 1).write(to: f.cloud.appendingPathComponent("photo.png"))
    _ = try await f.service.list("root", location: f.plain.id)
    let updated = try await f.service.thumbnail(node.id, location: f.plain.id, dimension: 256)
    XCTAssertNotEqual(updated, first)
    let pending = try f.repository.file("pending-preserve-test")
    try Data("pending edit".utf8).write(to: pending)
    try await f.service.clearThumbnailCache()
    XCTAssertEqual(try String(contentsOf: pending, encoding: .utf8), "pending edit")
    XCTAssertTrue(FileManager.default.fileExists(atPath: f.cloud.appendingPathComponent("photo.png").path))
  }
  func testVaultThumbnailCacheIsEncryptedAndCannotBeReadAfterLock() async throws {
    let f = try MobileCoreTests().fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let (vault, _) = try await f.service.createVault(connectionID: f.connection.id, parent: "", name: "private",
      password: "long-test-password", remember: false)
    let source = f.root.appendingPathComponent("source.png")
    try image(1, 0).write(to: source)
    let item = try await f.service.create(parent: "root", name: "photo.png", directory: false,
      contents: source, requestID: "image", location: vault.id)
    let previewData = try await f.service.thumbnail(item.id, location: vault.id, dimension: 256)
    let preview = try XCTUnwrap(previewData)
    let files = try FileManager.default.contentsOfDirectory(at: f.repository.root.appendingPathComponent("preview-cache-v1"), includingPropertiesForKeys: nil)
    XCTAssertEqual(files.count, 1)
    let stored = try Data(contentsOf: XCTUnwrap(files.first))
    XCTAssertThrowsError(try JSONSerialization.jsonObject(with: stored))
    let current = try await f.service.item(item.id, location: vault.id)
    let key = MobileThumbnailCache.key(location: vault.id, node: current, pixels: 256, vault: true)
    let secret = MobileThumbnailCache.encryptionKey(raw: try XCTUnwrap(f.secrets.read("active-\(vault.id)")), location: vault.id)
    let cached = try MobileThumbnailCache(repository: f.repository, policy: MobileBrowsingPolicy()).read(key, encryptionKey: secret)
    XCTAssertEqual(cached?.data, preview)
    try await f.service.lock(vault.id)
    do {
      try await f.service.deliverThumbnail(location: vault.id) { XCTFail("A thumbnail rendered before locking must not be delivered after locking") }
      XCTFail("Delivery must revalidate lock state")
    } catch MobileError.locked {}
    do { _ = try await f.service.thumbnail(item.id, location: vault.id, dimension: 256); XCTFail("Locked preview must be refused") } catch MobileError.locked {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.repository.root.appendingPathComponent("scratch-\(vault.id)").path))
    try await f.service.unlock(vault.id, password: "long-test-password")
    let reopened = try await f.service.thumbnail(item.id, location: vault.id, dimension: 256)
    XCTAssertEqual(reopened, preview)
  }
  func testPreviewCapsCorruptionCleanupAndCancellationAreBounded() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cache-limits-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try MobileRepository(root: root)
    let cache = MobileThumbnailCache(repository: repo, policy: MobileBrowsingPolicy())
    let id = String(repeating: "a", count: 64)
    try cache.save(Data([1, 2]), key: id, encryptionKey: nil)
    let dir = root.appendingPathComponent("preview-cache-v1")
    let corrupt = dir.appendingPathComponent(id + ".thumb")
    try Data("broken".utf8).write(to: corrupt)
    XCTAssertNil(try cache.read(id, encryptionKey: nil))
    for i in 0..<514 {
      try Data([0]).write(to: dir.appendingPathComponent(String(format: "%064x", i) + ".thumb"))
    }
    try cache.prune()
    XCTAssertLessThanOrEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 512)
    XCTAssertThrowsError(try MobileThumbnailRenderer.pixels(.infinity))
    XCTAssertThrowsError(try MobileThumbnailRenderer.pixels(.nan))
    XCTAssertEqual(try MobileThumbnailRenderer.pixels(90_000), 512)
    let delayed = Task {
      try await MobileDeadline.run(seconds: 0.02) { try await Task.sleep(for: .seconds(5)); return 1 }
    }
    do { _ = try await delayed.value; XCTFail("Deadline must cancel the work") } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
  }
}

actor BrowsingStore: PagedCiphertextStore {
  let base: LocalCiphertextStore
  private var count = 0, fail = false
  private var readCount = 0, statCount = 0, truncate = false
  init(root: URL) { base = LocalCiphertextStore(root: root) }
  func calls() -> Int { count }
  func ioCalls() -> (reads: Int, stats: Int) { (readCount, statCount) }
  func truncateDownloads() { truncate = true }
  func failSecond(_ enabled: Bool) { fail = enabled }
  func listPage(_ path: String, continuation: String?, limit: Int) async throws -> CipherDirectoryPage {
    count += 1
    if continuation != nil && fail { throw MobileError.network(503) }
    let names = continuation == nil ? ["a.png", "b.png"] : ["c.png"]
    return CipherDirectoryPage(items: names.map { CipherItem(name: $0, size: 1, modified: .distantPast, version: "v1", isDirectory: false) }, next: continuation == nil ? "page2" : nil)
  }
  func stat(_ p: String) async throws -> CipherItem { statCount += 1; return try await base.stat(p) }
  func list(_ p: String) async throws -> [CipherItem] { throw MobileError.incomplete }
  func read(_ p: String, limit: Int) async throws -> Data { readCount += 1; return try await base.read(p, limit: limit) }
  func download(_ p: String, to f: URL) async throws { if truncate { try Data([0]).write(to: f) } else { try await base.download(p, to: f) } }
  func upload(_ f: URL, to p: String) async throws { throw MobileError.unsupported }
  func mkdir(_ p: String) async throws { throw MobileError.unsupported }
  func move(_ p: String, to q: String, directory: Bool, replace: Bool) async throws { throw MobileError.unsupported }
  func delete(_ p: String, directory: Bool) async throws { throw MobileError.unsupported }
}

extension MobileBrowsingTests {
  func testSignedHTTPPaginationPrefixAndConditionalCopyStayWithinBucketScope() async throws {
    guard ProcessInfo.processInfo.environment["CLOUDMOUNT_RUN_BROWSING_HTTP_TESTS"] == "1" else { throw XCTSkip("Start the loopback browsing fixture") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("s3-browse-http-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try MobileRepository(root: root)
    let credentials = S3Credentials(accessKey: "cloudmount-test-access", secretKey: "cloudmount-test-secret")
    let store = try S3Store(endpoint: URL(string: "http://127.0.0.1:19474")!,
      settings: S3Settings(bucket: "mobile-tests", region: "auto", prefix: "scope"), credentials: credentials, journal: repo, allowLoopbackHTTP: true)
    var page = try await store.listPage("browse", continuation: nil, limit: 31)
    XCTAssertEqual(page.items.count, 31); XCTAssertNotNil(page.next)
    var names = page.items.map(\.name), count = 1
    while let next = page.next {
      page = try await store.listPage("browse", continuation: next, limit: 31)
      XCTAssertLessThanOrEqual(page.items.count, 31)
      names += page.items.map(\.name); count += 1
    }
    XCTAssertEqual(names.count, 257); XCTAssertEqual(Set(names).count, 257); XCTAssertEqual(count, 9)
    let source = try repo.file("source")
    try Data("private-data".utf8).write(to: source)
    let path = "crud-" + UUID().uuidString
    try await store.put(source, path: path, expected: nil, requireNew: true)
    let before = try await store.stat(path)
    try Data("updated-data".utf8).write(to: source)
    try await store.put(source, path: path, expected: before.version, requireNew: false)
    try await store.move(path, to: path + "-copy", directory: false, replace: false)
    let value = try await store.read(path + "-copy", limit: 32)
    XCTAssertEqual(value, Data("updated-data".utf8))
    try await store.delete(path + "-copy", directory: false)
    let unscoped = try S3Store(endpoint: URL(string: "http://127.0.0.1:19474")!, settings: S3Settings(bucket: "mobile-tests", region: "auto"), credentials: credentials, journal: repo, allowLoopbackHTTP: true)
    let outside = try await unscoped.read("outside.txt", limit: 32)
    XCTAssertEqual(outside, Data("outside-scope".utf8))
    do { _ = try await unscoped.read(path + "-copy", limit: 32); XCTFail("The prefix must not leak into the bucket root") } catch VaultCoreError.missing {}
  }
}

extension MobileBrowsingTests {
  func testMetadataObservationDoesNotCreateEndlessSyncChangesAndOldCatalogsDecode() throws {
    var node = MobileNode(id: "item", parent: "root", path: "photo.png", name: "photo.png", directory: false, size: 1, modified: .distantPast, version: "v1")
    let legacy = try JSONEncoder().encode(node)
    XCTAssertNil(try JSONDecoder().decode(MobileNode.self, from: legacy).observedAt)
    var catalog = MobileCatalog(); catalog.record(node)
    let generation = catalog.generation
    node.observedAt = Date(); catalog.record(node)
    XCTAssertEqual(catalog.generation, generation)
    XCTAssertEqual(catalog.nodes[node.id]?.observedAt, node.observedAt)
  }
  func testCachedAndConcurrentThumbnailReadsAreCoalescedAndTruncationIsRejected() async throws {
    let (root, repo, service, location, store) = try pageFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let png = try image(1, 0)
    try png.write(to: root.appendingPathComponent("photo.png"))
    let remote = try await store.stat("photo.png")
    var catalog = MobileCatalog()
    let node = MobileNode(id: "photo", parent: "root", path: "photo.png", name: "photo.png", directory: false, size: remote.size, modified: remote.modified, version: remote.version)
    catalog.record(node); try repo.saveCatalog(catalog, id: location.id)
    let first = try await service.thumbnail(node.id, location: location.id, dimension: 256)
    XCTAssertNotNil(first)
    let before = await store.ioCalls()
    let second = try await service.thumbnail(node.id, location: location.id, dimension: 256)
    let after = await store.ioCalls()
    XCTAssertEqual(first, second); XCTAssertEqual(before.reads, after.reads); XCTAssertEqual(before.stats, after.stats)
    try await service.clearThumbnailCache()
    async let a = service.thumbnail(node.id, location: location.id, dimension: 256)
    async let b = service.thumbnail(node.id, location: location.id, dimension: 256)
    let both = try await (a, b)
    XCTAssertEqual(both.0, both.1)
    let coalesced = await store.ioCalls()
    XCTAssertEqual(coalesced.reads, after.reads + 1, "Concurrent requests must share the resulting local cache")
    await store.truncateDownloads()
    let target = root.appendingPathComponent("downloaded")
    do { _ = try await service.download(node.id, location: location.id, to: target); XCTFail("A truncated response must not become a valid Files document") } catch MobileError.conflict {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    catalog = try repo.catalog(location.id)
    var huge = node; huge.id = "huge"; huge.name = "huge.png"; huge.path = "huge.png"; huge.size = 9_000_000
    catalog.record(huge); try repo.saveCatalog(catalog, id: location.id)
    let counters = await store.ioCalls()
    let skipped = try await service.thumbnail(huge.id, location: location.id, dimension: 256)
    let skippedCounters = await store.ioCalls()
    XCTAssertNil(skipped); XCTAssertEqual(counters.reads, skippedCounters.reads); XCTAssertEqual(counters.stats, skippedCounters.stats)
  }
}

extension MobileBrowsingTests {
  func testWeakFileServerRevisionDoesNotReuseOldThumbnailIndefinitely() async throws {
    let (root, repo, service, location, store) = try pageFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var config = try repo.configuration()
    config.connections[0].s3 = nil
    config.connections[0].fileServer = FileServerSettings(kind: .sftp)
    try repo.write(config, name: "configuration.json")
    try image(1, 0).write(to: root.appendingPathComponent("photo.png"))
    let stat = try await store.stat("photo.png")
    var catalog = MobileCatalog()
    let node = MobileNode(id: "photo", parent: "root", path: "photo.png", name: "photo.png", directory: false, size: stat.size, modified: stat.modified, version: stat.version)
    catalog.record(node); try repo.saveCatalog(catalog, id: location.id)
    let result = try await service.thumbnail(node.id, location: location.id, dimension: 256)
    let bytes = try XCTUnwrap(result)
    let cache = MobileThumbnailCache(repository: repo, policy: MobileBrowsingPolicy())
    let key = MobileThumbnailCache.key(location: location.id, node: node, pixels: 256, vault: false)
    try cache.save(bytes, key: key, encryptionKey: nil, now: Date().addingTimeInterval(-120))
    let before = await store.ioCalls()
    _ = try await service.thumbnail(node.id, location: location.id, dimension: 256)
    let after = await store.ioCalls()
    XCTAssertEqual(after.reads, before.reads + 1)
  }
}
