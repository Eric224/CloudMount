import XCTest
@testable import CloudMount

final class MountCachePolicyTests: XCTestCase {
    func testBundledEngineAcceptsCachePolicyForBothMountMethods() async throws {
        guard let binary = ProcessInfo.processInfo.environment["CLOUDMOUNT_RCLONE_TEST_BINARY"] else { throw XCTSkip("Set bundled rclone path") }
        for command in ["mount", "nfsmount"] {
            let result = await CommandRunner.execute(binary,
                arguments: [command, "--help"] + MountCachePolicy.arguments(directoryMinutes: 5), timeout: 5)
            XCTAssertTrue(result.succeeded, result.output)
        }
    }

    @MainActor func testRemoteCannotBeCreatedWithoutRequiredS3Bucket() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "providers", withExtension: "json", subdirectory: "Fixtures"))
        let providers = try JSONDecoder().decode([RcloneProvider].self, from: Data(contentsOf: url))
        let provider = try XCTUnwrap(providers.first { $0.prefix == "s3" })
        let suite = "CloudMount-RequiredBucket-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(startup: false, defaults: defaults)
        model.createRemote(name: "S3", provider: provider, values: ["provider": "AWS"], mountFolder: "")
        XCTAssertEqual(model.configurationError, L10n.string("請填寫或選擇 S3 儲存桶名稱。"))
        XCTAssertFalse(model.isConfiguringRemote)
        XCTAssertFalse(model.configurationWriterActive)
    }

    func testCachePolicyBoundsResourcesWithoutWeakeningChangeDetection() {
        let arguments = MountCachePolicy.arguments(directoryMinutes: 900)
        func option(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        XCTAssertEqual(option("--dir-cache-time"), "60m")
        XCTAssertEqual(option("--buffer-size"), "4M")
        XCTAssertEqual(option("--max-buffer-memory"), "64M")
        XCTAssertEqual(option("--vfs-read-chunk-streams"), "0")
        XCTAssertEqual(option("--vfs-cache-min-free-space"), "1G")
        for unsafe in ["--vfs-fast-fingerprint", "--no-modtime", "--no-checksum", "--s3-no-head", "--fast-list", "--vfs-refresh"] {
            XCTAssertFalse(arguments.contains(unsafe))
        }
        let options = MountCachePolicy.vaultOptions(sizeGB: Int.max, ageHours: Int.max, directoryMinutes: -2)
        XCTAssertEqual(options["CacheMaxSize"] as? Int64, 1_073_741_824_000)
        XCTAssertEqual(options["CacheMaxAge"] as? Int64, 31_536_000_000_000_000)
        XCTAssertEqual(options["DirCacheTime"] as? Int64, 60_000_000_000)
        XCTAssertEqual(options["CacheMode"] as? Int, 3)
        XCTAssertEqual(options["ChunkSize"] as? Int, 8_388_608)
    }

    @MainActor func testCacheDefaultsAndExplicitOptOutSurviveRelaunch() throws {
        let suite = "CloudMount-Cache-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = AppModel(startup: false, defaults: defaults)
        XCTAssertTrue(first.cacheReadFiles)
        XCTAssertEqual(first.cacheDirectoryMinutes, 5)
        first.cacheReadFiles = false; first.cacheDirectoryMinutes = 12
        let second = AppModel(startup: false, defaults: defaults)
        XCTAssertFalse(second.cacheReadFiles)
        XCTAssertEqual(second.cacheDirectoryMinutes, 12)
    }
}
