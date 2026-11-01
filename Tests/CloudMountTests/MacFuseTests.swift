import XCTest
@testable import CloudMount

final class MacFuseTests: XCTestCase {
    func testAutomaticPolicyChecksTheInstalledModuleOSRequirement() {
        let stable = MacFuseInstallation(version: "5.4.0", runtimePresent: true, fsKitMinimumOS: "26.0", kernelLoaded: true, fsKitEnabled: true)
        XCTAssertEqual(stable.resolve(.automatic, systemVersion: "27.0.1"), .fskit)
        XCTAssertEqual(stable.resolve(.automatic, systemVersion: "15.4"), .fuse)
        XCTAssertNil(stable.resolve(.fskit, systemVersion: "15.4"))
        XCTAssertEqual(stable.resolve(.nfs, systemVersion: "27.0.1"), .nfs)
        XCTAssertEqual(stable.resolve(.automatic, systemVersion: "27.0.1", destination: "/tmp/中文"), .fuse)
        XCTAssertEqual(stable.resolve(.automatic, systemVersion: "27.0.1", destination: "/tmp/has space"), .fuse)
        XCTAssertEqual(stable.resolve(.automatic, systemVersion: "27.0.1", readOnly: true), .fuse)
        var disabled = stable; disabled.kernelLoaded = false; disabled.fsKitEnabled = false
        XCTAssertEqual(disabled.resolve(.automatic, systemVersion: "27.0.1"), .nfs)
        XCTAssertNil(disabled.resolve(.fskit, systemVersion: "27.0.1"))
        var modern = stable; modern = MacFuseInstallation(version: "5.5.0", runtimePresent: true, fsKitMinimumOS: "26.0", kernelLoaded: false, fsKitEnabled: true)
        XCTAssertEqual(modern.resolve(.automatic, systemVersion: "26.4", destination: "/tmp/中文", readOnly: true), .fskit)
        XCTAssertEqual(modern.resolve(.automatic, systemVersion: "26.0", readOnly: true), .nfs)
        XCTAssertEqual(MacFuseInstallation.missing.resolve(.automatic, systemVersion: "27.0.1"), .nfs)
        XCTAssertNil(MacFuseInstallation.missing.resolve(.fuse, systemVersion: "27.0.1"))
        for value in [MacFuseInstallation(version: "5.3.3", runtimePresent: true, fsKitMinimumOS: "26.0"),
                      MacFuseInstallation(version: "5.4.0", runtimePresent: false, fsKitMinimumOS: "26.0")] {
            XCTAssertEqual(value.resolve(.automatic, systemVersion: "27.0.1"), .nfs)
            XCTAssertNil(value.resolve(.fuse, systemVersion: "27.0.1"))
        }
    }
    func testCliAndVaultRcUseMatchingFsKitOptionsWithoutNfsFlags() {
        let arguments = RcloneHelpers.mountArguments(method: .fskit, remote: "NAS", folder: "home", destination: "/tmp/test", readOnly: true)
        XCTAssertEqual(arguments.first, "mount")
        XCTAssertEqual(Array(arguments.suffix(3)), ["--read-only", "--option", "backend=fskit"])
        XCTAssertFalse(arguments.contains("locallocks")); XCTAssertFalse(arguments.contains("noquota"))
        XCTAssertEqual(MountMethod.fskit.rcMountType, "cmount")
        XCTAssertEqual(MountMethod.fskit.mountOptions(label: "私人") ["ExtraOptions"] as? [String], ["backend=fskit"])
        XCTAssertFalse(MacFuseInstaller.validArchive(Data("tampered".utf8)))
    }
    @MainActor func testPreferenceDefaultsToAutomaticAndPersistsExplicitNfs() throws {
        let suite = "CloudMountTests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(startup: false, defaults: preferences)
        XCTAssertEqual(model.method, .automatic)
        model.method = .nfs
        XCTAssertEqual(AppModel(startup: false, defaults: preferences).method, .nfs)
        model.method = .automatic
        XCTAssertFalse(model.autoMountEnabled)
    }
    func testOfficialInstallerCanBeDownloadedAndVerifiedWithoutInstalling() async throws {
        guard ProcessInfo.processInfo.environment["CLOUDMOUNT_CHECK_MACFUSE_INSTALLER"] == "1" else { throw XCTSkip("Opt in to downloading the signed official installer; never launches or installs it") }
        let package = try await MacFuseInstaller.prepare()
        XCTAssertEqual(package.pathExtension, "pkg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.deletingLastPathComponent().appendingPathComponent("macFUSE.dmg").path))
        try FileManager.default.removeItem(at: package.deletingLastPathComponent())
    }
    @MainActor func testOrdinaryRemoteUsesMacFuseAndCoalescesMountClicks() async throws {
        guard ProcessInfo.processInfo.environment["CLOUDMOUNT_RUN_MACFUSE_TESTS"] == "1" else { throw XCTSkip("Opt in to one isolated macFUSE remote mount") }
        XCTAssertTrue(MacFuseInstallation.inspect().supportsFSKit(on: MacFuseSupport.systemVersion))
        let executable = try XCTUnwrap(ProcessInfo.processInfo.environment["CLOUDMOUNT_RCLONE_TEST_BINARY"])
        var folder = Bundle(for: MacFuseTests.self).bundleURL.deletingLastPathComponent()
        for _ in 0..<6 {
            if FileManager.default.isExecutableFile(atPath: folder.appendingPathComponent("CloudMountHelper").path) { break }
            folder.deleteLastPathComponent()
        }
        let helper = folder.appendingPathComponent("CloudMountHelper").path
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper))
        let root = try VaultDisk.privateDirectory(URL(fileURLWithPath: "/private/tmp/cmmf-" + UUID().uuidString.prefix(10), isDirectory: true))
        let cloud = root.appendingPathComponent("cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: false)
        let config = root.appendingPathComponent("rclone.conf", isDirectory: false)
        try Data("[fixture]\ntype = local\n".utf8).write(to: config)
        let wrapper = root.appendingPathComponent("rclone", isDirectory: false)
        try Data(("#!/bin/sh\nexec " + RcloneHelpers.shellQuote(executable) + " --config " + RcloneHelpers.shellQuote(config.path) + " \"$@\"\n").utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let suite = "CloudMountTests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(startup: false, defaults: preferences, helperPath: helper)
        model.rclonePath = wrapper.path; model.version = "test"; model.remotes = ["fixture"]; model.selectedRemote = "fixture"
        model.folder = cloud.path; model.destination = root.appendingPathComponent("mount", isDirectory: true).path
        await model.macFuse.refresh(helperPath: helper)
        if ProcessInfo.processInfo.environment["CLOUDMOUNT_REQUIRE_FSKIT"] == "1" {
            guard model.macFuse.installation.fsKitEnabled == true,
                  model.macFuse.resolved(.automatic, destination: model.destination) == .fskit else {
                try FileManager.default.removeItem(at: root)
                throw VaultFailure.message("FSKit is required for this run but is not ready; no mount was started")
            }
        }
        guard let actual = model.macFuse.resolved(.automatic), actual == .fuse || actual == .fskit else {
            try FileManager.default.removeItem(at: root)
            throw XCTSkip("macFUSE needs approval in System Settings")
        }
        func waitForMount() async throws {
            let deadline = Date().addingTimeInterval(35)
            while Date() < deadline {
                if model.mounts.first(where: { $0.destination == model.destination })?.phase.allowsOpening == true { return }
                if let phase = model.mounts.first(where: { $0.destination == model.destination })?.phase, phase == .failed || phase == .blocked { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw VaultFailure.message("isolated macFUSE remote: " + (model.errorMessage ?? model.log))
        }
        func unmount() async -> Bool {
            if let record = model.mounts.first(where: { $0.destination == model.destination }) { model.unmount(record) }
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline, model.mounts.contains(where: { $0.destination == model.destination }) { try? await Task.sleep(nanoseconds: 100_000_000) }
            return !model.mounts.contains(where: { $0.destination == model.destination })
        }
        do {
            for cycle in 0..<2 {
                model.mount(openWhenReady: false); model.mount(openWhenReady: false)
                try await waitForMount()
                XCTAssertEqual(model.mounts.filter { $0.destination == model.destination }.count, 1)
                let snapshot = await model.scanMountedVolumes()
                XCTAssertTrue(snapshot?.contains { $0.destination == model.destination && $0.fileSystem.contains("macfuse") } == true)
                let source = root.appendingPathComponent("source", isDirectory: false)
                try Data("cycle-\(cycle)-first".utf8).write(to: source)
                let destination = model.destination + "/中文.txt"
                let copied = await CommandRunner.execute("/bin/cp", arguments: [source.path, destination], timeout: 8)
                XCTAssertTrue(copied.succeeded, copied.output)
                try Data("cycle-\(cycle)-other".utf8).write(to: source)
                let overwritten = await CommandRunner.execute("/bin/cp", arguments: [source.path, destination], timeout: 8)
                XCTAssertTrue(overwritten.succeeded, overwritten.output)
                let read = await CommandRunner.execute("/bin/cat", arguments: [destination], timeout: 8)
                XCTAssertEqual(read.stdout, "cycle-\(cycle)-other")
                let renamed = await CommandRunner.execute("/bin/mv", arguments: [destination, model.destination + "/renamed.txt"], timeout: 8)
                XCTAssertTrue(renamed.succeeded, renamed.output)
                try await Task.sleep(nanoseconds: 6_000_000_000)
                XCTAssertEqual(try String(contentsOf: cloud.appendingPathComponent("renamed.txt"), encoding: .utf8), "cycle-\(cycle)-other")
                let deleted = await CommandRunner.execute("/bin/rm", arguments: [model.destination + "/renamed.txt"], timeout: 8)
                XCTAssertTrue(deleted.succeeded, deleted.output)
                let clean = await unmount(); XCTAssertTrue(clean, model.errorMessage ?? "")
                guard clean else { throw VaultFailure.invalid }
            }
            try FileManager.default.removeItem(at: root)
        } catch { _ = await unmount(); throw error }
    }
}
