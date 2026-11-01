import XCTest
import CryptoKit
import Combine
import CloudMountVaultCore
@testable import CloudMount

final class VaultCryptoTests: XCTestCase {
    func testPortableEnvelopeWrongPasswordAndRecovery() throws {
        let (created, keys) = try VaultEnvelope.create(name: "私人文件", password: "a-long-test-password")
        let bytes = try JSONEncoder().encode(created)
        let remote = try VaultEnvelope.decode(bytes)
        XCTAssertEqual(try remote.unlock(password: "a-long-test-password"), keys)
        XCTAssertEqual(try remote.recover(code: keys.recoveryCode), keys)
        XCTAssertThrowsError(try remote.unlock(password: "incorrect-password"))
        XCTAssertThrowsError(try remote.recover(code: String(repeating: "0", count: 64)))
        let text = String(decoding: bytes, as: UTF8.self)
        for secret in ["a-long-test-password", keys.password, keys.salt, keys.recoveryCode] { XCTAssertFalse(text.contains(secret)) }
        XCTAssertEqual(try remote.unlock(password: "a-long-test-password"), try created.unlock(password: "a-long-test-password"))
    }
    func testTamperedHeaderAndPayloadAreRejectedBeforeAnyWriting() throws {
        let (created, _) = try VaultEnvelope.createLegacyFixture(name: "Vault", password: "a-long-test-password")
        let bytes = try JSONEncoder().encode(created)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object["name"] = "changed"
        let tamperedName = try VaultEnvelope.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try tamperedName.unlock(password: "a-long-test-password"))
        object["iterations"] = 2_000_000_000
        XCTAssertThrowsError(try VaultEnvelope.decode(JSONSerialization.data(withJSONObject: object)))
        XCTAssertThrowsError(try VaultEnvelope.decode(Data(repeating: 0, count: 65_536)))
        XCTAssertThrowsError(try VaultEnvelope.create(name: "Vault", password: "short"))
    }
    func testEachVaultHasIndependentKeysAndWriterAuthentication() throws {
        let (_, a) = try VaultEnvelope.create(name: "A", password: "a-long-test-password")
        let (_, b) = try VaultEnvelope.create(name: "B", password: "a-long-test-password")
        XCTAssertNotEqual(a.password, b.password)
        XCTAssertNotEqual(a.salt, b.salt)
        let lease = VaultLease.make(a, device: UUID())
        XCTAssertTrue(lease.valid(a))
        XCTAssertFalse(lease.valid(b))
        let changed = VaultLease(vault: lease.vault, device: UUID(), signature: lease.signature)
        XCTAssertFalse(changed.valid(a))
    }
    func testPortableRecoveryFileAndCloudLocationRules() throws {
        let (envelope, keys) = try VaultEnvelope.create(name: "Vault", password: "a-long-test-password")
        let backup = VaultRecoveryFile(format: "CloudMountRecovery-v1", envelope: envelope, code: keys.recoveryCode, folder: "bucket/.cloudmount-vaults/example")
        let decoded = try JSONDecoder().decode(VaultRecoveryFile.self, from: JSONEncoder().encode(backup))
        XCTAssertEqual(try decoded.secrets(), keys)
        XCTAssertEqual(try VaultLocation.parent("bucket/photos", s3: true), "bucket/photos/.cloudmount-vaults")
        XCTAssertEqual(try VaultLocation.parent("", s3: false), ".cloudmount-vaults")
        for invalid in ["", "bucket/../private", "a:b", "a\nb"] { XCTAssertThrowsError(try VaultLocation.parent(invalid, s3: true)) }
    }
    func testUploadStateDoesNotTreatVfsReferenceAsOpenFileAndFailsClosed() throws {
        var disk: [String: Any] = ["uploadsQueued": 0, "uploadsInProgress": 0, "erroredFiles": 0, "outOfSpace": false]
        XCTAssertTrue(try VaultUploadState.parse(["inUse": 1, "diskCache": disk]).clean)
        for name in ["uploadsQueued", "uploadsInProgress", "erroredFiles"] {
            var changed = disk; changed[name] = 1
            XCTAssertFalse(try VaultUploadState.parse(["inUse": 1, "diskCache": changed]).clean)
        }
        disk["outOfSpace"] = true
        XCTAssertFalse(try VaultUploadState.parse(["inUse": 1, "diskCache": disk]).clean)
        XCTAssertThrowsError(try VaultUploadState.parse([:]))
    }
    func testRetryingFinderSettingsAreNotReportedAsActiveEncryption() throws {
        let state = VaultUploadState(references: 1, queued: 1, uploading: 0, errors: 0, outOfSpace: false)
        let queue: [String: Any] = ["queue": [["name": ".DS_Store", "tries": 8, "uploading": false, "expiry": 196.05]]]
        let report = try VaultUploadReport.make(state: state, queue: queue, dirty: 1,
            lastError: "failed to delete existing object: localized service error")
        XCTAssertEqual(report.phase, .retrying)
        XCTAssertTrue(report.finderSettingsOnly)
        XCTAssertTrue(report.replacementCleanupFailed)
        XCTAssertEqual(report.retryAfter, 197)
        XCTAssertEqual(report.uploading, 0)
        XCTAssertEqual(report.queued, 0)
        XCTAssertTrue(report.warning)
        XCTAssertFalse(try VaultUploadReport.make(state: state, queue: queue, dirty: 2, lastError: nil).finderSettingsOnly)
        let two: [String: Any] = ["queue": [
            ["name": "first", "tries": 1, "uploading": false, "expiry": 300.0],
            ["name": "second", "tries": 1, "uploading": false, "expiry": 10.0]]]
        XCTAssertEqual(try VaultUploadReport.make(state: state, queue: two, dirty: 2, lastError: nil).retryAfter, 10)
        // Neither a document nor an AppleDouble resource fork is dismissed as
        // disposable Finder settings, and historical errors do not stick.
        for name in ["Report.docx", "._Report.docx"] {
            let q: [String: Any] = ["queue": [["name": name, "tries": 1, "uploading": false, "expiry": 0.0]]]
            XCTAssertFalse(try VaultUploadReport.make(state: state, queue: q, dirty: 1, lastError: nil).finderSettingsOnly)
        }
        let clean = VaultUploadState(references: 1, queued: 0, uploading: 0, errors: 0, outOfSpace: false)
        let recovered = try VaultUploadReport.make(state: clean, queue: ["queue": []], dirty: 0,
            lastError: "failed to delete existing object: historical error")
        XCTAssertEqual(recovered.phase, .uploaded)
        XCTAssertFalse(recovered.warning)
        XCTAssertFalse(recovered.replacementCleanupFailed)
    }
    func testUploadReportDistinguishesWritebackDelayOpenWritesAndUnknownQueue() throws {
        let queued = VaultUploadState(references: 1, queued: 1, uploading: 0, errors: 0, outOfSpace: false)
        var item: [String: Any] = ["name": "Report.docx", "tries": 0, "uploading": false, "expiry": 4.0]
        XCTAssertEqual(try VaultUploadReport.make(state: queued, queue: ["queue": [item]], dirty: 1, lastError: nil).phase, .waiting)
        item["uploading"] = true
        XCTAssertEqual(try VaultUploadReport.make(state: queued, queue: ["queue": [item]], dirty: 1, lastError: nil).phase, .uploading)
        let clean = VaultUploadState(references: 1, queued: 0, uploading: 0, errors: 0, outOfSpace: false)
        XCTAssertEqual(try VaultUploadReport.make(state: clean, queue: ["queue": []], dirty: 1, lastError: nil).phase, .openChanges)
        XCTAssertThrowsError(try VaultUploadReport.make(state: clean, queue: [:], dirty: 0, lastError: nil))
        item["expiry"] = Double.infinity
        XCTAssertThrowsError(try VaultUploadReport.make(state: queued, queue: ["queue": [item]], dirty: 1, lastError: nil))
        let full = VaultUploadState(references: 1, queued: 1, uploading: 1, errors: 1, outOfSpace: true)
        XCTAssertEqual(try VaultUploadReport.make(state: full, queue: ["queue": []], dirty: 1, lastError: nil).phase, .storageFull)
    }
    func testPrivateExportDoesNotChangeParentPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cm-permissions-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int
        try VaultDisk.write(["public": "test"], to: root.appendingPathComponent("export"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int, before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("export").path)[.posixPermissions] as? Int, 0o600)
    }
    func testSecretPipeHandlesLargeInputAndClosedChild() {
        let data = Data(repeating: 65, count: 200_000)
        let read = CommandRunner.run("/usr/bin/wc", arguments: ["-c"], timeout: 3, input: data)
        XCTAssertTrue(read.succeeded)
        XCTAssertEqual(Int(read.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), data.count)
        let result = CommandRunner.run("/usr/bin/true", arguments: [], timeout: 3, input: data)
        XCTAssertTrue(result.succeeded)
    }
    func testRealKeychainCanRememberWithoutInteraction() throws {
        guard ProcessInfo.processInfo.environment["CLOUDMOUNT_RUN_KEYCHAIN_TESTS"] == "1" else { throw XCTSkip("Opt in to an isolated temporary Keychain item") }
        let store = VaultKeychain(service: "com.codex.cloudmount.tests." + UUID().uuidString)
        let keys = VaultSecrets(id: UUID(), password: "test-only", salt: "test-only", recoveryCode: "test-only")
        defer { try? store.remove(keys.id) }
        try store.save(keys)
        XCTAssertEqual(try store.read(keys.id), keys)
        try store.remove(keys.id)
        XCTAssertNil(try store.read(keys.id))
    }
    func testOldSessionJournalDefaultsToActiveRecovery() throws {
        let location = VaultLocation(id: UUID(), name: "Test", remote: "fixture", folder: "vault")
        let value = VaultJournal(location: location, socket: "/private/tmp/cmv-test/rpc.sock", destination: "/private/tmp/test", writer: nil, readOnly: false)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        object["cleanupOnly"] = nil
        object["method"] = nil
        let decoded = try JSONDecoder().decode(VaultJournal.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(decoded.cleanupOnly)
        XCTAssertEqual(decoded.method, .nfs)
        XCTAssertEqual(decoded.location.id, location.id)
    }
}

final class VaultIntegrationTests: XCTestCase {
    private final class MemoryKeys: VaultSecretStore {
        var values: [UUID: VaultSecrets] = [:]
        func read(_ id: UUID) throws -> VaultSecrets? { values[id] }
        func save(_ keys: VaultSecrets) throws { values[keys.id] = keys }
        func remove(_ id: UUID) throws { values[id] = nil }
    }
    private var helper: String {
        var folder = Bundle(for: VaultIntegrationTests.self).bundleURL.deletingLastPathComponent()
        for _ in 0..<6 {
            let path = folder.appendingPathComponent("CloudMountHelper").path
            if FileManager.default.isExecutableFile(atPath: path) { return path }
            folder.deleteLastPathComponent()
        }
        return "missing-helper"
    }
    private func binary() throws -> String {
        guard let value = ProcessInfo.processInfo.environment["CLOUDMOUNT_RCLONE_TEST_BINARY"] else { throw XCTSkip("Set CLOUDMOUNT_RCLONE_TEST_BINARY") }
        return value
    }
    @MainActor func testAuthorizedDrimeVaultCanOverwriteAtomicReplaceDeleteAndLock() async throws {
        guard let remote = ProcessInfo.processInfo.environment["CLOUDMOUNT_DRIME_TEST_REMOTE"] else { throw XCTSkip("Requires explicit authorization for an isolated real-cloud fixture") }
        let binary = try binary()
        let local = try VaultDisk.privateDirectory(URL(fileURLWithPath: "/private/tmp/cmv-drime-test-" + UUID().uuidString.prefix(8)))
        let folder = ".cloudmount-diagnostics-" + UUID().uuidString
        print("AUTHORIZED_DRIME_FIXTURE " + remote + ":" + folder)
        let suite = "CloudMountTests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(startup: false, defaults: preferences, helperPath: helper)
        model.method = .nfs
        model.rclonePath = binary; model.version = "v1.75.2-cloudmount.1"; model.remotes = [remote]
        let manager = VaultManager(model: model, root: local.appendingPathComponent("Vaults"), store: MemoryKeys(), openFinderAutomatically: false)
        await manager.prepareRemotes()
        let diagnostic = manager.$progress.sink { print("DRIME_STAGE " + $0) }
        defer { diagnostic.cancel() }
        let started = ProcessInfo.processInfo.systemUptime
        guard let id = await manager.create(remote: remote, parent: folder, name: "覆寫驗證・測試", password: "isolated-test-" + UUID().uuidString, remember: true) else {
            _ = await manager.lockAllForQuit()
            throw VaultFailure.message("Drime fixture create failed: " + (manager.error ?? "unknown") + " DIAGNOSTIC " + manager.lastDiagnostic)
        }
        print("DRIME_CREATE_SECONDS \(ProcessInfo.processInfo.systemUptime - started)")
        let mount = URL(fileURLWithPath: manager.destination(id))
        @MainActor func waitClean() async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 90
            while ProcessInfo.processInfo.systemUptime < deadline {
                let worker = try XCTUnwrap(manager.runtimes[id]?.worker)
                let state = try VaultUploadState.parse(await worker.call("vfs/stats", ["fs": "cloudmount_vault:"], timeout: 3))
                let cache = local.appendingPathComponent("Vaults/cache/" + id.uuidString)
                let dirty = await CommandRunner.execute(helper, arguments: ["vault-cache", cache.appendingPathComponent("vfsMeta").path, cache.path], timeout: 5)
                if state.clean && Int(dirty.stdout) == 0 { return }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            throw VaultFailure.message("Drime upload did not become clean; fixture and cache retained")
        }
        @MainActor func write(_ name: String, _ data: Data) async throws {
            let source = local.appendingPathComponent("input")
            try data.write(to: source)
            let result = await CommandRunner.execute("/bin/cp", arguments: [source.path, mount.appendingPathComponent(name).path], timeout: 8)
            guard result.succeeded else { throw VaultFailure.message("NFS fixture write failed") }
            try await waitClean()
            let output = UUID().uuidString
            _ = try await manager.runtimes[id]!.worker.call("operations/copyfile", ["srcFs": "cloudmount_vault:", "srcRemote": name, "dstFs": local.path, "dstRemote": output], timeout: 60)
            XCTAssertEqual(try Data(contentsOf: local.appendingPathComponent(output)), data)
            print("DRIME_WRITE_READBACK_OK \(name) \(data.count)")
        }
        do {
            try await write("中文測試.txt", Data("version one".utf8))
            try await write("中文測試.txt", Data("modified version two, different length".utf8))
            try await write("中文測試.txt", Data("third replacement".utf8))
            try await write(".DS_Store", Data(repeating: 65, count: 6148))
            try await write(".DS_Store", Data(repeating: 66, count: 6148))
            try await write("large.bin", Data(repeating: 77, count: 6 * 1_048_576))
            try await write("large.bin", Data(repeating: 88, count: 6 * 1_048_576 + 8192))
            let atomic = Data("atomic replacement through rename".utf8)
            try await write("temporary.txt", atomic)
            let rename = await CommandRunner.execute("/bin/mv", arguments: ["-f", mount.appendingPathComponent("temporary.txt").path, mount.appendingPathComponent("中文測試.txt").path], timeout: 15)
            XCTAssertTrue(rename.succeeded, rename.output)
            try await waitClean()
            _ = try await manager.runtimes[id]!.worker.call("operations/copyfile", ["srcFs": "cloudmount_vault:", "srcRemote": "中文測試.txt", "dstFs": local.path, "dstRemote": "atomic-readback"], timeout: 30)
            XCTAssertEqual(try Data(contentsOf: local.appendingPathComponent("atomic-readback")), atomic)
            let removed = await CommandRunner.execute("/bin/rm", arguments: [mount.appendingPathComponent("中文測試.txt").path, mount.appendingPathComponent("large.bin").path, mount.appendingPathComponent(".DS_Store").path], timeout: 20)
            XCTAssertTrue(removed.succeeded, removed.output)
            let listing = try await manager.runtimes[id]!.worker.call("operations/list", ["fs": "cloudmount_vault:", "remote": ""], timeout: 15)
            XCTAssertEqual((listing["list"] as? [[String: Any]])?.count, 0)
            let locked = await manager.lock(id)
            XCTAssertTrue(locked, manager.error ?? "")
            guard locked else { throw VaultFailure.invalid }
            print("DRIME_ATOMIC_DELETE_AND_LOCK_OK")
            let cleaned = await CommandRunner.execute(binary, arguments: ["purge", remote + ":" + folder, "--ask-password=false", "--retries", "1", "--timeout", "15s"], timeout: 60)
            XCTAssertTrue(cleaned.succeeded, "Fixture cleanup failed: " + remote + ":" + folder)
            if cleaned.succeeded { try FileManager.default.removeItem(at: local) }
        } catch {
            _ = await manager.lockAllForQuit()
            print("DRIME_FIXTURE_RETAINED " + remote + ":" + folder + " LOCAL " + local.path)
            throw error
        }
    }
    @MainActor func testRemoteFolderBrowsingKeepsUnicodeFiltersFilesAndRejectsTraversal() async throws {
        let root = try VaultDisk.privateDirectory(URL(fileURLWithPath: "/private/tmp/cmv-browse-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = try VaultDisk.privateDirectory(root.appendingPathComponent("cloud"))
        _ = try VaultDisk.privateDirectory(cloud.appendingPathComponent("中文資料夾"))
        _ = try VaultDisk.privateDirectory(cloud.appendingPathComponent("home"))
        try Data("keep".utf8).write(to: cloud.appendingPathComponent("not-a-folder.txt"))
        let config = root.appendingPathComponent("rclone.conf")
        try Data("[fixture]\ntype = local\n".utf8).write(to: config)
        let suite = "CloudMountTests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(startup: false, defaults: preferences, helperPath: helper)
        model.method = .nfs
        model.rclonePath = try binary()
        let manager = VaultManager(model: model, root: root.appendingPathComponent("Vaults"), store: MemoryKeys(), configurationPath: config.path)
        await manager.prepareRemotes()
        let folders = try await manager.folders(remote: "fixture", path: cloud.path)
        XCTAssertEqual(Set(folders), ["中文資料夾", "home"])
        let empty = try await manager.folders(remote: "fixture", path: cloud.path + "/中文資料夾")
        XCTAssertTrue(empty.isEmpty)
        for invalid in ["../private", "a:b", "a\nb"] {
            do { _ = try await manager.folders(remote: "fixture", path: invalid); XCTFail("unsafe path accepted") }
            catch { }
        }
        XCTAssertEqual(try String(contentsOf: cloud.appendingPathComponent("not-a-folder.txt")), "keep")
    }
    @MainActor func testAuthorizedNasHomeCanCreateReadOverwriteDeleteAndLockVault() async throws {
        guard ProcessInfo.processInfo.environment["CLOUDMOUNT_NAS_TEST_REMOTE"] == "NAS" else { throw XCTSkip("Requires authorization for an isolated NAS home fixture") }
        let binary = try binary()
        let local = try VaultDisk.privateDirectory(URL(fileURLWithPath: "/private/tmp/cmv-nas-" + UUID().uuidString.prefix(8)))
        let folder = "home/.cloudmount-diagnostics-" + UUID().uuidString
        let suite = "CloudMountTests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(startup: false, defaults: preferences, helperPath: helper)
        model.method = .nfs
        model.rclonePath = binary; model.version = "test"; model.remotes = ["NAS"]
        let manager = VaultManager(model: model, root: local.appendingPathComponent("Vaults"), store: MemoryKeys(), openFinderAutomatically: false)
        await manager.prepareRemotes()
        XCTAssertEqual(manager.remoteTypes["NAS"], "webdav")
        let folders = try await manager.folders(remote: "NAS", path: "")
        XCTAssertTrue(folders.contains("home"))
        let id = await manager.create(remote: "NAS", parent: folder, name: "NAS 加密驗證", password: "isolated-test-" + UUID().uuidString, remember: true)
        guard let id else {
            _ = await manager.lockAllForQuit()
            throw VaultFailure.message("NAS fixture create failed: " + (manager.error ?? "unknown"))
        }
        print("AUTHORIZED_NAS_FIXTURE NAS:" + folder)
        do {
            let worker = try XCTUnwrap(manager.runtimes[id]?.worker)
            let mount = manager.destination(id) + "/中文測試.txt"
            let cache = local.appendingPathComponent("Vaults/cache/" + id.uuidString)
            func waitClean() async throws {
                let deadline = ProcessInfo.processInfo.systemUptime + 45
                while ProcessInfo.processInfo.systemUptime < deadline {
                    let state = try VaultUploadState.parse(await worker.call("vfs/stats"))
                    let dirty = await CommandRunner.execute(helper, arguments: ["vault-cache", cache.appendingPathComponent("vfsMeta").path, cache.path], timeout: 3)
                    if state.clean && dirty.succeeded && Int(dirty.stdout) == 0 { return }
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
                throw VaultFailure.message("NAS fixture upload did not become clean")
            }
            for data in [Data("original encrypted data".utf8), Data("overwritten encrypted data".utf8)] {
                let write = await CommandRunner.execute("/usr/bin/tee", arguments: [mount], timeout: 10, input: data, discardOutput: true)
                XCTAssertTrue(write.succeeded)
                try await waitClean()
                _ = try await worker.call("operations/copyfile", ["srcFs": "cloudmount_vault:", "srcRemote": "中文測試.txt", "dstFs": local.path, "dstRemote": "readback"])
                XCTAssertEqual(try Data(contentsOf: local.appendingPathComponent("readback")), data)
            }
            let removed = await CommandRunner.execute("/bin/rm", arguments: [mount], timeout: 10)
            XCTAssertTrue(removed.succeeded)
            let listing = try await worker.call("operations/list", ["fs": "cloudmount_vault:", "remote": ""])
            XCTAssertEqual((listing["list"] as? [[String: Any]])?.count, 0)
            let locked = await manager.lock(id)
            XCTAssertTrue(locked, manager.error ?? "")
            guard locked else { throw VaultFailure.invalid }
            await manager.discover(remote: "NAS", parent: folder)
            XCTAssertEqual(manager.discoveries.first?.envelope.name, "NAS 加密驗證")
            let purged = await CommandRunner.execute(binary, arguments: ["purge", "NAS:" + folder, "--contimeout", "5s", "--timeout", "10s", "--retries", "1"], timeout: 20)
            XCTAssertTrue(purged.succeeded)
            if purged.succeeded { try? FileManager.default.removeItem(at: local) }
        } catch { _ = await manager.lockAllForQuit(); throw error }
    }
    @MainActor func testRealRcloneUsesPrivateSocketMemoryOnlyAndPortableCiphertext() async throws {
        let binary = try binary()
        let root = try VaultDisk.privateDirectory(URL(fileURLWithPath: "/private/tmp/cmv-test-" + UUID().uuidString.prefix(10)))
        defer { try? FileManager.default.removeItem(at: root) }
        let (envelope, keys) = try VaultEnvelope.createLegacyFixture(name: "Private", password: "a-long-test-password")
        let location = VaultLocation(id: keys.id, name: "Private", remote: "local", folder: root.appendingPathComponent("cloud").path)
        let worker = VaultWorker(executable: binary, socket: root.appendingPathComponent("rpc.sock").path)
        try await worker.start(cache: root.appendingPathComponent("cache").path, sizeGB: 1, ageHours: 1)
        do {
            try await worker.configure(remote: "local", config: ["type": "local"], location: location, keys: keys)
            try await worker.verifyRoundTrip()
            let input = root.appendingPathComponent("source.txt"), data = Data("private file content 測試".utf8)
            try data.write(to: input)
            _ = try await worker.call("operations/copyfile", ["srcFs": root.path, "srcRemote": "source.txt", "dstFs": "cloudmount_vault:", "dstRemote": "中文/秘密.txt"])
            let dataRoot = root.appendingPathComponent("cloud/data")
            let encryptedFiles = try XCTUnwrap(FileManager.default.enumerator(at: dataRoot, includingPropertiesForKeys: nil)).allObjects.compactMap { $0 as? URL }
            XCTAssertFalse(encryptedFiles.contains { $0.lastPathComponent == "秘密.txt" || $0.lastPathComponent == "中文" })
            let ciphertext = try XCTUnwrap(try encryptedFiles.first { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true })
            let stored = try Data(contentsOf: ciphertext)
            XCTAssertTrue(stored.starts(with: Data([82,67,76,79,78,69,0,0])))
            XCTAssertFalse(stored.range(of: data) != nil)
            // A second independent worker simulates a different computer: it
            // gets only the downloaded envelope, original password and backend.
            let otherKeys = try VaultEnvelope.decode(JSONEncoder().encode(envelope)).unlock(password: "a-long-test-password")
            let other = VaultWorker(executable: binary, socket: root.appendingPathComponent("second.sock").path)
            try await other.start(cache: root.appendingPathComponent("second-cache").path, sizeGB: 1, ageHours: 1)
            do {
                try await other.configure(remote: "different-local-name", config: ["type": "local"], location: location, keys: otherKeys)
                _ = try await other.call("operations/copyfile", ["srcFs": "cloudmount_vault:", "srcRemote": "中文/秘密.txt", "dstFs": root.path, "dstRemote": "decoded.txt"])
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("decoded.txt")), data)
            } catch { _ = await other.shutdownAfterUnmount(); throw error }
            let otherStopped = await other.shutdownAfterUnmount()
            XCTAssertTrue(otherStopped)
            let config = try await worker.call("config/dump")
            XCTAssertNotNil(config["cloudmount_vault"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("rclone.conf").path))
            let stopped = await worker.shutdownAfterUnmount()
            XCTAssertTrue(stopped)
        } catch { _ = await worker.shutdownAfterUnmount(); throw error }
    }
    func testCacheHelperDetectsUnqueuedDirtyWritesAndRejectsSymlinks() throws {
        let root = try VaultDisk.privateDirectory(URL(fileURLWithPath: "/private/tmp/cmv-cache-test-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = try VaultDisk.privateDirectory(root.appendingPathComponent("vfsMeta"))
        try Data("{\"Dirty\":true}".utf8).write(to: metadata.appendingPathComponent("file"))
        let dirty = CommandRunner.run(helper, arguments: ["vault-cache", metadata.path, root.path])
        XCTAssertTrue(dirty.succeeded, dirty.output)
        XCTAssertEqual(Int(dirty.stdout), 1)
        try Data("{\"Dirty\":false}".utf8).write(to: metadata.appendingPathComponent("file"))
        XCTAssertEqual(Int(CommandRunner.run(helper, arguments: ["vault-cache", metadata.path, root.path]).stdout), 0)
        try FileManager.default.createSymbolicLink(at: metadata.appendingPathComponent("alias"), withDestinationURL: metadata.appendingPathComponent("file"))
        XCTAssertFalse(CommandRunner.run(helper, arguments: ["vault-cache", metadata.path, root.path]).succeeded)
        XCTAssertFalse(CommandRunner.run(helper, arguments: ["vault-cache", metadata.path, root.appendingPathComponent("other").path]).succeeded)
    }
    @MainActor func testManagerCreatesLocksAndReopensRealLocalVaultWithoutRepeatedPassword() async throws {
        let fuseRun = ProcessInfo.processInfo.environment["CLOUDMOUNT_RUN_MACFUSE_TESTS"] == "1"
        guard fuseRun || ProcessInfo.processInfo.environment["CLOUDMOUNT_RUN_MOUNT_TESTS"] == "1" else { throw XCTSkip("Opt in to one isolated local mount lifecycle") }
        if fuseRun {
            let support = MacFuseSupport(); await support.refresh(helperPath: helper)
            if ProcessInfo.processInfo.environment["CLOUDMOUNT_REQUIRE_FSKIT"] == "1", support.resolved(.automatic) != .fskit {
                throw VaultFailure.message("FSKit is required for this run but is not ready; no vault was created")
            }
            guard let actual = support.resolved(.automatic), actual == .fuse || actual == .fskit else { throw XCTSkip("Enable macFUSE in System Settings before this isolated test") }
        }
        let binary = try binary()
        let root = try VaultDisk.privateDirectory(URL(fileURLWithPath: "/private/tmp/cmv-nfs-test-" + UUID().uuidString.prefix(8)))
        let preferencesName = "CloudMountTests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: preferencesName))
        defer { preferences.removePersistentDomain(forName: preferencesName) }
        let model = AppModel(startup: false, defaults: preferences, helperPath: helper)
        model.method = fuseRun ? .automatic : .nfs
        model.rclonePath = binary; model.version = "test"; model.remotes = ["fixture"]
        let config = root.appendingPathComponent("rclone.conf")
        try Data("[fixture]\ntype = local\n".utf8).write(to: config)
        let savedKeys = MemoryKeys()
        var manager = VaultManager(model: model, root: root.appendingPathComponent("Vaults"), store: savedKeys, configurationPath: config.path, openFinderAutomatically: false)
        await manager.prepareRemotes()
        let id = await manager.create(remote: "fixture", parent: root.appendingPathComponent("cloud").path, name: "Test Vault", password: "a-long-test-password", remember: true)
        guard let id else {
            let cleanup = await manager.lockAllForQuit()
            throw VaultFailure.message("Local NFS create failed: " + (manager.error ?? "unknown") + "; cleanup=\(cleanup)")
        }
        do {
            XCTAssertTrue(manager.isOpen(id))
            let otherPreferencesName = "CloudMountTests." + UUID().uuidString
            let otherPreferences = try XCTUnwrap(UserDefaults(suiteName: otherPreferencesName))
            defer { otherPreferences.removePersistentDomain(forName: otherPreferencesName) }
            let otherModel = AppModel(startup: false, defaults: otherPreferences, helperPath: helper)
            otherModel.method = model.method
            otherModel.rclonePath = binary; otherModel.version = "test"; otherModel.remotes = ["fixture"]
            let second = VaultManager(model: otherModel, root: root.appendingPathComponent("OtherVaults"), store: MemoryKeys(), configurationPath: config.path, openFinderAutomatically: false)
            await second.prepareRemotes()
            await second.discover(remote: "fixture", parent: root.appendingPathComponent("cloud").path)
            let found = try XCTUnwrap(second.discoveries.first)
            XCTAssertEqual(found.id, id)
            let blocked = await second.unlock(found.location, password: "a-long-test-password", remember: false)
            XCTAssertFalse(blocked)
            XCTAssertFalse(second.shouldAskPassword(id))
            XCTAssertFalse(second.isRunning(id))
            let source = root.appendingPathComponent("source.txt")
            try Data("vault lifecycle test".utf8).write(to: source)
            let target = URL(fileURLWithPath: manager.destination(id)).appendingPathComponent("Test.txt")
            let copied = await CommandRunner.execute("/bin/cp", arguments: [source.path, target.path], timeout: 5)
            XCTAssertTrue(copied.succeeded)
            let lockProbe = await CommandRunner.execute("/usr/bin/python3", arguments: ["-c",
                "import fcntl,sys; f=open(sys.argv[1], 'r+b'); fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB); print('local-lock-ok'); fcntl.flock(f, fcntl.LOCK_UN)", target.path], timeout: 5)
            XCTAssertTrue(lockProbe.succeeded, "Local NFS locks must work without a remote NLM server")
            if fuseRun {
                XCTAssertTrue([MountMethod.fskit, .fuse].contains(manager.runtimes[id]?.journal.method ?? .automatic))
                if ProcessInfo.processInfo.environment["CLOUDMOUNT_REQUIRE_FSKIT"] == "1" {
                    XCTAssertEqual(manager.runtimes[id]?.journal.method, .fskit)
                }
                let snapshot = await model.scanMountedVolumes()
                XCTAssertTrue(snapshot?.contains { $0.destination == manager.destination(id) && $0.fileSystem.contains("macfuse") } == true)
            } else {
                let parameters = await CommandRunner.execute("/usr/bin/nfsstat", arguments: ["-m"], timeout: 5)
                let block = parameters.stdout.components(separatedBy: "\n\n").first { $0.contains(manager.destination(id)) } ?? ""
                XCTAssertTrue(block.contains("locallocks") && block.contains("noquota"), "NFS options were not applied")
            }
            let previousPID = manager.runtimes[id]?.worker.pid
            let repaired = await manager.repairUploads(id)
            XCTAssertTrue(repaired, manager.error ?? "")
            XCTAssertNotEqual(previousPID, manager.runtimes[id]?.worker.pid)
            try await Task.sleep(nanoseconds: 7_000_000_000)
            let worker = try XCTUnwrap(manager.runtimes[id]?.worker)
            let actualState = try VaultUploadState.parse(await worker.call("vfs/stats", ["fs": "cloudmount_vault:"]))
            let actualQueue = try await worker.call("vfs/queue", ["fs": "cloudmount_vault:"])
            let actualReport = try VaultUploadReport.make(state: actualState, queue: actualQueue, dirty: 0, lastError: nil)
            XCTAssertEqual(actualReport.phase, .uploaded)
            // Simulate a relaunched controller adopting an already unlocked
            // worker. The old controller performs no more work, like a crashed app.
            let oldController = manager
            oldController.runtimes[id]?.poll?.cancel()
            let recovered = VaultManager(model: model, root: root.appendingPathComponent("Vaults"), store: savedKeys, configurationPath: config.path, openFinderAutomatically: false)
            await recovered.reconcileAndStart(allowAutomatic: false)
            XCTAssertTrue(recovered.isOpen(id), recovered.error ?? "")
            XCTAssertNil(recovered.recoveryWords(id))
            let recoveryPrepared = await recovered.prepareRecovery(id)
            XCTAssertTrue(recoveryPrepared, recovered.error ?? "")
            XCTAssertEqual(recovered.recoveryWords(id)?.split(separator: " ").count, 44)
            XCTAssertEqual(recovered.recoveryWords(id), oldController.recoveryWords(id))
            manager = recovered
            let writers = URL(fileURLWithPath: found.location.folder).appendingPathComponent("writers")
            let delayedWriters = writers.deletingLastPathComponent().appendingPathComponent("writers-delayed")
            try FileManager.default.moveItem(at: writers, to: delayedWriters)
            let locked = await manager.lock(id)
            XCTAssertTrue(locked, manager.error ?? "")
            XCTAssertFalse(manager.isOpen(id))
            guard locked else { throw VaultFailure.invalid }
            XCTAssertTrue(manager.pendingCleanup.contains(id))
            try FileManager.default.moveItem(at: delayedWriters, to: writers)
            await manager.clearPendingMarker(id)
            XCTAssertFalse(manager.pendingCleanup.contains(id), manager.error ?? "")
            let otherOpened = await second.unlock(found.location, password: "a-long-test-password", remember: true)
            XCTAssertTrue(otherOpened, second.error ?? "")
            let otherTarget = URL(fileURLWithPath: second.destination(id)).appendingPathComponent("Test.txt")
            let otherRead = await CommandRunner.execute("/bin/cat", arguments: [otherTarget.path], timeout: 5)
            XCTAssertEqual(otherRead.stdout, "vault lifecycle test")
            let otherLocked = await second.lock(id)
            XCTAssertTrue(otherLocked, second.error ?? "")
            let location = try XCTUnwrap(manager.locations.first)
            let opened = await manager.unlock(location, password: "", remember: true, readOnly: true)
            XCTAssertTrue(opened, manager.error ?? "")
            let read = await CommandRunner.execute("/bin/cat", arguments: [target.path], timeout: 5)
            XCTAssertEqual(read.stdout, "vault lifecycle test")
            let write = await CommandRunner.execute("/usr/bin/touch", arguments: [target.deletingLastPathComponent().appendingPathComponent("must-fail").path], timeout: 5)
            XCTAssertFalse(write.succeeded)
            let secondLock = await manager.lock(id)
            XCTAssertTrue(secondLock, manager.error ?? "")
            if secondLock { try FileManager.default.removeItem(at: root) }
        } catch { _ = await manager.lockAllForQuit(); throw error }
    }
    @MainActor func testStandardVaultWithoutCloudMountMetadataCanImportAndMount() async throws {
        guard ProcessInfo.processInfo.environment["CLOUDMOUNT_RUN_MOUNT_TESTS"] == "1" else { throw XCTSkip("Isolated standard-vault NFS import") }
        let binary = try binary()
        let root = try VaultDisk.privateDirectory(URL(fileURLWithPath: "/private/tmp/cmv-standard-import-" + UUID().uuidString.prefix(8), isDirectory: true))
        let vault = try VaultDisk.privateDirectory(root.appendingPathComponent("Official vault", isDirectory: true))
        let scratch = try VaultDisk.privateDirectory(root.appendingPathComponent("scratch", isDirectory: true))
        let (descriptor, key) = try VaultDescriptor.create(password: "standard-vault-password")
        try descriptor.masterkeyFile.write(to: vault.appendingPathComponent(VaultDescriptor.keyName, isDirectory: false))
        try descriptor.vaultConfig.write(to: vault.appendingPathComponent(VaultDescriptor.configName, isDirectory: false))
        let fs = try VaultFileSystem(store: LocalCiphertextStore(root: vault), descriptor: descriptor, rawKey: key, scratch: scratch)
        try await fs.initialize()
        let source = scratch.appendingPathComponent("input", isDirectory: false); try Data("standard import".utf8).write(to: source)
        try await fs.upload(source, to: "中文.txt")
        let suite = "CloudMountTests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(startup: false, defaults: preferences, helperPath: helper)
        model.method = .nfs
        model.rclonePath = binary; model.version = "test"; model.remotes = ["fixture"]
        let config = root.appendingPathComponent("rclone.conf", isDirectory: false); try Data("[fixture]\ntype = local\n".utf8).write(to: config)
        let manager = VaultManager(model: model, root: root.appendingPathComponent("Vaults", isDirectory: true), store: MemoryKeys(), configurationPath: config.path, openFinderAutomatically: false)
        await manager.prepareRemotes(); await manager.discoverExact(remote: "fixture", path: vault.path)
        let found = try XCTUnwrap(manager.discoveries.first, manager.error ?? "")
        XCTAssertEqual(found.id, descriptor.id)
        let opened = await manager.unlock(found.location, password: "standard-vault-password", remember: true)
        XCTAssertTrue(opened, manager.error ?? "")
        guard opened else { throw VaultFailure.invalid }
        do {
            let read = await CommandRunner.execute("/bin/cat", arguments: [manager.destination(found.id) + "/中文.txt"], timeout: 10)
            XCTAssertEqual(read.stdout, "standard import")
            let locked = await manager.lock(found.id); XCTAssertTrue(locked, manager.error ?? "")
            guard locked else { throw VaultFailure.invalid }
            XCTAssertFalse(FileManager.default.fileExists(atPath: vault.appendingPathComponent(VaultEnvelope.filename).path))
            try FileManager.default.removeItem(at: root)
        } catch { _ = await manager.lockAllForQuit(); throw error }
    }
    @MainActor func testDisabledAutomaticMountDoesNotUnlockRememberedVaults() async throws {
        let root = try VaultDisk.privateDirectory(URL(fileURLWithPath: "/private/tmp/cmv-auto-test-" + UUID().uuidString.prefix(8)))
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "CloudMountTests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(startup: false, defaults: preferences, helperPath: helper)
        model.method = .nfs
        model.rclonePath = "/usr/bin/false"; model.version = "test"; model.autoMountEnabled = false
        var location = VaultLocation(id: UUID(), name: "Test", remote: "fixture", folder: "test/.cloudmount-vaults/id")
        location.automaticUnlock = true
        try VaultDisk.write([location], to: root.appendingPathComponent("locations.json"))
        let keys = MemoryKeys(); try keys.save(VaultSecrets(id: location.id, password: "test", salt: "test", recoveryCode: "test"))
        let manager = VaultManager(model: model, root: root, store: keys, openFinderAutomatically: false)
        await manager.reconcileAndStart(allowAutomatic: true)
        XCTAssertTrue(manager.isRemembered(location.id))
        XCTAssertFalse(manager.isRunning(location.id))
        XCTAssertNil(manager.error)
    }
    @MainActor func testPendingCacheCannotBeForgottenOrDeleted() async throws {
        let root = try VaultDisk.privateDirectory(URL(fileURLWithPath: "/private/tmp/cmv-pending-test-" + UUID().uuidString.prefix(8)))
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "CloudMountTests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(startup: false, defaults: preferences, helperPath: helper)
        model.method = .nfs
        let location = VaultLocation(id: UUID(), name: "Test", remote: "fixture", folder: "test/.cloudmount-vaults/id")
        try VaultDisk.write([location], to: root.appendingPathComponent("locations.json"))
        let metadata = try VaultDisk.privateDirectory(root.appendingPathComponent("cache/" + location.id.uuidString + "/vfsMeta"))
        let pending = metadata.appendingPathComponent("pending")
        try Data("{\"Dirty\":true}".utf8).write(to: pending)
        let keys = MemoryKeys(); try keys.save(VaultSecrets(id: location.id, password: "test", salt: "test", recoveryCode: "test"))
        let manager = VaultManager(model: model, root: root, store: keys, openFinderAutomatically: false)
        await manager.removeLocal(location.id)
        XCTAssertEqual(manager.locations.count, 1)
        XCTAssertTrue(manager.isRemembered(location.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertNotNil(manager.error)
    }
    @MainActor func testCloudDeletionRequiresConfirmationCleanCacheAndNoWritersAndKeepsOtherVaults() async throws {
        let binary = try binary()
        let root = try VaultDisk.privateDirectory(URL(fileURLWithPath: "/private/tmp/cmv-delete-test-" + UUID().uuidString.prefix(8)))
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "CloudMountTests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(startup: false, defaults: preferences, helperPath: helper)
        model.method = .nfs
        model.rclonePath = binary; model.version = "test"; model.remotes = ["fixture"]
        let config = root.appendingPathComponent("rclone.conf")
        try Data("[fixture]\ntype = local\n".utf8).write(to: config)
        let (envelope, keys) = try VaultEnvelope.createLegacyFixture(name: "保密・工作資料 🔒", password: "a-long-test-password")
        let folder = root.appendingPathComponent("cloud/.cloudmount-vaults/" + envelope.id.uuidString)
        let writers = try VaultDisk.privateDirectory(folder.appendingPathComponent("writers"))
        try VaultDisk.write(envelope, to: folder.appendingPathComponent(VaultEnvelope.filename))
        try Data("test ciphertext".utf8).write(to: folder.appendingPathComponent("encrypted-file"))
        let (siblingEnvelope, _) = try VaultEnvelope.createLegacyFixture(name: "Other", password: "a-long-test-password")
        let sibling = try VaultDisk.privateDirectory(folder.deletingLastPathComponent().appendingPathComponent(siblingEnvelope.id.uuidString))
        try VaultDisk.write(siblingEnvelope, to: sibling.appendingPathComponent(VaultEnvelope.filename))
        try Data("keep".utf8).write(to: sibling.appendingPathComponent("keep"))
        let location = VaultLocation(id: envelope.id, name: envelope.name, remote: "fixture", folder: folder.path)
        let local = try VaultDisk.privateDirectory(root.appendingPathComponent("Vaults"))
        try VaultDisk.write([location], to: local.appendingPathComponent("locations.json"))
        let store = MemoryKeys(); try store.save(keys)
        let manager = VaultManager(model: model, root: local, store: store, configurationPath: config.path, openFinderAutomatically: false)
        await manager.prepareRemotes()
        await manager.discover(remote: "fixture", parent: root.appendingPathComponent("cloud").path)
        XCTAssertEqual(manager.discoveries.first(where: { $0.id == envelope.id })?.envelope.name, envelope.name)
        let wrong = await manager.deleteCloud(location.id, confirmation: "wrong")
        XCTAssertFalse(wrong)
        let dirtyRoot = try VaultDisk.privateDirectory(local.appendingPathComponent("cache/" + location.id.uuidString + "/vfsMeta"))
        let dirty = dirtyRoot.appendingPathComponent("pending")
        try Data("{\"Dirty\":true}".utf8).write(to: dirty)
        let blockedDirty = await manager.deleteCloud(location.id, confirmation: location.name)
        XCTAssertFalse(blockedDirty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirty.path))
        try FileManager.default.removeItem(at: dirty)
        let foreign = writers.appendingPathComponent(UUID().uuidString + ".json")
        try VaultDisk.write(VaultLease.make(keys, device: UUID()), to: foreign)
        let blockedWriter = await manager.deleteCloud(location.id, confirmation: location.name)
        XCTAssertFalse(blockedWriter)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertNotNil(try store.read(location.id))
        try FileManager.default.removeItem(at: foreign)
        let deleted = await manager.deleteCloud(location.id, confirmation: location.name)
        XCTAssertTrue(deleted, manager.error ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(try String(contentsOf: sibling.appendingPathComponent("keep")), "keep")
        XCTAssertTrue(manager.locations.isEmpty)
        XCTAssertNil(try store.read(location.id))
    }
}
