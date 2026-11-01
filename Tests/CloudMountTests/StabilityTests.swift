import XCTest
@testable import CloudMount

final class StabilityTests: XCTestCase {
    func testCommandTimeoutDoesNotWaitForStalledChild() {
        let start = Date()
        let result = CommandRunner.run("/bin/sleep", arguments: ["30"], timeout: 0.2)
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.stillRunning)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
    func testCommandCanBeCancelledAndClosesStdin() {
        let control = CommandControl()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { control.cancel() }
        let result = CommandRunner.run("/bin/sleep", arguments: ["30"], timeout: 10, control: control)
        XCTAssertTrue(result.cancelled)
        XCTAssertFalse(result.stillRunning)
        let eof = CommandRunner.run("/bin/sh", arguments: ["-c", "read value; printf 'closed'"])
        XCTAssertEqual(eof.stdout, "closed")
    }
    func testNoisyCommandIsBoundedAndBothPipesDrain() {
        let result = CommandRunner.run("/bin/sh", arguments: ["-c", "i=0; while [ $i -lt 5000 ]; do printf 'stdout-line\n'; printf 'stderr-line\n' >&2; i=$((i+1)); done"], timeout: 10, outputLimit: 1024)
        XCTAssertTrue(result.succeeded)
        XCTAssertLessThanOrEqual(result.stdout.utf8.count, 1024)
        XCTAssertLessThanOrEqual(result.stderr.utf8.count, 1024)
        XCTAssertTrue(result.stdout.contains("stdout-line"))
        XCTAssertTrue(result.stderr.contains("stderr-line"))
    }
    func testInheritedPipeFromChildDoesNotBlockCompletion() {
        let start = Date()
        let result = CommandRunner.run("/bin/sh", arguments: ["-c", "/bin/sleep 2 & printf done"], timeout: 5)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout, "done")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }
    func testDisabledAutoMountNeverRequestsAnyRemote() {
        XCTAssertEqual(AutoMountPolicy.requestedRemotes(enabled: false, selected: ["NAS"], available: ["NAS"], recovering: false, quitting: false), [])
        XCTAssertEqual(AutoMountPolicy.requestedRemotes(enabled: true, selected: [], available: ["NAS"], recovering: false, quitting: false), [])
        XCTAssertEqual(AutoMountPolicy.requestedRemotes(enabled: true, selected: ["NAS"], available: ["NAS", "Other"], recovering: false, quitting: false), ["NAS"])
        XCTAssertEqual(AutoMountPolicy.requestedRemotes(enabled: true, selected: ["NAS"], available: ["NAS"], recovering: true, quitting: false), [])
        XCTAssertEqual(AutoMountPolicy.requestedRemotes(enabled: true, selected: ["NAS"], available: ["NAS"], recovering: false, quitting: true), [])
    }
    func testRefreshRetainsInProgressMountsAndDoesNotMistakeApiSuccessForMounting() {
        let id = UUID()
        for phase in [MountPhase.preparing, .connecting, .unmounting, .blocked] {
            let record = MountRecord(id: id, remote: "NAS", folder: "", destination: "/test", phase: phase, owned: true)
            XCTAssertTrue(record.retainedAfterScan(paths: [], hasProcess: false))
        }
        let mounted = MountRecord(id: id, remote: "NAS", folder: "", destination: "/test", phase: .mounted, owned: false)
        XCTAssertFalse(mounted.retainedAfterScan(paths: [], hasProcess: false))
        XCTAssertTrue(mounted.retainedAfterScan(paths: ["/test"], hasProcess: false))
        XCTAssertTrue(mounted.retainedAfterScan(paths: [], hasProcess: true))
    }
    func testPathAliasesAndRemoteNamesCannotBypassChecks() {
        XCTAssertTrue(RcloneHelpers.pathsEqual("/Users/example/NAS", "/Users/example/nas"))
        XCTAssertTrue(RcloneHelpers.pathContains("/Cloud/NAS", "/cloud/nas/child"))
        XCTAssertFalse(RcloneHelpers.pathContains("/Cloud/NAS", "/Cloud/NAS-backup"))
        for name in ["NAS", "我的雲端", "WebDAV-2", "My Cloud"] { XCTAssertTrue(RcloneHelpers.isValidRemoteName(name)) }
        for name in ["", "-flag", "a/b", "a:b", "a\nkey=secret"] { XCTAssertFalse(RcloneHelpers.isValidRemoteName(name)) }
    }
    func testPersistentLogIsCapturedWithoutAnApplicationPipe() throws {
        let path = "/private/tmp/CloudMount-log-test-" + UUID().uuidString + "/mount.log"
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path) }
        let result = CommandRunner.run("/bin/sh", arguments: ["-c", "printf 'persistent-line\\n' > \"$1\"", "log-test", path], logFile: path)
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.stdout.contains("persistent-line"))
    }
    func testSensitiveErrorsAreRedacted() {
        let log = RcloneHelpers.redactLog("https://demo:supersecret@example.com/?access_token=abcdef Authorization: Bearer TOKEN123 password=\"a secret phrase\"")
        for secret in ["supersecret", "abcdef", "TOKEN123", "a secret phrase"] { XCTAssertFalse(log.contains(secret)) }
    }
    func testRedactedConfigNeverBecomesAnEditableCredential() {
        let value = AppModel.parseRedactedRemote("NAS", output: "[NAS]\ntype = webdav\nurl = https://example.invalid\npass = XXX\nbearer_token = *** REDACTED ***\n")
        XCTAssertEqual(value?.type, "webdav")
        XCTAssertNil(value?.values["pass"])
        XCTAssertNil(value?.values["bearer_token"])
    }
}

final class ProviderSchemaTests: XCTestCase {
    private func providers() throws -> [RcloneProvider] {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "providers", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode([RcloneProvider].self, from: Data(contentsOf: file))
    }
    func testS3EndpointValidationAndCompatibleDefault() throws {
        let s3 = try XCTUnwrap(providers().first { $0.prefix == "s3" })
        func policy(_ values: [String: String]) -> ProviderFormPolicy { ProviderFormPolicy(provider: s3, values: values) }
        XCTAssertEqual(policy([:]).effectiveProvider, "Other")
        XCTAssertNotNil(policy([:]).validationError)
        for endpoint in ["https://storage.example:9200", "http://192.168.1.10:9000"] {
            XCTAssertNil(policy(["endpoint": endpoint]).validationError)
        }
        XCTAssertNil(policy(["provider": "AWS"]).validationError)
        for endpoint in ["storage.example:9200", "ftp://example.com", "https://user:password@example.com", "https://example.com?secret=1", "https://example.com:70000"] {
            XCTAssertNotNil(policy(["endpoint": endpoint]).validationError, endpoint)
        }
    }
    func testEveryBackendAndProviderVariantHasCompleteDisjointFormGroups() throws {
        let providers = try providers()
        XCTAssertEqual(providers.count, 69)
        XCTAssertEqual(providers.reduce(0) { $0 + $1.options.count }, 968)
        var audit = ["backend,variant,total,basic,optional,advanced,basic_fields"]
        for provider in providers {
            let variants = provider.options.first(where: { $0.name == "provider" })?.examples.map(\.value) ?? [""]
            for variant in variants.isEmpty ? [""] : variants {
                let policy = ProviderFormPolicy(provider: provider, values: ["provider": variant])
                let grouped = policy.basic + policy.optional + policy.advanced
                if provider.prefix == "s3" {
                    for field in ["region", "endpoint", "force_path_style"] { XCTAssertTrue(policy.basic.contains { $0.name == field }, variant + ":" + field) }
                }
                audit.append([provider.prefix, variant, String(provider.options.count), String(policy.basic.count), String(policy.optional.count), String(policy.advanced.count), policy.basic.map(\.name).joined(separator: "|")].joined(separator: ","))
                XCTAssertEqual(Set(grouped.map(\.name)), Set(policy.eligible.map(\.name)), provider.prefix + ":" + variant)
                XCTAssertEqual(grouped.count, Set(grouped.map(\.name)).count)
                for option in policy.eligible where option.required && (option.defaultValue ?? "").isEmpty {
                    XCTAssertTrue(policy.basic.contains(where: { $0.name == option.name }), provider.prefix + ":" + option.name)
                }
            }
        }
        if let path = ProcessInfo.processInfo.environment["CLOUDMOUNT_PROVIDER_AUDIT_PATH"] {
            try audit.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    func testCommonServicesHaveSmallUsefulForms() throws {
        let providers = try providers()
        func policy(_ prefix: String, _ values: [String: String] = [:]) throws -> ProviderFormPolicy {
            ProviderFormPolicy(provider: try XCTUnwrap(providers.first { $0.prefix == prefix }), values: values)
        }
        XCTAssertEqual(try policy("webdav").basic.map(\.name), ["url", "user", "pass"])
        XCTAssertEqual(try policy("drime").basic.map(\.name), ["access_token"])
        XCTAssertEqual(try policy("internxt").basic.map(\.name), ["email", "pass"])
        XCTAssertEqual(try policy("drive").basic.count, 0)
        XCTAssertFalse(try policy("s3", ["provider": "AWS"]).eligible.contains { $0.name == "ibm_api_key" })
        XCTAssertTrue(try policy("s3", ["provider": "IBMCOS"]).eligible.contains { $0.name == "ibm_api_key" })
    }
    func testMissingCredentialsAndInvalidUrlAreCaughtBeforeCli() throws {
        let providers = try providers()
        let webdav = try XCTUnwrap(providers.first { $0.prefix == "webdav" })
        XCTAssertNotNil(ProviderFormPolicy(provider: webdav, values: ["url": "example.com"]).validationError)
        XCTAssertNotNil(ProviderFormPolicy(provider: webdav, values: ["url": "https://user:pass@example.com"]).validationError)
        XCTAssertNil(ProviderFormPolicy(provider: webdav, values: ["url": "https://example.com/dav"]).validationError)
        let internxt = try XCTUnwrap(providers.first { $0.prefix == "internxt" })
        XCTAssertNotNil(ProviderFormPolicy(provider: internxt, values: ["email": "demo@example.com"]).validationError)
        XCTAssertNil(ProviderFormPolicy(provider: internxt, values: ["email": "demo@example.com"], editing: true).validationError)
        let drime = try XCTUnwrap(providers.first { $0.prefix == "drime" })
        XCTAssertTrue(drime.options.first { $0.name == "access_token" }?.isSecret == true)
        let sftp = try XCTUnwrap(providers.first { $0.prefix == "sftp" })
        XCTAssertFalse(try XCTUnwrap(sftp.options.first { $0.name == "host" }).isSecret)
        XCTAssertFalse(try XCTUnwrap(internxt.options.first { $0.name == "email" }).isSecret)
        let storj = try XCTUnwrap(providers.first { $0.prefix == "storj" })
        XCTAssertTrue(ProviderFormPolicy(provider: storj, values: [:]).eligible.contains { $0.name == "access_grant" })
        let editing = ProviderFormPolicy(provider: webdav, values: ["url": "https://example.com", "user": "", "pass": ""], editing: true)
        XCTAssertEqual(editing.submittedValues["user"], "")
        XCTAssertNil(editing.submittedValues["pass"])
        XCTAssertNotNil(ProviderFormPolicy(provider: drime, values: [:]).validationError)
    }
}

final class LocalIntegrationTests: XCTestCase {
    private var helper: String {
        var folder = Bundle(for: LocalIntegrationTests.self).bundleURL.deletingLastPathComponent()
        for _ in 0..<6 {
            let path = folder.appendingPathComponent("CloudMountHelper").path
            if FileManager.default.isExecutableFile(atPath: path) { return path }
            folder.deleteLastPathComponent()
        }
        return "missing-helper"
    }
    func testHelperRejectsDataDirectoriesAndSymlinksWithoutModifyingThem() throws {
        // A local temporary folder only; no real cloud mounts are created.
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("CloudMount-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("empty")
        let prepared = CommandRunner.run(helper, arguments: ["prepare", empty.path])
        XCTAssertTrue(prepared.succeeded, prepared.output)
        let metadata = empty.appendingPathComponent(".DS_Store")
        try Data("metadata".utf8).write(to: metadata)
        let allowed = CommandRunner.run(helper, arguments: ["prepare", empty.path])
        XCTAssertTrue(allowed.succeeded, allowed.output)
        let plan = try JSONDecoder().decode(MountPreparation.self, from: Data(allowed.stdout.utf8))
        XCTAssertTrue(plan.allowNonEmpty)
        let data = empty.appendingPathComponent("important.txt")
        try Data("keep".utf8).write(to: data)
        let blocked = CommandRunner.run(helper, arguments: ["prepare", empty.path])
        XCTAssertFalse(blocked.succeeded)
        XCTAssertTrue(blocked.stderr.contains("important.txt"))
        XCTAssertEqual(try String(contentsOf: data), "keep")
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: empty)
        XCTAssertTrue(CommandRunner.run(helper, arguments: ["prepare", link.path]).stderr.contains("symlink_path"))
        XCTAssertFalse(CommandRunner.run(helper, arguments: ["prepare", "/"]).succeeded)
    }
    func testRealRcloneConfigFlowInIsolatedFile() throws {
        guard let binary = ProcessInfo.processInfo.environment["CLOUDMOUNT_RCLONE_TEST_BINARY"] else { throw XCTSkip("Set CLOUDMOUNT_RCLONE_TEST_BINARY for isolated CLI integration checks") }
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("CloudMount-config-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let flags = ["--config", root.appendingPathComponent("rclone.conf").path, "--ask-password=false"]
        let setup = RcloneHelpers.configurationStartArguments(remote: "NAS", provider: "webdav", updating: false,
            values: ["url": "https://example.invalid", "vendor": "other", "user": "demo", "pass": "--dummy-password"])
        let result = CommandRunner.run(binary, arguments: flags + setup)
        XCTAssertTrue(result.succeeded, result.output)
        let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        XCTAssertEqual(json?["State"] as? String, "")
        let redacted = CommandRunner.run(binary, arguments: ["config", "redacted", "NAS", "--config", root.appendingPathComponent("rclone.conf").path, "--ask-password=false"])
        XCTAssertTrue(redacted.succeeded)
        XCTAssertFalse(redacted.stdout.contains("dummy-password"))
    }
}
