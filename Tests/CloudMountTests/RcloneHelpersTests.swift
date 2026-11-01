import XCTest
@testable import CloudMount

final class RcloneHelpersTests: XCTestCase {
    @MainActor
    func testChangingBucketDoesNotOpenExistingDifferentMount() async throws {
        guard let binary = ProcessInfo.processInfo.environment["CLOUDMOUNT_RCLONE_TEST_BINARY"] else { throw XCTSkip("Set the bundled rclone path") }
        let suite = "CloudMount-MountTarget-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let model = AppModel(startup: false, defaults: defaults, helperPath: "/bin/false")
        model.vaults = VaultManager(model: model, root: root)
        model.rclonePath = binary; model.version = "rclone test"; model.remotes = ["S3"]; model.selectedRemote = "S3"
        model.folder = "new-bucket"; model.destination = "/private/tmp/CloudMount-target-test"
        model.mounts = [MountRecord(id: UUID(), remote: "S3", folder: "old-bucket", destination: model.destination, phase: .mounted, owned: true)]
        model.mount(openWhenReady: false)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(model.errorMessage, L10n.string("這個位置已掛載其他儲存桶或資料夾。請先卸載，再切換掛載內容。"))
        XCTAssertEqual(model.mounts.count, 1)
        XCTAssertEqual(model.mounts.first?.folder, "old-bucket")
        XCTAssertNil(model.startingMountID)
    }

    @MainActor
    func testS3BucketControlsAreAvailableWithoutOpeningVaultSetup() async throws {
        guard let binary = ProcessInfo.processInfo.environment["CLOUDMOUNT_RCLONE_TEST_BINARY"] else { throw XCTSkip("Set the bundled rclone path for the isolated refresh integration test") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudMount-S3Refresh-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("rclone.conf")
        try "[Storage]\ntype = s3\nprovider = Other\nendpoint = https://example.invalid\n".write(to: config, atomically: true, encoding: .utf8)
        let wrapper = root.appendingPathComponent("rclone-test")
        try ("#!/bin/sh\nexec " + RcloneHelpers.shellQuote(binary) + " --config " + RcloneHelpers.shellQuote(config.path) + " \"$@\"\n").write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let suite = "CloudMount-S3Refresh-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let helper = URL(fileURLWithPath: binary).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("CloudMount.app/Contents/Helpers/CloudMountHelper").path
        let model = AppModel(startup: false, defaults: defaults, helperPath: helper)
        model.rclonePath = wrapper.path
        model.vaults = VaultManager(model: model, root: root.appendingPathComponent("vaults"), configurationPath: config.path, openFinderAutomatically: false)
        model.refresh()
        let deadline = Date().addingTimeInterval(20)
        while model.isRefreshing && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(model.isRefreshing)
        XCTAssertEqual(model.remotes, ["Storage"])
        XCTAssertTrue(model.selectedRemoteIsS3)
        XCTAssertFalse(model.autoMountEnabled)
        XCTAssertFalse(model.mounts.contains { $0.owned })
    }

    func testS3CustomEndpointDoesNotDefaultToAWSVirtualHosting() {
        XCTAssertTrue(RcloneHelpers.s3AllowsPathStyle(provider: "Other"))
        XCTAssertTrue(RcloneHelpers.s3AllowsPathStyle(provider: "Minio"))
        XCTAssertTrue(RcloneHelpers.s3AllowsPathStyle(provider: "Cloudflare"))
        XCTAssertFalse(RcloneHelpers.s3AllowsPathStyle(provider: "AWS"))
        XCTAssertEqual(RcloneHelpers.normalizedConfigurationValues(provider: "s3", values: ["endpoint": "https://storage.example:9200"])["provider"], "Other")
        XCTAssertEqual(RcloneHelpers.normalizedConfigurationValues(provider: "s3", values: ["provider": "AWS"])["provider"], "AWS")
        XCTAssertTrue(RcloneHelpers.s3NeedsCompatibleProvider(["provider": "AWS", "endpoint": "https://storage.example:9200"]))
        for endpoint in ["", "https://s3.us-east-1.amazonaws.com", "https://bucket.vpce-123.s3.us-east-1.vpce.amazonaws.com", "https://s3.cn-north-1.amazonaws.com.cn"] {
            XCTAssertFalse(RcloneHelpers.s3NeedsCompatibleProvider(["provider": "AWS", "endpoint": endpoint]))
        }
        XCTAssertFalse(RcloneHelpers.s3NeedsCompatibleProvider(["provider": "Minio", "endpoint": "https://storage.example"]))
    }

    func testS3BucketAndSubfolderRemainSeparate() {
        XCTAssertEqual(RcloneHelpers.s3MountPath(bucket: " photos ", subfolder: " /2026/旅行/ "), "photos/2026/旅行")
        XCTAssertEqual(RcloneHelpers.s3MountPath(bucket: "", subfolder: "2026"), "")
        let split = RcloneHelpers.splitS3MountPath("photos/2026/旅行")
        XCTAssertEqual(split.bucket, "photos")
        XCTAssertEqual(split.subfolder, "2026/旅行")
        for bucket in ["photos", "legacy_Bucket", "media.example", "我的文件", "App For MAC"] { XCTAssertNil(RcloneHelpers.s3BucketError(bucket)) }
        for bucket in ["", "  ", "\n"] { XCTAssertEqual(RcloneHelpers.s3BucketError(bucket), L10n.string("請填寫或選擇 S3 儲存桶名稱。")) }
        for invalid in ["https://example.com", "bucket/folder", "../bucket", "bucket\nname"] { XCTAssertNotNil(RcloneHelpers.s3BucketError(invalid)) }
        XCTAssertNil(RcloneHelpers.s3PrefixError(bucket: "bucket", prefix: "notes/中文/"))
        XCTAssertNil(RcloneHelpers.s3PrefixError(bucket: "", prefix: ""))
        XCTAssertNotNil(RcloneHelpers.s3PrefixError(bucket: "", prefix: "notes"))
        XCTAssertNotNil(RcloneHelpers.s3PrefixError(bucket: "bucket", prefix: "notes/../outside"))
        XCTAssertEqual(RcloneHelpers.remoteErrorStatus(in: "operation error S3: ListObjectsV2 lookup bucket.example: no such host"), L10n.string("S3 網址無法解析"))
    }

    @MainActor
    func testMountPreferencesArePerRemoteAndSurviveRelaunch() throws {
        let suite = "CloudMount-S3Preferences-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(startup: false, defaults: defaults)
        model.setPreferredMountFolder("photos/2026", for: "S3")
        model.setPreferredMountFolder("home", for: "NAS")
        model.selectedRemote = "S3"
        XCTAssertEqual(model.folder, "photos/2026")
        model.selectedRemote = "NAS"
        XCTAssertEqual(model.folder, "home")
        model.selectedRemote = "Other"
        XCTAssertEqual(model.folder, "")
        let relaunched = AppModel(startup: false, defaults: defaults)
        relaunched.selectedRemote = "S3"
        XCTAssertEqual(relaunched.folder, "photos/2026")
        relaunched.setPreferredMountFolder("", for: "S3")
        XCTAssertEqual(relaunched.folder, "")
    }

    func testMountDirectoryIgnoresOnlyHarmlessFinderMetadata() {
        XCTAssertEqual(RcloneHelpers.mountDirectoryBlockers([".DS_Store", ".localized"]), [])
        XCTAssertEqual(RcloneHelpers.mountDirectoryBlockers([".DS_Store", "important.txt"]), ["important.txt"])
    }

    func testRemoteListAndMountArguments() {
        XCTAssertEqual(RcloneHelpers.parseRemotes("zeta:\ndrime:\n\n"), ["drime", "zeta"])
        XCTAssertEqual(
            RcloneHelpers.mountArguments(method: .nfs, remote: "drime", folder: "Photos/2026",
                                          destination: "/tmp/My Cloud", readOnly: true),
            ["nfsmount", "drime:Photos/2026", "/tmp/My Cloud", "--vfs-cache-mode", "writes",
             "--vfs-cache-max-size", "20G", "--vfs-cache-max-age", "24h",
             "--volname", "drime"] + MountCachePolicy.arguments(directoryMinutes: 5) + ["--read-only", "--option", "locallocks", "--option", "noquota"]
        )
    }

    func testAbsoluteSftpAndLocalPathsAreNotRewritten() {
        XCTAssertEqual(RcloneHelpers.remotePath(name: "sftp", folder: " /var/data/ "), "sftp:/var/data/")
        XCTAssertEqual(RcloneHelpers.remotePath(name: "sftp", folder: "/"), "sftp:/")
        XCTAssertEqual(RcloneHelpers.remotePath(name: "local", folder: "/Users/example/Files"), "local:/Users/example/Files")
        XCTAssertEqual(RcloneHelpers.remotePath(name: "sftp", folder: "relative"), "sftp:relative")
    }
    func testMountArgumentsApplyUserCacheSettings() {
        XCTAssertEqual(
            RcloneHelpers.mountArguments(method: .fuse, remote: "drime", folder: "", destination: "/tmp/drime",
                                         readOnly: false, cacheReadFiles: true, cacheMaxSizeGB: 50, cacheMaxAgeHours: 72),
            ["mount", "drime:", "/tmp/drime", "--vfs-cache-mode", "full",
             "--vfs-cache-max-size", "50G", "--vfs-cache-max-age", "72h", "--volname", "drime"] + MountCachePolicy.arguments(directoryMinutes: 5)
        )
    }

    func testMountArgumentsDoNotPassExperimentalLocalFlag() {
        let fuseArguments = RcloneHelpers.mountArguments(
            method: .fuse, remote: "drime", folder: "", destination: "/tmp/drime",
            readOnly: false
        )
        XCTAssertFalse(fuseArguments.contains("local"))

        let nfsArguments = RcloneHelpers.mountArguments(
            method: .nfs, remote: "drime", folder: "", destination: "/tmp/drime",
            readOnly: false
        )
        XCTAssertFalse(nfsArguments.contains("local"))
    }

    func testAllowNonEmptyIsExplicitAndFuseOnly() {
        let fuseArguments = RcloneHelpers.mountArguments(
            method: .fuse, remote: "drime", folder: "", destination: "/tmp/drime",
            readOnly: false, allowNonEmpty: true
        )
        XCTAssertTrue(fuseArguments.contains("--allow-non-empty"))

        let nfsArguments = RcloneHelpers.mountArguments(
            method: .nfs, remote: "drime", folder: "", destination: "/tmp/drime",
            readOnly: false, allowNonEmpty: true
        )
        XCTAssertFalse(nfsArguments.contains("--allow-non-empty"))
    }

    func testMountedVolumeDetectionForNFSAndMacFUSE() {
        let output = """
        localhost:/ on /Users/eric/CloudMounts/drime (nfs, nodev, nosuid, mounted by eric)
        drime: on /Users/eric/DrimeCloud (macfuse, nodev, nosuid, synchronous, mounted by eric)
        backup:/ on /Volumes/Backup (nfs, nodev, nosuid, mounted by eric)
        NAS: on /Users/eric/CloudMounts/NAS (macfuse, nodev, nosuid, synchronous, mounted by eric)
        /dev/disk9s1 on /Volumes/CloudMount (apfs, local, nodev, nosuid)
        """

        let volumes = RcloneHelpers.parseMountedVolumes(
            output, remotes: ["drime"], homeDirectory: "/Users/eric"
        )

        XCTAssertEqual(volumes.count, 4)
        XCTAssertEqual(volumes[0].remote, "drime")
        XCTAssertEqual(volumes[0].destination, "/Users/eric/CloudMounts/drime")
        XCTAssertEqual(volumes[1].remote, "drime")
        XCTAssertEqual(volumes[1].destination, "/Users/eric/DrimeCloud")
        XCTAssertNil(volumes[2].remote)
        XCTAssertEqual(volumes[3].remote, "NAS")
        XCTAssertFalse(volumes[3].remoteConfigured)
        XCTAssertFalse(volumes.contains(where: { $0.fileSystem == "apfs" }))
    }

    func testShellQuoteKeepsExecutablePathLiteral() {
        XCTAssertEqual(RcloneHelpers.shellQuote("/tmp/it's rclone"), "'/tmp/it'\\''s rclone'")
    }

    func testConfigurationQuestionAllowsOptionalBlankAndRequiresRequiredValue() throws {
        let optionalQuestion = try JSONDecoder().decode(RcloneConfigQuestion.self, from: Data(#"{"State":"s1","Option":{"Name":"vendor","Required":false},"Error":""}"#.utf8))
        let requiredQuestion = try JSONDecoder().decode(RcloneConfigQuestion.self, from: Data(#"{"State":"s2","Option":{"Name":"token","Required":true},"Error":""}"#.utf8))

        XCTAssertTrue(optionalQuestion.accepts(answer: ""))
        XCTAssertTrue(optionalQuestion.accepts(answer: "   "))
        XCTAssertFalse(requiredQuestion.accepts(answer: "  \n"))
        XCTAssertTrue(requiredQuestion.accepts(answer: "token-value"))
    }

    func testRemoteErrorStatusClassifiesAuthenticationFailures() {
        XCTAssertEqual(RcloneHelpers.remoteErrorStatus(in: "Statfs failed: 401 Unauthorized"), L10n.string("驗證失敗（401）"))
        XCTAssertEqual(RcloneHelpers.remoteErrorStatus(in: "403 Forbidden"), L10n.string("存取遭拒（403）"))
        XCTAssertNil(RcloneHelpers.remoteErrorStatus(in: "directory listing succeeded"))
    }

    func testConfigurationContinuationObscuresPasswordsAgain() {
        let arguments = RcloneHelpers.configurationContinuationArguments(
            remote: "NAS", state: "vendor-state", answer: "", defaults: [
                "url": "https://example.invalid", "user": "demo",
                "pass": "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234", "vendor": ""
            ]
        )

        XCTAssertTrue(arguments.contains("--obscure"))
        XCTAssertTrue(arguments.contains("pass"))
        XCTAssertTrue(arguments.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ1234"))
        XCTAssertFalse(arguments.contains("vendor"))
    }

    func testWebDAVUsesGenericVendorWhenNoVendorWasSelected() {
        XCTAssertEqual(
            RcloneHelpers.normalizedConfigurationValues(provider: "webdav", values: ["url": "https://example.invalid"]),
            ["url": "https://example.invalid", "vendor": "other"]
        )
        XCTAssertEqual(
            RcloneHelpers.normalizedConfigurationValues(provider: "webdav", values: ["vendor": "nextcloud"])["vendor"],
            "nextcloud"
        )
        XCTAssertNil(RcloneHelpers.normalizedConfigurationValues(provider: "s3", values: [:])["vendor"])
    }

    func testTransferDirectionAndDryRun() {
        XCTAssertEqual(
            RcloneHelpers.transferArguments(command: "sync", remote: "drime", remoteFolder: "Backup",
                                            local: "/tmp/local", direction: .download, dryRun: true),
            ["sync", "drime:Backup", "/tmp/local", "--dry-run", "--stats", "5s"]
        )
    }
}
