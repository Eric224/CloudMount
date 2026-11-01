import AppKit
import Combine
import Foundation
import CryptoKit
import Darwin
import CloudMountVaultCore

struct VaultDiscovery: Identifiable { let location: VaultLocation; let envelope: VaultEnvelope; var id: UUID { location.id } }
struct VaultJournal: Codable {
    let location: VaultLocation
    let socket: String
    let destination: String
    let writer: String?
    let readOnly: Bool
    var cleanupOnly: Bool = false
    var method: MountMethod = .nfs
    enum CodingKeys: String, CodingKey { case location, socket, destination, writer, readOnly, cleanupOnly, method }
}
extension VaultJournal {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        location = try c.decode(VaultLocation.self, forKey: .location)
        socket = try c.decode(String.self, forKey: .socket)
        destination = try c.decode(String.self, forKey: .destination)
        writer = try c.decodeIfPresent(String.self, forKey: .writer)
        readOnly = try c.decode(Bool.self, forKey: .readOnly)
        cleanupOnly = try c.decodeIfPresent(Bool.self, forKey: .cleanupOnly) ?? false
        method = try c.decodeIfPresent(MountMethod.self, forKey: .method) ?? .nfs
    }
}

struct VaultLease: Codable {
    let vault: UUID
    let device: UUID
    let signature: Data
    private var body: Data { Data("CMWriter-v1|\(vault.uuidString)|\(device.uuidString)".utf8) }
    private static func key(_ secrets: VaultSecrets) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(secrets.salt.utf8)),
            salt: Data(secrets.id.uuidString.utf8), info: Data("CMWriterLease-v1".utf8), outputByteCount: 32)
    }
    static func make(_ keys: VaultSecrets, device: UUID) -> Self {
        let value = Self(vault: keys.id, device: device, signature: Data())
        return Self(vault: keys.id, device: device, signature: Data(HMAC<SHA256>.authenticationCode(for: value.body, using: key(keys))))
    }
    func valid(_ keys: VaultSecrets) -> Bool {
        vault == keys.id && HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: body, using: Self.key(keys))
    }
}

@MainActor
final class VaultRuntime {
    let journal: VaultJournal
    let worker: VaultWorker
    var keys: VaultSecrets?
    var envelope: VaultEnvelope?
    var status = L10n.string("正在解鎖…")
    var ready = false
    var stopped = false
    var poll: Task<Void, Never>?
    init(journal: VaultJournal, worker: VaultWorker, keys: VaultSecrets?, envelope: VaultEnvelope?) {
        self.journal = journal; self.worker = worker; self.keys = keys; self.envelope = envelope
    }
}

@MainActor
final class VaultManager: ObservableObject {
    @Published private(set) var locations: [VaultLocation] = []
    @Published private(set) var discoveries: [VaultDiscovery] = []
    @Published private(set) var remoteTypes: [String: String] = [:]
    private var folderBrowseBusy = false
    private var folderBrowseBlocked = false
    @Published private(set) var statuses: [UUID: String] = [:]
    @Published private(set) var uploadReports: [UUID: VaultUploadReport] = [:]
    @Published private(set) var busy = false
    @Published private(set) var pendingCleanup: Set<UUID> = []
    @Published private(set) var recoverySaved: Set<UUID> = []
    @Published var progress = ""
    @Published var error: String?
    private(set) var runtimes: [UUID: VaultRuntime] = [:]
    private weak var model: AppModel?
    private let store: VaultSecretStore
    private let root: URL
    private let mountRoot: URL
    private let device: UUID
    private let configurationPath: String?
    private let openAutomatically: Bool
    private var reconciled = false
    private var control = CommandControl()
    private var rememberedIDs: Set<UUID> = []
    private var needsPassword: Set<UUID> = []
    private var storageReady = true
    private var repairingUploads = false
    private(set) var lastDiagnostic = ""

    init(model: AppModel, root: URL? = nil, store: VaultSecretStore = VaultKeychain(), configurationPath: String? = nil, openFinderAutomatically: Bool = true) {
        self.model = model; self.store = store
        self.configurationPath = configurationPath; openAutomatically = openFinderAutomatically
        let storageName = Bundle.main.bundleIdentifier == "com.codex.cloudmount.preview" ? "CloudMount Preview" : "CloudMount"
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/" + storageName + "/Vaults")
        mountRoot = root?.appendingPathComponent("mounts") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("CloudMountVaults")
        let deviceFile = self.root.appendingPathComponent("device.json")
        let diskID = (try? Data(contentsOf: deviceFile)).flatMap { try? JSONDecoder().decode(UUID.self, from: $0) }
        let saved = diskID ?? (root == nil ? UserDefaults.standard.string(forKey: "vaultDeviceID").flatMap(UUID.init(uuidString:)) : nil) ?? UUID()
        device = saved
        do { _ = try VaultDisk.privateDirectory(self.root); try VaultDisk.write(saved, to: deviceFile) }
        catch { storageReady = false; self.error = L10n.string("無法儲存本機保險箱設定，請檢查資料夾權限。") }
        if let bytes = try? Data(contentsOf: self.root.appendingPathComponent("locations.json")),
           let list = try? JSONDecoder().decode([VaultLocation].self, from: bytes), Set(list.map(\.id)).count == list.count { locations = list }
        rememberedIDs = Set(locations.compactMap { (try? store.read($0.id)) != nil ? $0.id : nil })
    }
    var available: Bool { storageReady && model?.canStartMount == true && model?.isTransferring != true && !busy }
    var canCancel: Bool { !repairingUploads && !runtimes.values.contains(where: { $0.worker.mountInFlight }) }
    var supportedRemotes: [String] { remoteTypes.filter { ["drime", "webdav", "s3", "local"].contains($0.value) }.keys.sorted() }
    func isOpen(_ id: UUID) -> Bool { runtimes[id]?.ready == true }
    func isRunning(_ id: UUID) -> Bool { runtimes[id] != nil }
    func canResume(_ id: UUID) -> Bool {
        guard let runtime = runtimes[id] else { return false }
        return !runtime.ready && !runtime.stopped && !runtime.worker.didExit && !runtime.worker.mountInFlight && available
    }
    func canRepairUploads(_ id: UUID) -> Bool {
        guard let runtime = runtimes[id] else { return false }
        return runtime.ready && !runtime.journal.readOnly && available
    }
    func canRepairWithoutPassword(_ id: UUID) -> Bool { !needsPassword.contains(id) && (runtimes[id]?.keys != nil || isRemembered(id)) }
    /// This operation is deliberately separate from Lock: it preserves dirty
    /// cache and the writer lease while replacing a stopped, normally unmounted
    /// worker. No force-unmount, queue removal or cache deletion is used.
    func repairUploads(_ id: UUID, password: String = "") async -> Bool {
        guard canRepairUploads(id), let runtime = runtimes[id], let model else { return false }
        needsPassword.remove(id)
        do { try begin("正在保留修改並修復上傳…") } catch { self.error = L10n.error(error); return false }
        repairingUploads = true
        defer { repairingUploads = false; end() }
        do {
            let location = runtime.journal.location
            let envelope = try await loadEnvelope(remote: location.remote, path: location.folder, fallbackName: location.name)
            guard envelope.id == id else { throw VaultFailure.invalid }
            let keys: VaultSecrets
            if !password.isEmpty {
                keys = try await Task.detached(priority: .userInitiated) { try envelope.unlock(password: password) }.value
            } else {
                guard let saved = runtime.keys ?? (try? store.read(id)) else { throw VaultFailure.password }
                keys = try envelope.recover(code: saved.recoveryCode)
                guard keys == saved else { throw VaultFailure.password }
            }
            let result = await UnmountOperation.run(path: runtime.journal.destination, timeout: 8,
                snapshot: { await model.scanMountedVolumes() })
            guard result == .unmounted else {
                if result == .unsafe { model.blockMountOperations() }
                throw VaultFailure.message("無法修復：請先儲存並關閉使用保險箱的檔案，再試一次。本機修改會保留。")
            }
            runtime.ready = false
            guard await runtime.worker.shutdownAfterUnmount() else {
                model.blockMountOperations()
                throw VaultFailure.message("上次保險箱程序未回應，請重新啟動 Mac 後再試。")
            }
            runtime.stopped = true; runtime.poll?.cancel()
            runtimes[id] = nil; uploadReports[id] = nil
            statuses[id] = L10n.string("已停止舊程序，待重新解鎖以繼續上傳")
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: runtime.worker.socket).deletingLastPathComponent())
            // Check the persisted cache before handing it to a new worker. An
            // unreadable cache is a hard stop, never a reason to clear it.
            _ = try await dirtyCount(id)
            if let bundled = AppModel.bundledRclone() { model.rclonePath = bundled }
            try await open(location, envelope: envelope, keys: keys, remember: isRemembered(id), readOnly: false, verify: false)
            return true
        } catch {
            if case VaultFailure.message(let key) = error, key == "密碼不正確，或保險箱描述檔已損壞。" { needsPassword.insert(id) }
            self.error = L10n.error(error)
            return false
        }
    }
    func status(_ id: UUID) -> String { statuses[id] ?? L10n.string("已鎖定") }
    func isRemembered(_ id: UUID) -> Bool { rememberedIDs.contains(id) }
    func shouldAskPassword(_ id: UUID) -> Bool { needsPassword.contains(id) }
    func references(_ remote: String) -> Bool {
        runtimes.values.contains { $0.journal.location.remote == remote } || locations.contains { $0.remote == remote && pendingCleanup.contains($0.id) }
    }
    func destination(_ id: UUID) -> String {
        mountRoot.appendingPathComponent(id.uuidString, isDirectory: true).path
    }
    private func begin(_ message: String) throws {
        guard available else { throw VaultFailure.message("請先等待目前掛載或保險箱工作完成。") }
        busy = true; model?.vaultOperationBusy = true; progress = L10n.string(message); error = nil; control = CommandControl()
    }
    private func end() { busy = false; model?.vaultOperationBusy = false; progress = ""; model?.vaultWorkersActive = !runtimes.isEmpty }
    private func persist() throws { try VaultDisk.write(locations, to: root.appendingPathComponent("locations.json")) }
    private func rememberLocation(_ location: VaultLocation) throws {
        guard RcloneHelpers.isValidRemoteName(location.remote), VaultLocation.isSafeFolder(location.folder) else { throw VaultFailure.invalid }
        if let index = locations.firstIndex(where: { $0.id == location.id }) {
            guard locations[index].remote == location.remote, locations[index].folder == location.folder else {
                throw VaultFailure.message("此保險箱已加入。請先使用原有的保險箱項目。")
            }
            locations[index].formatVersion = location.formatVersion
        } else { locations.append(location) }
        try persist()
    }
    private func journalURL(_ id: UUID) -> URL { root.appendingPathComponent("sessions/" + id.uuidString + ".json") }
    private func command(_ arguments: [String], input: Data? = nil, outputLimit: Int = 262_144) async throws -> Data {
        guard let model, !control.isCancelled, !Task.isCancelled else { throw VaultFailure.message("操作已取消。") }
        let configFlags = configurationPath.map { ["--config", $0] } ?? []
        let result = await CommandRunner.execute(model.rclonePath, arguments: ["--ask-password=false"] + configFlags + arguments +
            ["--contimeout", "8s", "--timeout", "15s", "--retries", "1", "--low-level-retries", "1"],
            timeout: 25, control: control, outputLimit: outputLimit, input: input)
        guard result.succeeded, !control.isCancelled else {
            throw VaultFailure.message(VaultRemoteFailure.message(result, selectingFolder: arguments.first == "mkdir"))
        }
        return Data(result.stdout.utf8)
    }
    /// Standard files are authoritative. Public CloudMount metadata supplies a
    /// display name only; importing an official vault does not require it.
    private func loadEnvelope(remote: String, path: String, fallbackName: String) async throws -> VaultEnvelope {
        let target = remote + ":" + path
        struct Entry: Decodable { let Name: String }
        let listing = try JSONDecoder().decode([Entry].self, from: await command(["lsjson", target, "--max-depth", "1"]))
        let names = Set(listing.map(\.Name))
        if names.contains(VaultDescriptor.configName) || names.contains(VaultDescriptor.keyName) {
            guard names.contains(VaultDescriptor.configName), names.contains(VaultDescriptor.keyName) else { throw VaultFailure.invalid }
            let key = try await command(["cat", target + "/" + VaultDescriptor.keyName], outputLimit: 65_536)
            let config = try await command(["cat", target + "/" + VaultDescriptor.configName], outputLimit: 65_536)
            let descriptor = try VaultDescriptor.parse(masterkeyFile: key, vaultConfig: config)
            var name = fallbackName
            if names.contains(VaultEnvelope.filename) {
                let data = try await command(["cat", target + "/" + VaultEnvelope.filename], outputLimit: 65_536)
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let text = object["name"] as? String, !text.isEmpty, text.utf8.count <= 256 { name = text }
            }
            return .standard(descriptor, name: name)
        }
        guard names.contains(VaultEnvelope.filename) else { throw VaultFailure.message("此位置尚未找到 CloudMount 保險箱。請確認儲存桶或資料夾位置。") }
        let legacy = try VaultEnvelope.decode(await command(["cat", target + "/" + VaultEnvelope.filename], outputLimit: 65_536))
        guard legacy.descriptor == nil else { throw VaultFailure.invalid }
        return legacy
    }
    func prepareRemotes() async {
        guard !busy, let model, !model.isConfiguringRemote, !model.configurationWriterActive else { return }
        control = CommandControl()
        do {
            let data = try await command(["config", "dump"], outputLimit: 4_194_304)
            let config = try JSONDecoder().decode([String: [String: String]].self, from: data)
            remoteTypes = config.compactMapValues { $0["type"] }
        } catch { self.error = L10n.error(error) }
    }
    func clearDiscoveries() { guard !busy else { return }; discoveries = []; error = nil }
    func folders(remote: String, path: String) async throws -> [String] {
        try Task.checkCancellation()
        guard !folderBrowseBlocked else { throw VaultFailure.message("資料夾查詢工具未回應，已停止重複查詢。請重新開啟 CloudMount 後再試。") }
        guard !busy, !folderBrowseBusy else { throw VaultFailure.message("另一項工作尚未完成，請稍後按「重新整理」。") }
        guard let model, supportedRemotes.contains(remote),
              path.isEmpty || VaultLocation.isSafeFolder(path) else {
            throw VaultFailure.message("請輸入有效的存放位置；S3 請先指定儲存桶名稱。")
        }
        folderBrowseBusy = true
        defer { folderBrowseBusy = false }
        let browseControl = CommandControl()
        let configFlags = configurationPath.map { ["--config", $0] } ?? []
        let result = await withTaskCancellationHandler {
            await CommandRunner.execute(model.rclonePath, arguments: ["--ask-password=false"] + configFlags +
                ["lsjson", remote + ":" + path, "--dirs-only", "--max-depth", "1", "--contimeout", "5s", "--timeout", "10s", "--retries", "1", "--low-level-retries", "1"],
                timeout: 15, control: browseControl, outputLimit: 1_048_576)
        } onCancel: { browseControl.cancel() }
        folderBrowseBlocked = result.stillRunning
        try Task.checkCancellation()
        guard result.succeeded else { throw VaultFailure.message(VaultRemoteFailure.message(result)) }
        struct Entry: Decodable { let Name: String; let IsDir: Bool }
        let entries = try JSONDecoder().decode([Entry].self, from: Data(result.stdout.utf8))
        return entries.filter { $0.IsDir && !$0.Name.isEmpty && !$0.Name.contains("/") && VaultLocation.isSafeFolder($0.Name) }
            .map(\.Name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    func discover(remote: String, parent: String) async {
        do { try begin("正在尋找保險箱…") } catch { self.error = L10n.error(error); return }
        defer { end() }
        discoveries = []
        do {
            let folder = try VaultLocation.parent(parent, s3: remoteTypes[remote] == "s3")
            let bytes = try await command(["lsjson", remote + ":" + folder, "--dirs-only", "--max-depth", "1"])
            struct Entry: Decodable { let Name: String; let IsDir: Bool }
            let entries = try JSONDecoder().decode([Entry].self, from: bytes)
            guard entries.count <= 100 else { throw VaultFailure.message("保險箱數量較多，請使用完整保險箱路徑加入。") }
            for item in entries where item.IsDir && UUID(uuidString: item.Name) != nil {
                guard !control.isCancelled else { throw VaultFailure.message("操作已取消。") }
                let path = folder + "/" + item.Name
                let envelope = try await loadEnvelope(remote: remote, path: path, fallbackName: item.Name)
                guard envelope.id.uuidString.lowercased() == item.Name.lowercased() else { throw VaultFailure.invalid }
                discoveries.append(VaultDiscovery(location: VaultLocation(id: envelope.id, name: envelope.name, remote: remote, folder: path, formatVersion: envelope.version), envelope: envelope))
            }
            if discoveries.isEmpty { error = L10n.string("此位置尚未找到 CloudMount 保險箱。請確認儲存桶或資料夾位置。") }
        } catch { self.error = L10n.error(error) }
    }
    func discoverExact(remote: String, path: String) async {
        do { try begin("正在尋找保險箱…") } catch { self.error = L10n.error(error); return }
        defer { end() }
        do {
            _ = try VaultLocation.parent(path, s3: remoteTypes[remote] == "s3")
            var path = path.trimmingCharacters(in: .whitespacesAndNewlines)
            while path.hasSuffix("/") { path.removeLast() }
            let envelope = try await loadEnvelope(remote: remote, path: path, fallbackName: (path as NSString).lastPathComponent)
            discoveries = [VaultDiscovery(location: VaultLocation(id: envelope.id, name: envelope.name, remote: remote, folder: path, formatVersion: envelope.version), envelope: envelope)]
        } catch { self.error = L10n.error(error) }
    }
    func create(remote: String, parent: String, name: String, password: String, remember: Bool) async -> UUID? {
        do { try begin("正在建立加密保險箱…") } catch { self.error = L10n.error(error); return nil }
        defer { end() }
        do {
            let folder = try VaultLocation.parent(parent, s3: remoteTypes[remote] == "s3")
            progress = L10n.string("1/5：正在準備保險箱金鑰…")
            let (envelope, keys) = try await Task.detached(priority: .userInitiated) { try VaultEnvelope.create(name: name, password: password) }.value
            guard !control.isCancelled else { throw VaultFailure.message("操作已取消。") }
            let location = VaultLocation(id: envelope.id, name: envelope.name, remote: remote, folder: folder + "/" + envelope.id.uuidString, formatVersion: envelope.version)
            let bytes = try JSONEncoder().encode(envelope)
            progress = L10n.string("2/5：正在建立雲端資料夾與描述檔…")
            // Create the writer directory with its parents in one request.
            // open() can reuse it instead of repeating mkdir after verification.
            _ = try await command(["mkdir", location.root + "/writers"])
            if let descriptor = envelope.descriptor, let raw = keys.cryptomatorKey {
                let seed = try VaultDisk.privateDirectory(FileManager.default.temporaryDirectory.appendingPathComponent("cm-vault-seed-" + UUID().uuidString, isDirectory: true))
                defer { try? FileManager.default.removeItem(at: seed) }
                let content = try VaultDisk.privateDirectory(seed.appendingPathComponent("content", isDirectory: true))
                let scratch = try VaultDisk.privateDirectory(seed.appendingPathComponent("scratch", isDirectory: true))
                let fs = try VaultFileSystem(store: LocalCiphertextStore(root: content), descriptor: descriptor, rawKey: raw, scratch: scratch)
                try await fs.initialize()
                try descriptor.masterkeyFile.write(to: content.appendingPathComponent(VaultDescriptor.keyName, isDirectory: false))
                try descriptor.vaultConfig.write(to: content.appendingPathComponent(VaultDescriptor.configName, isDirectory: false))
                _ = try await command(["copy", content.path, location.root])
            }
            _ = try await command(["rcat", location.root + "/" + VaultEnvelope.filename], input: bytes)
            progress = L10n.string("3/5：正在確認雲端描述檔…")
            let downloaded = try await command(["cat", location.root + "/" + VaultEnvelope.filename], outputLimit: 65_536)
            guard try VaultEnvelope.decode(downloaded) == envelope else { throw VaultFailure.invalid }
            // Persist the valid vault before testing/mounting, so a transient
            // failure never loses the path or asks the user to create again.
            try rememberLocation(location)
            try await open(location, envelope: envelope, keys: keys, remember: remember, readOnly: false, verify: true)
            return location.id
        } catch { self.error = L10n.error(error); return nil }
    }
    func unlock(_ location: VaultLocation, password: String, remember: Bool, readOnly: Bool = false, takeover: Bool = false) async -> Bool {
        needsPassword.remove(location.id)
        do { try begin("正在解鎖…") } catch { self.error = L10n.error(error); return false }
        defer { end() }
        do {
            if let existing = runtimes[location.id], existing.ready { openFinder(location.id); return true }
            guard runtimes[location.id] == nil else { throw VaultFailure.message("保險箱仍有工作程序，請先鎖定或重新整理狀態。") }
            let envelope = try await loadEnvelope(remote: location.remote, path: location.folder, fallbackName: location.name)
            guard envelope.id == location.id else { throw VaultFailure.invalid }
            let keys: VaultSecrets
            if password.isEmpty {
                guard let saved = try store.read(location.id) else { throw VaultFailure.password }
                // A locally saved key must authenticate this exact remote envelope.
                keys = try envelope.recover(code: saved.recoveryCode)
                guard keys == saved else { throw VaultFailure.password }
            } else { keys = try await Task.detached(priority: .userInitiated) { try envelope.unlock(password: password) }.value }
            try rememberLocation(location)
            try await open(location, envelope: envelope, keys: keys, remember: remember, readOnly: readOnly, verify: false, takeover: takeover)
            return true
        } catch {
            if case VaultFailure.message(let key) = error,
               key == "密碼不正確，或保險箱描述檔已損壞。" || key == "無法讀取鑰匙圈，請使用保險箱密碼解鎖。" { needsPassword.insert(location.id) }
            self.error = L10n.error(error); return false
        }
    }
    private func open(_ location: VaultLocation, envelope: VaultEnvelope, keys: VaultSecrets, remember: Bool, readOnly: Bool, verify: Bool, takeover: Bool = false) async throws {
        guard let model, runtimes[location.id] == nil, !control.isCancelled else { throw VaultFailure.message("操作已取消。") }
        let path = destination(location.id)
        await model.macFuse.refresh(helperPath: model.helperPath)
        guard let mountMethod = model.macFuse.resolved(model.method, destination: path, readOnly: readOnly) else {
            model.macFuse.showSetup = true
            throw VaultFailure.message("請先安裝或更新 macFUSE，也可選擇免安裝的 NFS。")
        }
        let config = try JSONDecoder().decode([String: [String: String]].self, from: await command(["config", "dump"], outputLimit: 4_194_304))
        guard let base = config[location.remote] else { throw VaultFailure.message("請先連接此保險箱使用的遠端空間。") }
        if readOnly, try await dirtyCount(location.id) > 0 { throw VaultFailure.message("這台 Mac 尚有未上傳修改，請先以可寫模式解鎖並完成上傳。") }
        let prepared = await CommandRunner.execute(model.helperPath, arguments: ["prepare", path], timeout: 5)
        guard !prepared.timedOut, !prepared.stillRunning else { model.blockMountOperations(); throw VaultFailure.message("系統掛載指令未回應，請重新啟動 Mac 後再試。") }
        guard prepared.succeeded else { throw VaultFailure.message("保險箱掛載位置已被使用或包含檔案，請先檢查目前掛載。") }
        let directory = try VaultDisk.privateDirectory(URL(fileURLWithPath: "/private/tmp/cmv-" + UUID().uuidString.prefix(16)))
        let cache = try VaultDisk.privateDirectory(root.appendingPathComponent("cache/" + location.id.uuidString))
        let worker = VaultWorker(executable: model.rclonePath, socket: directory.appendingPathComponent("rpc.sock").path)
        var runtime: VaultRuntime?
        do {
            try await worker.start(cache: cache.path, sizeGB: model.cacheMaxSizeGB, ageHours: model.cacheMaxAgeHours,
                                   directoryMinutes: model.cacheDirectoryMinutes)
            try await worker.configure(remote: location.remote, config: base, location: location, keys: keys, descriptor: envelope.descriptor, readOnly: readOnly)
            if verify { progress = L10n.string("4/5：正在驗證雲端加密讀寫…"); try await worker.verifyRoundTrip() }
            guard !control.isCancelled else { throw VaultFailure.message("操作已取消。") }
            if verify { progress = L10n.string("5/5：正在取得寫入權限並掛載…") }
            let writer = readOnly ? nil : try await acquireWriter(location, keys: keys, takeover: takeover, directoryPrepared: verify)
            let journal = VaultJournal(location: location, socket: worker.socket, destination: path, writer: writer, readOnly: readOnly, method: mountMethod)
            let session = VaultRuntime(journal: journal, worker: worker, keys: keys, envelope: envelope)
            runtime = session; runtimes[location.id] = session; model.vaultWorkersActive = true
            try VaultDisk.write(journal, to: journalURL(location.id))
            if !verify { progress = L10n.string("正在掛載保險箱…") }
            try await worker.mount(destination: path, readOnly: readOnly, label: location.name, method: mountMethod)
            guard let snapshot = await model.scanMountedVolumes(), snapshot.contains(where: { RcloneHelpers.pathsEqual($0.destination, path) }) else { throw VaultFailure.message("無法確認保險箱掛載，請先檢查目前狀態。") }
            session.ready = true; session.status = L10n.string(readOnly ? "已解鎖（唯讀）" : "已解鎖")
            statuses[location.id] = session.status
            if remember { do { try store.save(keys); rememberedIDs.insert(location.id) } catch { self.error = L10n.error(error) } }
            else {
                do { try store.remove(location.id); rememberedIDs.remove(location.id); setAutomatic(location.id, enabled: false) }
                catch { self.error = L10n.error(error) }
            }
            startPolling(session)
            if openAutomatically { openFinder(location.id) }
        } catch {
            lastDiagnostic = worker.bridgeDiagnostic()
            if let runtime {
                statuses[location.id] = L10n.string("尚未鎖定，請檢查狀態")
                if worker.mountInFlight { model.blockMountOperations() }
                startPolling(runtime)
            } else {
                if await worker.shutdownAfterUnmount() {
                    try? FileManager.default.removeItem(at: directory)
                } else {
                    // Never discard the only endpoint for a worker whose exit
                    // is uncertain, even if mounting has not started yet.
                    let journal = VaultJournal(location: location, socket: worker.socket, destination: path, writer: nil, readOnly: readOnly, method: mountMethod)
                    let retained = VaultRuntime(journal: journal, worker: worker, keys: keys, envelope: envelope)
                    runtimes[location.id] = retained; model.vaultWorkersActive = true
                    try? VaultDisk.write(journal, to: journalURL(location.id))
                    statuses[location.id] = L10n.string("尚未鎖定，請檢查狀態")
                    model.blockMountOperations()
                }
            }
            throw error
        }
    }
    private func acquireWriter(_ location: VaultLocation, keys: VaultSecrets, takeover: Bool, directoryPrepared: Bool = false) async throws -> String {
        let parent = location.root + "/writers"
        if !directoryPrepared { _ = try await command(["mkdir", parent]) }
        let name = device.uuidString + ".json"
        // No automatic lease expiry: an offline computer may still have unsent
        // edits. Another computer can always open read-only without taking over.
        try await checkWriters(location, keys: keys, own: name, removingForeign: takeover)
        _ = try await command(["rcat", parent + "/" + name], input: JSONEncoder().encode(VaultLease.make(keys, device: device)))
        do { try await checkWriters(location, keys: keys, own: name) }
        catch { _ = try? await command(["deletefile", parent + "/" + name]); throw error }
        return name
    }
    private func checkWriters(_ location: VaultLocation, keys: VaultSecrets, own: String, removingForeign: Bool = false) async throws {
        struct Entry: Decodable { let Name: String; let IsDir: Bool }
        let bytes = try await command(["lsjson", location.root + "/writers", "--files-only", "--max-depth", "1"])
        let list = try JSONDecoder().decode([Entry].self, from: bytes)
        guard list.count <= 8 else { throw VaultFailure.message("另一台電腦可能仍在使用此保險箱。請先在該電腦鎖定，或以唯讀開啟。") }
        for item in list where !item.IsDir && item.Name != own {
            guard item.Name.hasSuffix(".json"), UUID(uuidString: String(item.Name.dropLast(5))) != nil else { throw VaultFailure.invalid }
            let data = try await command(["cat", location.root + "/writers/" + item.Name], outputLimit: 16_384)
            let lease = try JSONDecoder().decode(VaultLease.self, from: data)
            guard lease.valid(keys), lease.device.uuidString + ".json" == item.Name else { throw VaultFailure.invalid }
            if removingForeign {
                _ = try await command(["deletefile", location.root + "/writers/" + item.Name])
                continue
            }
            throw VaultFailure.message("另一台電腦可能仍在使用此保險箱。請先在該電腦鎖定，或以唯讀開啟。")
        }
    }
    private func releaseWriter(_ journal: VaultJournal) async throws {
        guard let writer = journal.writer else { return }
        guard writer == device.uuidString + ".json" else { throw VaultFailure.invalid }
        struct Entry: Decodable { let Name: String }
        let bytes = try await command(["lsjson", journal.location.root + "/writers", "--files-only", "--max-depth", "1"])
        let list = try JSONDecoder().decode([Entry].self, from: bytes)
        if list.contains(where: { $0.Name == writer }) { _ = try await command(["deletefile", journal.location.root + "/writers/" + writer]) }
    }
    func clearPendingMarker(_ id: UUID) async {
        guard runtimes[id] == nil else { return }
        do { try begin("正在清理寫入標記…") } catch { self.error = L10n.error(error); return }
        defer { end() }
        do {
            let journal = try JSONDecoder().decode(VaultJournal.self, from: Data(contentsOf: journalURL(id)))
            guard journal.cleanupOnly, VaultLocation.isSafeFolder(journal.location.folder) else { throw VaultFailure.invalid }
            try await releaseWriter(journal)
            try FileManager.default.removeItem(at: journalURL(id))
            pendingCleanup.remove(id); statuses[id] = nil
        } catch { self.error = L10n.error(error) }
    }
    func transferTouchesVault(remote: String, folder: String, deletingAncestor: Bool) -> Bool {
        let folder = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return locations.contains { location in
            guard location.remote == remote else { return false }
            return folder == location.folder || folder.hasPrefix(location.folder + "/") ||
                (deletingAncestor && (folder.isEmpty || location.folder.hasPrefix(folder + "/")))
        }
    }
    func copyExclusions(remote: String, folder: String) -> [String] {
        let folder = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return locations.filter { $0.remote == remote && (folder.isEmpty || $0.folder.hasPrefix(folder + "/")) }.flatMap {
            ["--exclude", "/" + (folder.isEmpty ? $0.folder : String($0.folder.dropFirst(folder.count + 1))) + "/**"]
        }
    }
    private func startPolling(_ runtime: VaultRuntime) {
        runtime.poll?.cancel()
        runtime.poll = Task { [weak self, weak runtime] in
            while !Task.isCancelled {
                guard let self, let runtime, runtimes[runtime.journal.location.id] === runtime else { return }
                await refresh(runtime)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
    private func refresh(_ runtime: VaultRuntime) async {
        let id = runtime.journal.location.id
        guard !busy else { return }
        do {
            guard await runtime.worker.bridgeIsHealthy() else { throw VaultFailure.invalid }
            let state = try VaultUploadState.parse(await runtime.worker.call("vfs/stats", ["fs": "cloudmount_vault:"], timeout: 2))
            let queue = try await runtime.worker.call("vfs/queue", ["fs": "cloudmount_vault:"], timeout: 2)
            let hasRetries = (queue["queue"] as? [[String: Any]])?.contains { ($0["tries"] as? Int ?? 0) > 0 && ($0["uploading"] as? Bool == false) } == true
            let stats = hasRetries || state.errors > 0 ? try? await runtime.worker.call("core/stats", timeout: 2) : nil
            let dirty = try await dirtyCount(id)
            let report = try VaultUploadReport.make(state: state, queue: queue, dirty: dirty, lastError: stats?["lastError"] as? String)
            guard runtimes[id] === runtime, !busy, !Task.isCancelled else { return }
            guard runtime.ready else { return }
            uploadReports[id] = report
            runtime.status = runtime.journal.readOnly ? L10n.string("已解鎖（唯讀）") : report.title
            statuses[id] = runtime.status
        } catch {
            guard runtimes[id] === runtime, !busy, !Task.isCancelled else { return }
            uploadReports[id] = nil
            statuses[id] = L10n.string("無法確認上傳狀態，請檢查連線")
        }
    }
    private func dirtyCount(_ id: UUID) async throws -> Int {
        guard let model else { throw VaultFailure.invalid }
        let path = root.appendingPathComponent("cache/" + id.uuidString).path
        let result = await CommandRunner.execute(model.helperPath, arguments: ["vault-cache", path + "/vfsMeta", path], timeout: 5, outputLimit: 4096)
        if result.timedOut || result.stillRunning { model.blockMountOperations() }
        guard result.succeeded, let count = Int(result.stdout), count >= 0 else { throw VaultFailure.message("無法確認本機快取狀態；已保留資料，請稍後重試。") }
        return count
    }
    private func ensureUploadsComplete(_ runtime: VaultRuntime) async throws {
        let dirty = try await dirtyCount(runtime.journal.location.id)
        if runtime.stopped {
            guard dirty == 0 else { throw VaultFailure.message("尚未鎖定：請儲存並關閉檔案，等待上傳完成後重試。") }
            return
        }
        let list = try await runtime.worker.call("vfs/list", timeout: 3)
        guard let names = list["vfses"] as? [String] else { throw VaultFailure.invalid }
        if !names.isEmpty {
            let state = try VaultUploadState.parse(await runtime.worker.call("vfs/stats", ["fs": "cloudmount_vault:"], timeout: 3))
            let queue = try await runtime.worker.call("vfs/queue", ["fs": "cloudmount_vault:"], timeout: 3)
            let report = try VaultUploadReport.make(state: state, queue: queue, dirty: dirty, lastError: nil)
            if report.warning { throw VaultFailure.message("尚未鎖定：有上傳失敗或空間不足，本機修改已保留。請查看上傳狀態。") }
            guard state.clean, report.phase == .uploaded else {
                throw VaultFailure.message("尚未鎖定：請儲存並關閉檔案，等待上傳完成後重試。")
            }
        }
        guard dirty == 0 else { throw VaultFailure.message("尚未鎖定：請儲存並關閉檔案，等待上傳完成後重試。") }
    }
    private func waitForUploads(_ runtime: VaultRuntime) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while true {
            do { try await ensureUploadsComplete(runtime); return }
            catch {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw error }
                progress = L10n.string("正在等待檔案關閉與上傳完成…")
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
        }
    }
    func lock(_ id: UUID, quitting: Bool = false) async -> Bool {
        guard !busy, let model, let runtime = runtimes[id] else { return runtimes[id] == nil }
        guard !model.vaultOperationBusy, model.activeUnmountID == nil, model.startingMountID == nil else {
            error = L10n.string("請先等待目前掛載或保險箱工作完成。")
            if quitting { model.errorMessage = error }
            return false
        }
        busy = true; model.vaultOperationBusy = true; control = CommandControl(); progress = L10n.string("正在安全鎖定…"); error = nil
        defer { end() }
        do {
            await runtime.worker.refreshMountJob()
            guard !runtime.worker.mountInFlight else { throw VaultFailure.message("保險箱掛載仍在處理，已停止重複操作。") }
            try await waitForUploads(runtime)
            let result = await UnmountOperation.run(path: runtime.journal.destination, timeout: 8,
                snapshot: { await model.scanMountedVolumes() })
            guard result == .unmounted else {
                if result == .unsafe { model.blockMountOperations() }
                throw VaultFailure.message("尚未鎖定：檔案可能仍被使用，請關閉檔案與 Finder 預覽後重試。")
            }
            runtime.ready = false
            // Close the race with a write that completed just before umount.
            // Retain worker, key and cache if anything still needs uploading.
            try await ensureUploadsComplete(runtime)
            if !runtime.stopped {
                guard await runtime.worker.shutdownAfterUnmount() else { model.blockMountOperations(); throw VaultFailure.message("掛載已卸載，但工作程序尚未停止；請重新啟動 Mac 後再試。") }
                runtime.stopped = true
            }
            guard try await dirtyCount(id) == 0 else { throw VaultFailure.message("尚有本機修改，請重新解鎖恢復上傳。") }
            var cleanup = runtime.journal; cleanup.cleanupOnly = true
            try VaultDisk.write(cleanup, to: journalURL(id))
            var released = true
            do { try await releaseWriter(cleanup) }
            catch { released = false }
            runtime.poll?.cancel(); runtime.keys = nil
            runtimes[id] = nil
            uploadReports[id] = nil
            if released {
                statuses[id] = nil; pendingCleanup.remove(id)
                try? FileManager.default.removeItem(at: journalURL(id))
            } else {
                pendingCleanup.insert(id)
                statuses[id] = L10n.string("已鎖定，等待清理雲端寫入標記")
            }
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: runtime.worker.socket).deletingLastPathComponent())
            return true
        } catch {
            statuses[id] = L10n.string(runtime.ready ? "尚未鎖定，請重試" : "尚未完成鎖定，請重試")
            self.error = L10n.error(error)
            if quitting { model.errorMessage = L10n.error(error) }
            return false
        }
    }
    func resume(_ id: UUID) async {
        guard canResume(id), let runtime = runtimes[id], let model else { return }
        do { try begin("正在解鎖…") } catch { self.error = L10n.error(error); return }
        defer { end() }
        do {
            await model.macFuse.refresh(helperPath: model.helperPath)
            guard model.macFuse.resolved(runtime.journal.method, destination: runtime.journal.destination, readOnly: runtime.journal.readOnly) != nil else {
                model.macFuse.showSetup = true
                throw VaultFailure.message("請先安裝或更新 macFUSE，也可選擇免安裝的 NFS。")
            }
            let prepared = await CommandRunner.execute(model.helperPath, arguments: ["prepare", runtime.journal.destination], timeout: 5)
            if prepared.timedOut || prepared.stillRunning { model.blockMountOperations() }
            guard prepared.succeeded else { throw VaultFailure.message("保險箱掛載位置已被使用或包含檔案，請先檢查目前掛載。") }
            try await runtime.worker.mount(destination: runtime.journal.destination, readOnly: runtime.journal.readOnly, label: runtime.journal.location.name, method: runtime.journal.method)
            guard let snapshot = await model.scanMountedVolumes(), snapshot.contains(where: { RcloneHelpers.pathsEqual($0.destination, runtime.journal.destination) }) else { throw VaultFailure.invalid }
            runtime.ready = true
            statuses[id] = L10n.string("已解鎖")
            if openAutomatically { openFinder(id) }
        } catch {
            if runtime.worker.mountInFlight { model.blockMountOperations() }
            self.error = L10n.error(error)
        }
    }
    func lockAllForQuit() async -> Bool {
        guard !busy else { model?.errorMessage = L10n.string("保險箱工作尚未完成，請稍後再結束 app。"); return false }
        for id in Array(runtimes.keys) { if !(await lock(id, quitting: true)) { return false } }
        return true
    }
    func openFinder(_ id: UUID) {
        guard let runtime = runtimes[id], runtime.ready, let model else { return }
        Task { await model.finderOpener.open(path: runtime.journal.destination, helper: model.helperPath) }
    }
    func cancel() { control.cancel() }
    func setAutomatic(_ id: UUID, enabled: Bool) {
        guard let index = locations.firstIndex(where: { $0.id == id }), !enabled || isRemembered(id) else { return }
        locations[index].automaticUnlock = enabled
        do { try persist() } catch { self.error = L10n.error(error) }
    }
    func forgetPassword(_ id: UUID) {
        do { try store.remove(id); rememberedIDs.remove(id); setAutomatic(id, enabled: false); objectWillChange.send() }
        catch { self.error = L10n.error(error) }
    }
    func removeLocal(_ id: UUID) async {
        guard !busy, runtimes[id] == nil else { return }
        do {
            guard try await dirtyCount(id) == 0 else { throw VaultFailure.message("這台 Mac 尚有未上傳修改，請先以可寫模式解鎖並完成上傳。") }
            guard let snapshot = await model?.scanMountedVolumes(), !snapshot.contains(where: { RcloneHelpers.pathsEqual($0.destination, destination(id)) }) else { throw VaultFailure.message("上次保險箱掛載尚未釋放，請重新啟動 Mac 後再試。") }
            guard !busy, runtimes[id] == nil else { return }
            try store.remove(id); rememberedIDs.remove(id); locations.removeAll { $0.id == id }; try persist()
            if pendingCleanup.remove(id) != nil { try? FileManager.default.removeItem(at: journalURL(id)); statuses[id] = nil }
        }
        catch { self.error = L10n.error(error) }
    }
    func deleteCloud(_ id: UUID, confirmation: String) async -> Bool {
        guard let location = locations.first(where: { $0.id == id }), confirmation == location.name,
              runtimes[id] == nil, RcloneHelpers.isValidRemoteName(location.remote), VaultLocation.isSafeFolder(location.folder),
              UUID(uuidString: location.folder.split(separator: "/").last.map(String.init) ?? "") == id else {
            error = L10n.string("請先鎖定保險箱，並輸入完整名稱確認刪除。")
            return false
        }
        do { try begin("正在刪除雲端保險箱…") } catch { self.error = L10n.error(error); return false }
        defer { end() }
        // A non-UUID writer entry also blocks older CloudMount clients. The
        // second listing catches a writer that raced with our first check.
        let marker = location.root + "/writers/deleting.json"
        let token = ["format": "CloudMountDelete-v1", "vault": id.uuidString, "device": device.uuidString, "nonce": UUID().uuidString]
        let bytes = (try? JSONEncoder().encode(token)) ?? Data()
        var ownsMarker = false
        do {
            guard try await dirtyCount(id) == 0 else { throw VaultFailure.message("這台 Mac 尚有未上傳修改，請先以可寫模式解鎖並完成上傳。") }
            guard let snapshot = await model?.scanMountedVolumes(), !snapshot.contains(where: { RcloneHelpers.pathsEqual($0.destination, destination(id)) }) else {
                throw VaultFailure.message("上次保險箱掛載尚未釋放，請重新啟動 Mac 後再試。")
            }
            let envelope = try await loadEnvelope(remote: location.remote, path: location.folder, fallbackName: location.name)
            guard envelope.id == id, envelope.name == location.name else { throw VaultFailure.invalid }
            struct Entry: Decodable { let Name: String }
            let entries = try JSONDecoder().decode([Entry].self, from: await command(["lsjson", location.root + "/writers", "--max-depth", "1"]))
            guard entries.isEmpty else { throw VaultFailure.message("仍有電腦持有寫入標記，無法刪除。請先在各電腦鎖定保險箱。") }
            _ = try await command(["rcat", marker], input: bytes)
            ownsMarker = true
            let rechecked = try JSONDecoder().decode([Entry].self, from: await command(["lsjson", location.root + "/writers", "--max-depth", "1"]))
            guard rechecked.count == 1, rechecked.first?.Name == "deleting.json",
                  try await command(["cat", marker], outputLimit: 16_384) == bytes else {
                throw VaultFailure.message("仍有電腦持有寫入標記，無法刪除。請先在各電腦鎖定保險箱。")
            }
            // The target must be the exact, descriptor-verified UUID folder,
            // never the shared container, bucket, remote or a user-entered path.
            _ = try await command(["purge", location.root])
            ownsMarker = false
            locations.removeAll { $0.id == id }; try persist()
            pendingCleanup.remove(id); uploadReports[id] = nil; statuses[id] = nil
            try? FileManager.default.removeItem(at: journalURL(id))
            do { try store.remove(id); rememberedIDs.remove(id) }
            catch { self.error = L10n.string("雲端保險箱已刪除，但無法清除鑰匙圈中的解鎖資訊。") }
            return true
        } catch {
            if ownsMarker, let current = try? await command(["cat", marker], outputLimit: 16_384), current == bytes {
                _ = try? await command(["deletefile", marker])
            }
            self.error = L10n.error(error)
            return false
        }
    }
    func recoveryWords(_ id: UUID) -> String? {
        guard let runtime = runtimes[id], runtime.ready, runtime.envelope?.descriptor != nil else { return nil }
        return runtime.keys?.recoveryCode
    }
    func prepareRecovery(_ id: UUID) async -> Bool {
        guard let runtime = runtimes[id], runtime.ready else { return false }
        if recoveryWords(id) != nil { return true }
        do { try begin("正在準備復原資訊…") } catch { self.error = L10n.error(error); return false }
        defer { end() }
        do {
            let location = runtime.journal.location
            let envelope = try await loadEnvelope(remote: location.remote, path: location.folder, fallbackName: location.name)
            let saved = try runtime.keys ?? store.read(id)
            guard envelope.id == id, envelope.descriptor != nil,
                  let keys = saved,
                  try envelope.recover(code: keys.recoveryCode) == keys else { throw VaultFailure.password }
            guard runtimes[id] === runtime, runtime.ready else { return false }
            runtime.envelope = envelope; runtime.keys = keys
            return true
        } catch { self.error = L10n.error(error); return false }
    }
    func exportRecovery(_ id: UUID) {
        if let runtime = runtimes[id], runtime.ready, runtime.envelope == nil,
           runtime.journal.location.formatVersion == 8 {
            Task { if await prepareRecovery(id) { exportRecovery(id) } }
            return
        }
        guard let runtime = runtimes[id], let envelope = runtime.envelope, let keys = runtime.keys else {
            error = L10n.string("請先用密碼解鎖保險箱，再匯出復原檔。"); return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "CloudMount-\(runtime.journal.location.name).cloudmount-recovery"
        panel.message = L10n.string("持有此復原檔即可解鎖保險箱。請存放在安全位置，避免放在同一個雲端空間。")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let model else { return }
        Task {
            do {
                let content = try JSONEncoder().encode(VaultRecoveryFile(format: envelope.descriptor == nil ? "CloudMountRecovery-v1" : "CryptomatorRecovery-v8", envelope: envelope,
                    code: keys.recoveryCode, folder: runtime.journal.location.folder, instructions: envelope.descriptor == nil ? nil : "Standard Cryptomator format 8. The code field contains the official 44-word recovery key. Download the entire vault folder, preserving vault.cryptomator, masterkey.cryptomator and d/. Open vault.cryptomator in official Cryptomator with your password; if the password is lost, use its recovery-key/password-reset workflow and these 44 words. CloudMount is not required. This key cannot restore deleted or missing ciphertext. Keep this file private and outside the vault."))
                let result = await CommandRunner.execute(model.helperPath, arguments: ["save-vault-recovery", url.path], timeout: 5, outputLimit: 4096, input: content)
                guard result.succeeded else { throw VaultFailure.invalid }
                recoverySaved.insert(id)
            } catch { self.error = L10n.string("無法儲存復原檔，請選擇本機的安全位置。") }
        }
    }
    func recover(remote: String, file: URL, remember: Bool) async -> Bool {
        do { try begin("正在復原保險箱…") } catch { self.error = L10n.error(error); return false }
        defer { end() }
        do {
            let result = await CommandRunner.execute("/bin/cat", arguments: [file.path], timeout: 5, control: control, outputLimit: 65_536)
            guard result.succeeded else { throw VaultFailure.invalid }
            let bytes = Data(result.stdout.utf8)
            guard bytes.count < 65_536 else { throw VaultFailure.invalid }
            let backup = try JSONDecoder().decode(VaultRecoveryFile.self, from: bytes)
            guard VaultLocation.isSafeFolder(backup.folder) else { throw VaultFailure.invalid }
            let keys = try backup.secrets()
            let current = try await loadEnvelope(remote: remote, path: backup.folder, fallbackName: backup.envelope.name)
            if current.descriptor != nil {
                guard try current.recover(code: backup.code) == keys else { throw VaultFailure.invalid }
            } else { guard current == backup.envelope else { throw VaultFailure.invalid } }
            let location = VaultLocation(id: current.id, name: current.name, remote: remote, folder: backup.folder, formatVersion: current.version)
            try rememberLocation(location)
            try await open(location, envelope: current, keys: keys, remember: remember, readOnly: false, verify: false)
            return true
        } catch { self.error = L10n.error(error); return false }
    }
    func reconcileAndStart(allowAutomatic: Bool) async {
        guard !reconciled, let model else { return }; reconciled = true
        do {
            let directory = root.appendingPathComponent("sessions")
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            guard files.count <= 100 else { throw VaultFailure.invalid }
            for file in files where file.pathExtension == "json" {
                let data = try Data(contentsOf: file)
                let journal = try JSONDecoder().decode(VaultJournal.self, from: data)
                try rememberLocation(journal.location)
                let socketParent = URL(fileURLWithPath: journal.socket).deletingLastPathComponent().path
                guard journal.destination == destination(journal.location.id), socketParent.hasPrefix("/private/tmp/cmv-"),
                      URL(fileURLWithPath: journal.socket).lastPathComponent == "rpc.sock" else { throw VaultFailure.invalid }
                if journal.cleanupOnly {
                    guard let snapshot = await model.scanMountedVolumes(), !snapshot.contains(where: { RcloneHelpers.pathsEqual($0.destination, journal.destination) }) else { throw VaultFailure.invalid }
                    pendingCleanup.insert(journal.location.id)
                    do {
                        try await releaseWriter(journal)
                        try FileManager.default.removeItem(at: file)
                        pendingCleanup.remove(journal.location.id)
                    } catch { statuses[journal.location.id] = L10n.string("已鎖定，等待清理雲端寫入標記") }
                    continue
                }
                var info = stat()
                let socketExists = lstat(journal.socket, &info) == 0
                if socketExists {
                    guard info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFSOCK else { throw VaultFailure.invalid }
                    let worker = VaultWorker(executable: model.rclonePath, socket: journal.socket, attached: true)
                    guard (try? await worker.call("core/version", timeout: 2)) != nil else { model.blockMountOperations(); throw VaultFailure.message("上次保險箱程序未回應，請重新啟動 Mac 後再試。") }
                    try await worker.capturePID()
                    let runtime = VaultRuntime(journal: journal, worker: worker, keys: try? store.read(journal.location.id), envelope: nil)
                    runtime.ready = await model.scanMountedVolumes()?.contains { RcloneHelpers.pathsEqual($0.destination, journal.destination) } ?? false
                    runtimes[journal.location.id] = runtime
                    statuses[journal.location.id] = L10n.string("已接回上次保險箱，請檢查狀態")
                    startPolling(runtime)
                } else {
                    guard let snapshot = await model.scanMountedVolumes(), !snapshot.contains(where: { RcloneHelpers.pathsEqual($0.destination, journal.destination) }) else {
                        model.blockMountOperations(); throw VaultFailure.message("上次保險箱掛載尚未釋放，請重新啟動 Mac 後再試。")
                    }
                    // Keep the writer marker and cache for recovery by this Mac.
                    try? FileManager.default.removeItem(at: file)
                }
            }
            model.vaultWorkersActive = !runtimes.isEmpty
            if let snapshot = await model.scanMountedVolumes() {
                for location in locations where runtimes[location.id] == nil && snapshot.contains(where: { RcloneHelpers.pathsEqual($0.destination, destination(location.id)) }) {
                    statuses[location.id] = L10n.string("仍有舊掛載，尚未鎖定")
                    model.blockMountOperations()
                    error = L10n.string("上次保險箱掛載尚未釋放，請重新啟動 Mac 後再試。")
                }
            }
            if allowAutomatic {
                for location in locations where location.automaticUnlock && runtimes[location.id] == nil {
                    guard model.autoMountEnabled, available else { break }
                    if isRemembered(location.id) { _ = await unlock(location, password: "", remember: true) }
                }
            }
        } catch { self.error = L10n.error(error) }
    }
}
