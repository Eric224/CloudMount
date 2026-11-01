import AppKit
import Combine
import CryptoKit
import Foundation
import ServiceManagement
import Darwin

struct MountRecord: Identifiable {
    let id: UUID
    let remote: String
    let folder: String
    let destination: String
    var phase: MountPhase
    var problem: String? = nil
    let owned: Bool
    var status: String { problem ?? phase.label }
    func retainedAfterScan(paths: Set<String>, hasProcess: Bool) -> Bool {
        hasProcess || paths.contains(destination) || [.preparing, .connecting, .unmounting, .blocked].contains(phase)
    }
}

enum MountPhase: String {
    case preparing, connecting, mounted, inUse, unmounting, failed, blocked
    var label: String {
        L10n.string([.preparing: "正在檢查連線…", .connecting: "連線中…", .mounted: "已掛載",
                     .inUse: "仍已掛載（使用中）", .unmounting: "卸載中…", .failed: "掛載失敗", .blocked: "需要重新啟動 Mac"] [self]!)
    }
    var allowsOpening: Bool { self == .mounted || self == .inUse }
    var unmountActionTitle: String {
        L10n.string(self == .preparing || self == .connecting ? "停止連線" : self == .inUse ? "重試卸載" : "卸載")
    }
    static func afterUnmountFailure(previous: MountPhase, current: MountPhase, busy: Bool) -> MountPhase {
        // A filesystem process can fail while the unmount utility is running.
        // Do not turn a genuinely failed or blocked mount back into a healthy one.
        if current == .failed || current == .blocked { return current }
        return previous.allowsOpening ? (busy ? .inUse : .mounted) : previous
    }
}

struct SystemMount: Codable, Equatable {
    let source: String
    let destination: String
    let fileSystem: String
}
struct MountBookmark: Codable { let remote: String; let folder: String; let destination: String }
struct MountPreparation: Decodable { let path: String; let allowNonEmpty: Bool }
struct MountRequest {
    let remote: String
    let folder: String
    let destination: String
    let method: MountMethod
    let readOnly: Bool
    let cacheReadFiles: Bool
    let cacheMaxSizeGB: Int
    let cacheMaxAgeHours: Int
    let cacheDirectoryMinutes: Int
}

struct RcloneProvider: Decodable, Identifiable, Hashable {
    let name: String
    let prefix: String
    let description: String
    let options: [RcloneProviderOption]

    var id: String { prefix }

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case prefix = "Prefix"
        case description = "Description"
        case options = "Options"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        prefix = try c.decode(String.self, forKey: .prefix)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        options = try c.decodeIfPresent([RcloneProviderOption].self, forKey: .options) ?? []
    }
}

struct RcloneProviderOption: Decodable, Identifiable, Hashable {
    struct Example: Decodable, Hashable {
        let value: String
        let help: String
        let provider: String?
        enum CodingKeys: String, CodingKey { case value = "Value"; case help = "Help"; case provider = "Provider" }
    }

    let name: String
    let help: String
    let type: String
    let defaultValue: String?
    let required: Bool
    let isPassword: Bool
    let sensitive: Bool
    let providerFilter: String
    var isSecret: Bool {
        let identifiers: Set<String> = ["host", "user", "username", "email", "account", "domain", "endpoint", "url", "spn", "remote", "upstreams", "region", "root_folder_id", "drive_id", "tenant"]
        return isPassword || (sensitive && !identifiers.contains(name) && !name.hasSuffix("_file")) ||
            ["api_key", "api_secret", "private_key", "key_pem", "access_grant", "passphrase"].contains(name) || name.contains("token")
    }
    let advanced: Bool
    let exclusive: Bool
    let hidden: Bool
    let examples: [Example]

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case help = "Help"
        case type = "Type"
        case defaultValue = "DefaultStr"
        case defaultNumber = "Default"
        case required = "Required"
        case isPassword = "IsPassword"
        case sensitive = "Sensitive"
        case providerFilter = "Provider"
        case advanced = "Advanced"
        case exclusive = "Exclusive"
        case hidden = "Hide"
        case examples = "Examples"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        help = try c.decodeIfPresent(String.self, forKey: .help) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "string"
        if let value = try? c.decode(String.self, forKey: .defaultValue) {
            defaultValue = value
        } else if let value = try? c.decode(String.self, forKey: .defaultNumber) {
            defaultValue = value
        } else if let value = try? c.decode(Bool.self, forKey: .defaultNumber) {
            defaultValue = String(value)
        } else if let value = try? c.decode(Int.self, forKey: .defaultNumber) {
            defaultValue = String(value)
        } else {
            defaultValue = nil
        }
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? false
        isPassword = try c.decodeIfPresent(Bool.self, forKey: .isPassword) ?? false
        sensitive = try c.decodeIfPresent(Bool.self, forKey: .sensitive) ?? false
        providerFilter = try c.decodeIfPresent(String.self, forKey: .providerFilter) ?? ""
        advanced = try c.decodeIfPresent(Bool.self, forKey: .advanced) ?? false
        exclusive = try c.decodeIfPresent(Bool.self, forKey: .exclusive) ?? false
        if let value = try? c.decode(Bool.self, forKey: .hidden) {
            hidden = value
        } else if let value = try? c.decode(Int.self, forKey: .hidden) {
            hidden = value & 2 != 0
        } else {
            hidden = false
        }
        examples = try c.decodeIfPresent([Example].self, forKey: .examples) ?? []
    }
}

struct RcloneConfigQuestion: Decodable {
    let state: String
    let option: RcloneProviderOption
    let error: String
    enum CodingKeys: String, CodingKey { case state = "State"; case option = "Option"; case error = "Error" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(String.self, forKey: .state)
        option = try c.decode(RcloneProviderOption.self, forKey: .option)
        error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
    }

    func accepts(answer: String) -> Bool {
        let effective = answer.isEmpty ? (option.defaultValue ?? "") : answer
        return !option.required || !effective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var rclonePath: String { didSet { settings.set(rclonePath, forKey: "rclonePath") } }
    @Published var version = ""
    @Published var remotes: [String] = []
    @Published var providers: [RcloneProvider] = []
    @Published var isLoadingProviders = false
    @Published var isConfiguringRemote = false
    @Published var configurationBusy = false
    @Published var configurationWriterActive = false
    @Published var configurationQuestion: RcloneConfigQuestion?
    @Published var configurationError: String?
    @Published var configurationStatus = ""
    @Published var remoteEditorStatus = ""
    @Published var selectedRemote = "" {
        didSet { if selectedRemote != oldValue { folder = preferredMountFolder(for: selectedRemote) } }
    }
    @Published var folder = ""
    private var preferredMountFolders: [String: String] = [:]
    var selectedRemoteIsS3: Bool { vaults.remoteTypes[selectedRemote] == "s3" }
    var mountBucket: String {
        get { RcloneHelpers.splitS3MountPath(folder).bucket }
        set { folder = RcloneHelpers.s3MountPath(bucket: newValue, subfolder: RcloneHelpers.splitS3MountPath(folder).subfolder) }
    }
    var mountSubfolder: String {
        get { selectedRemoteIsS3 ? RcloneHelpers.splitS3MountPath(folder).subfolder : folder }
        set { folder = selectedRemoteIsS3 ? RcloneHelpers.s3MountPath(bucket: mountBucket, subfolder: newValue) : newValue }
    }
    func preferredMountFolder(for remote: String) -> String { preferredMountFolders[remote] ?? "" }
    func setPreferredMountFolder(_ path: String, for remote: String) {
        preferredMountFolders[remote] = RcloneHelpers.normalizedFolder(path)
        settings.set(preferredMountFolders, forKey: "preferredMountFolders")
        if selectedRemote == remote { folder = preferredMountFolders[remote] ?? "" }
    }
    @Published var destination = ""
    @Published var method: MountMethod { didSet { settings.set(method.rawValue, forKey: "mountMethodPreference") } }
    let macFuse = MacFuseSupport()
    @Published var readOnly = false
    @Published var cacheReadFiles: Bool { didSet { settings.set(cacheReadFiles, forKey: "cacheReadFiles") } }
    @Published var cacheMaxSizeGB: Int { didSet { settings.set(cacheMaxSizeGB, forKey: "cacheMaxSizeGB") } }
    @Published var cacheMaxAgeHours: Int { didSet { settings.set(cacheMaxAgeHours, forKey: "cacheMaxAgeHours") } }
    @Published var cacheDirectoryMinutes: Int { didSet { settings.set(cacheDirectoryMinutes, forKey: "cacheDirectoryMinutes") } }
    @Published var mounts: [MountRecord] = []
    @Published var log = ""
    @Published var errorMessage: String?
    @Published var isRefreshing = false
    @Published var isInstallingRclone = false
    @Published var installationStatus = ""
    @Published var launchesAtLogin: Bool
    @Published var autoMountEnabled: Bool { didSet { settings.set(autoMountEnabled, forKey: "autoMountEnabled"); if !autoMountEnabled { automaticMountTask?.cancel() } } }
    @Published var automaticMounts: Set<String> { didSet { settings.set(Array(automaticMounts), forKey: "automaticMounts") } }
    @Published var loginItemStatus = ""
    @Published var transferLocal = ""
    @Published var transferRemoteFolder = ""
    @Published var transferDirection: TransferDirection = .upload
    @Published var transferStatus = ""
    @Published var isTransferring = false
    @Published var testingRemotes: Set<String> = []
    @Published var startingMountID: UUID?
    @Published var activeUnmountID: UUID?
    @Published var safetyNotice = ""
    @Published var isQuitting = false
    @Published var vaultOperationBusy = false
    @Published var vaultWorkersActive = false
    lazy var vaults = VaultManager(model: self)
    let finderOpener = FinderOpener()

    private var mountControls: [UUID: CommandControl] = [:]
    private var mountExitHandled: Set<UUID> = []
    private var stopping: Set<UUID> = []
    private var blockedPaths: Set<String> = []
    private var knownSystemMounts: [SystemMount] = []
    private var mountBookmarks: [MountBookmark] = []
    private var mountSnapshotTask: Task<[SystemMount]?, Never>?
    private var transferControl: CommandControl?
    private var previewSignature: String?
    private var didScheduleAutomaticMounts = false
    private var automaticMountTask: Task<Void, Never>?
    private var configurationSession = UUID()
    private var configurationControl: CommandControl?
    private var configuringRemoteName = ""
    private var configurationDefaults: [String: String] = [:]
    private var configurationMountFolder: String?
    private var configurationProvider: RcloneProvider?
    private var isUpdatingRemote = false
    private var autoAnswers: Set<String> = []
    private var editorSession = UUID()
    private var editorControl: CommandControl?
    private var testControls: [String: CommandControl] = [:]
    private var installTask: Task<Void, Never>?
    private var supportsLogRotation = false
    private var recoveredUnfinishedOperation = false
    private var sessionBlocked = false

    private let settings: UserDefaults
    private let suppliedHelperPath: String?

    init(startup: Bool = true, defaults: UserDefaults = .standard, helperPath: String? = nil) {
        settings = defaults; suppliedHelperPath = helperPath
        preferredMountFolders = defaults.dictionary(forKey: "preferredMountFolders") as? [String: String] ?? [:]
        method = defaults.string(forKey: "mountMethodPreference").flatMap(MountMethod.init(rawValue:)) ?? .automatic
        launchesAtLogin = SMAppService.mainApp.status == .enabled
        autoMountEnabled = defaults.bool(forKey: "autoMountEnabled")
        automaticMounts = Set(defaults.stringArray(forKey: "automaticMounts") ?? [])
        cacheReadFiles = defaults.object(forKey: "cacheReadFiles") as? Bool ?? true
        cacheDirectoryMinutes = MountCachePolicy.directoryMinutes(defaults.object(forKey: "cacheDirectoryMinutes") as? Int ?? 5)
        cacheMaxSizeGB = max(1, min(defaults.object(forKey: "cacheMaxSizeGB") as? Int ?? 20, 1000))
        cacheMaxAgeHours = max(1, min(defaults.object(forKey: "cacheMaxAgeHours") as? Int ?? 24, 8760))
        rclonePath = defaults.string(forKey: "rclonePath") ?? ""
        if let bundled = Self.bundledRclone(), rclonePath.isEmpty ||
            rclonePath == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CloudMount/bin/rclone").path ||
            rclonePath.hasSuffix("/Contents/Helpers/CloudMountRclone") {
            rclonePath = bundled
            settings.set(bundled, forKey: "rclonePath")
        }
        if let data = defaults.data(forKey: "mountBookmarks"), let saved = try? JSONDecoder().decode([MountBookmark].self, from: data) { mountBookmarks = saved }
        sessionBlocked = defaults.string(forKey: "blockedMountBoot") == SessionSafety.bootID
        recoveredUnfinishedOperation = defaults.bool(forKey: "unfinishedMountOperation")
        if sessionBlocked {
            safetyNotice = L10n.string("上次系統掛載指令未回應。請重新啟動 Mac 後再掛載，避免累積卡住的程序。")
        } else if recoveredUnfinishedOperation {
            safetyNotice = L10n.string("上次掛載未正常完成，本次暫停自動掛載。請先檢查目前掛載，再手動連線。")
        }
        if startup {
            if !rclonePath.isEmpty { refresh() }
            else { Task {
                let detected = await Task.detached(priority: .utility) { Self.detectRclone() }.value
                if rclonePath.isEmpty { rclonePath = detected; if !detected.isEmpty { refresh() } }
            } }
        }
    }
    var hasRclone: Bool { !rclonePath.isEmpty }
    var canStartMount: Bool { hasRclone && !version.isEmpty && !vaultOperationBusy && !isConfiguringRemote && !configurationWriterActive && startingMountID == nil && activeUnmountID == nil && !sessionBlocked && !isQuitting && !isInstallingRclone && !macFuse.preparingInstaller && !macFuse.installationPending && !mounts.contains(where: { $0.phase == .failed || $0.phase == .blocked }) }
    var canChangeRclone: Bool { !vaultWorkersActive && !vaultOperationBusy && !isQuitting && !isRefreshing && !isLoadingProviders && mounts.isEmpty && !isTransferring && !isConfiguringRemote && !configurationWriterActive && testingRemotes.isEmpty && !isInstallingRclone && !macFuse.preparingInstaller && !macFuse.installationPending }
    var helperPath: String {
        if let suppliedHelperPath { return suppliedHelperPath }
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        if executable.deletingLastPathComponent().lastPathComponent == "MacOS" {
            return executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers/CloudMountHelper").path
        }
        return executable.deletingLastPathComponent().appendingPathComponent("CloudMountHelper").path
    }
    nonisolated static func detectRclone() -> String {
        if let bundled = bundledRclone() { return bundled }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in [home + "/Library/Application Support/CloudMount/bin/rclone", home + "/.local/bin/rclone", "/opt/homebrew/bin/rclone", "/usr/local/bin/rclone", "/opt/local/bin/rclone"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return ""
    }
    nonisolated static func bundledRclone() -> String? {
        guard let executable = Bundle.main.executableURL,
              executable.deletingLastPathComponent().lastPathComponent == "MacOS" else { return nil }
        let path = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers/CloudMountRclone").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
    private func command(_ arguments: [String], timeout: TimeInterval = 20, control: CommandControl = CommandControl(), outputLimit: Int = 8_388_608) async -> CommandResult {
        await CommandRunner.execute(rclonePath, arguments: ["--ask-password=false"] + arguments, timeout: timeout, control: control, outputLimit: outputLimit)
    }
    private func helper(_ arguments: [String], timeout: TimeInterval = 5, control: CommandControl = CommandControl()) async -> CommandResult {
        guard !sessionBlocked else { return CommandResult(status: -2, stdout: "", stderr: safetyNotice, stillRunning: false) }
        let result = await CommandRunner.execute(helperPath, arguments: arguments, timeout: timeout, control: control)
        if result.timedOut || result.stillRunning { blockMountOperations() }
        return result
    }
    func blockMountOperations() {
        sessionBlocked = true
        settings.set(SessionSafety.bootID, forKey: "blockedMountBoot")
        safetyNotice = L10n.string("系統掛載指令未回應，已停止後續掛載與卸載。請重新啟動 Mac 後再試。")
    }
    private func updateRecoveryMarker() {
        settings.set(startingMountID != nil || activeUnmountID != nil || !blockedPaths.isEmpty || mounts.contains(where: { $0.phase == .failed || $0.phase == .blocked }), forKey: "unfinishedMountOperation")
    }
    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            let state = SMAppService.mainApp.status
            launchesAtLogin = state == .enabled || state == .requiresApproval
            loginItemStatus = L10n.string(state == .requiresApproval ? "已提出登入啟動要求。請到「系統設定 → 一般 → 登入項目」允許 CloudMount。" : launchesAtLogin ? "CloudMount 會在登入 macOS 時啟動。" : "已關閉登入時啟動。")
        } catch { loginItemStatus = L10n.error(error) }
    }
    func setAutomaticMount(_ remote: String, enabled: Bool) {
        if enabled { automaticMounts.insert(remote) } else { automaticMounts.remove(remote) }
    }
    func chooseRclone() {
        guard canChangeRclone else { return }
        let panel = NSOpenPanel()
        panel.message = L10n.string("選擇 rclone 執行檔")
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            rclonePath = url.path; version = ""; providers = []; refresh()
        }
    }
    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.message = L10n.string("選擇空資料夾作為掛載位置")
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { destination = url.path }
    }
    func chooseTransferLocal() {
        let panel = NSOpenPanel()
        panel.message = L10n.string("選擇要複製或同步的本機資料夾")
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { transferLocal = url.path }
    }
    func refresh() {
        guard hasRclone, !isRefreshing, !isQuitting else { return }
        isRefreshing = true
        Task {
            defer { isRefreshing = false }
            await macFuse.refresh(helperPath: helperPath)
            let versionResult = await command(["version"], timeout: 10)
            guard versionResult.succeeded else {
                version = ""; errorMessage = friendlyError(versionResult.output, fallback: "無法啟動 rclone。請重新選擇或安裝 rclone。")
                return
            }
            version = versionResult.stdout.components(separatedBy: .newlines).first ?? ""
            let flags = await command(["help", "flags"], timeout: 10)
            supportsLogRotation = flags.succeeded && flags.stdout.contains("--log-file-max-size")
            let result = await command(["listremotes"], timeout: 10)
            guard result.succeeded else { errorMessage = friendlyError(result.output, fallback: "無法讀取 rclone 設定："); return }
            remotes = RcloneHelpers.parseRemotes(result.stdout)
            if !remotes.contains(selectedRemote) { selectedRemote = remotes.first ?? "" }
            await readProviders()
            // The mount form needs backend types before showing S3's bucket
            // controls, even when the user never opens a vault setup sheet.
            await vaults.prepareRemotes()
            guard await scanMountedVolumes() != nil, !isQuitting else { return }
            await vaults.reconcileAndStart(allowAutomatic: autoMountEnabled && !recoveredUnfinishedOperation && !sessionBlocked)
            updateRecoveryMarker()
            scheduleAutomaticMountsIfNeeded()
        }
    }
    func loadProviders() { Task { await readProviders() } }
    private func readProviders() async {
        guard providers.isEmpty, !isLoadingProviders, hasRclone else { return }
        isLoadingProviders = true
        defer { isLoadingProviders = false }
        let result = await command(["config", "providers"], timeout: 15)
        guard result.succeeded, let parsed = try? JSONDecoder().decode([RcloneProvider].self, from: Data(result.stdout.utf8)) else {
            configurationError = friendlyError(result.output, fallback: "讀取 rclone 支援的雲端類型失敗。")
            return
        }
        providers = parsed.sorted { $0.description.localizedStandardCompare($1.description) == .orderedAscending }
    }
    func refreshMountedVolumes() { Task { _ = await scanMountedVolumes() } }
    @discardableResult
    func scanMountedVolumes() async -> [SystemMount]? {
        guard !sessionBlocked else { return nil }
        if let existing = mountSnapshotTask { return await existing.value }
        let path = helperPath
        let task = Task<[SystemMount]?, Never> {
            let result = await CommandRunner.execute(path, arguments: ["snapshot"], timeout: 5)
            if result.timedOut || result.stillRunning { self.blockMountOperations() }
            guard result.succeeded else { return nil }
            return try? JSONDecoder().decode([SystemMount].self, from: Data(result.stdout.utf8))
        }
        mountSnapshotTask = task
        let snapshot = await task.value
        mountSnapshotTask = nil
        guard let snapshot else {
            safetyNotice = L10n.string("無法確認系統掛載狀態，已暫停新掛載。請確認 app 安裝完整，或重新啟動 Mac。")
            return nil
        }
        knownSystemMounts = snapshot
        let paths = Set(snapshot.map(\.destination))
        // An in-progress mount is not stale just because it is not in the kernel
        // table yet. Never terminate it from a refresh operation.
        mounts.removeAll { record in
            !record.retainedAfterScan(paths: paths, hasProcess: mountControls[record.id] != nil) && !blockedPaths.contains(record.destination)
        }
        let detected = RcloneHelpers.identifyMountedVolumes(snapshot, remotes: remotes,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        for item in detected {
            let saved = mountBookmarks.first { RcloneHelpers.pathsEqual($0.destination, item.destination) }
            guard let remote = item.remote ?? saved?.remote else { continue }
            if let index = mounts.firstIndex(where: { $0.destination == item.destination }) {
                if mounts[index].phase == .connecting { mounts[index].phase = .mounted }
            } else {
                mounts.append(MountRecord(id: UUID(), remote: remote, folder: item.fileSystem == "nfs" ? (saved?.folder ?? item.folder) : item.folder, destination: item.destination,
                    phase: .mounted, problem: remotes.contains(remote) ? nil : L10n.string("遠端設定不存在，請重新新增"), owned: false))
            }
        }
        return snapshot
    }
    func beginRemoteEditor() {
        cancelRemoteConfiguration()
        editorSession = UUID(); configurationError = nil; configurationStatus = ""; remoteEditorStatus = ""
    }
    func cancelRemoteConfiguration() {
        configurationControl?.cancel(); configurationControl = nil
        editorControl?.cancel(); editorControl = nil
        configurationSession = UUID(); editorSession = UUID()
        isConfiguringRemote = false; configurationBusy = false
        configurationQuestion = nil; configurationDefaults = [:]; configurationProvider = nil
        configurationStatus = ""; remoteEditorStatus = ""
    }
    func createRemote(name: String, provider: RcloneProvider, values: [String: String], mountFolder: String? = nil) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RcloneHelpers.isValidRemoteName(name) else { configurationError = L10n.string("請輸入有效的遠端名稱。"); return }
        guard !remotes.contains(name) else { configurationError = L10n.string("已有同名遠端，請換一個名稱。"); return }
        startConfiguration(name: name, provider: provider, values: values, updating: false, mountFolder: mountFolder)
    }
    func updateRemote(name: String, provider: RcloneProvider, values: [String: String], clearing: Set<String> = [], mountFolder: String? = nil) {
        guard !vaults.references(name), !vaultOperationBusy, !mounts.contains(where: { $0.remote == name }), !testingRemotes.contains(name), !isTransferring else {
            configurationError = String(format: L10n.string("請先卸載 %@，再修改設定。"), name); return
        }
        startConfiguration(name: name, provider: provider, values: values, updating: true, clearing: clearing, mountFolder: mountFolder)
    }
    private func startConfiguration(name: String, provider: RcloneProvider, values: [String: String], updating: Bool, clearing: Set<String> = [], mountFolder: String? = nil) {
        guard !vaultOperationBusy, !configurationWriterActive, !configurationBusy, startingMountID == nil, activeUnmountID == nil, !isQuitting, !isInstallingRclone else { return }
        if provider.prefix == "s3", let error = RcloneHelpers.s3BucketError(RcloneHelpers.splitS3MountPath(mountFolder ?? "").bucket) {
            configurationError = error; return
        }
        let policy = ProviderFormPolicy(provider: provider, values: values, editing: updating)
        if let error = policy.validationError { configurationError = error; return }
        configurationSession = UUID()
        configurationMountFolder = mountFolder
        configuringRemoteName = name; configurationProvider = provider
        configurationDefaults = RcloneHelpers.normalizedConfigurationValues(provider: provider.prefix, values: policy.submittedValues)
        if updating { for key in clearing where provider.options.contains(where: { $0.name == key }) { configurationDefaults[key] = "" } }
        isUpdatingRemote = updating; isConfiguringRemote = true; autoAnswers = []
        configurationQuestion = nil; configurationError = nil
        configurationStatus = String(format: L10n.string(updating ? "正在更新 %@…" : "正在建立 %@…"), name)
        runConfigurationCommand(RcloneHelpers.configurationStartArguments(remote: name, provider: provider.prefix,
            updating: updating, values: configurationDefaults))
    }
    func answerConfigurationQuestion(_ answer: String) {
        guard !configurationBusy, let question = configurationQuestion, question.accepts(answer: answer) else { return }
        let effective = answer.isEmpty ? question.option.defaultValue ?? "" : answer
        configurationQuestion = nil
        runConfigurationCommand(RcloneHelpers.configurationContinuationArguments(remote: configuringRemoteName,
            state: question.state, answer: effective, defaults: configurationDefaults))
    }
    private func runConfigurationCommand(_ initialArguments: [String]) {
        let session = configurationSession
        let control = CommandControl(); configurationControl = control
        configurationBusy = true
        Task {
            var arguments = initialArguments
            if arguments.count > 2 && arguments[1] == "create" {
                configurationWriterActive = true
                let listed = await command(["listremotes"], timeout: 10, control: control)
                configurationWriterActive = false
                guard configurationSession == session, !control.isCancelled, !isQuitting else { return }
                if !listed.succeeded || RcloneHelpers.parseRemotes(listed.stdout).contains(configuringRemoteName) {
                    configurationBusy = false; isConfiguringRemote = false
                    configurationError = L10n.string("此名稱已有遠端設定。請關閉此視窗，選擇該遠端並使用編輯功能繼續。")
                    refresh(); return
                }
            }
            for _ in 0..<32 {
                configurationWriterActive = true
                let result = await command(arguments, timeout: 180, control: control)
                configurationWriterActive = false
                guard configurationSession == session, !isQuitting else { if !isQuitting { refresh() }; return }
                guard result.succeeded else {
                    configurationBusy = false; isConfiguringRemote = false
                    configurationError = friendlyError(result.output, fallback: result.timedOut ? "設定等候逾時。請重試或取消，稍後繼續設定。" : "建立遠端失敗。")
                    refresh()
                    return
                }
                guard let data = result.stdout.data(using: .utf8),
                      let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    configurationBusy = false; isConfiguringRemote = false
                    configurationError = L10n.string("rclone 回傳的設定資料無法辨識，請更新 rclone 後再試。")
                    return
                }
                let state = response["State"] as? String ?? ""
                if state.isEmpty {
                    configurationBusy = false; isConfiguringRemote = false
                    configurationDefaults = [:]; configurationQuestion = nil; configurationControl = nil
                    configurationStatus = L10n.string(isUpdatingRemote ? "遠端已更新。" : "遠端已建立。")
                    appendLog(configurationStatus)
                    selectedRemote = configuringRemoteName
                    if let configurationMountFolder { setPreferredMountFolder(configurationMountFolder, for: configuringRemoteName) }
                    refresh()
                    return
                }
                guard let question = try? JSONDecoder().decode(RcloneConfigQuestion.self, from: data) else {
                    configurationBusy = false; isConfiguringRemote = false
                    configurationError = L10n.string("rclone 回傳的設定資料無法辨識，請更新 rclone 後再試。")
                    return
                }
                var automaticAnswer: String?
                if question.error.isEmpty {
                    automaticAnswer = configurationDefaults[question.option.name]
                    if automaticAnswer == nil, question.option.name == "config_is_local" { automaticAnswer = "true" }
                    if automaticAnswer == nil, !question.option.required, !question.option.isSecret,
                       configurationProvider?.options.contains(where: { $0.name == question.option.name }) == true,
                       let value = question.option.defaultValue, !value.isEmpty { automaticAnswer = value }
                }
                if let answer = automaticAnswer {
                    let key = question.state + "|" + question.option.name
                    if autoAnswers.insert(key).inserted {
                        arguments = RcloneHelpers.configurationContinuationArguments(remote: configuringRemoteName,
                            state: question.state, answer: answer, defaults: configurationDefaults)
                        continue
                    }
                }
                configurationQuestion = question; configurationBusy = false
                configurationStatus = String(format: L10n.string("請完成 %@ 設定。"),
                    L10n.optionLabel(providerPrefix: configurationProvider?.prefix ?? "", optionName: question.option.name))
                return
            }
            configurationBusy = false; isConfiguringRemote = false
            configurationError = L10n.string("設定步驟反覆重複，已停止。請檢查資料後重試。")
        }
    }
    func loadRemoteConfiguration(_ remote: String, completion: @escaping (String, [String: String]) -> Void) {
        remoteEditorStatus = L10n.string("正在讀取遠端設定…")
        let session = editorSession
        let control = CommandControl(); editorControl = control
        Task {
            // The decrypted output stays in memory and is never logged. Only
            // non-credential fields are passed to the form (host, user, email).
            let result = await command(["config", "show", remote], timeout: 10, control: control)
            guard editorSession == session else { return }
            remoteEditorStatus = ""
            guard result.succeeded, let parsed = Self.parseRedactedRemote(remote, output: result.stdout) else {
                configurationError = friendlyError(result.stderr, fallback: "無法讀取遠端設定。"); return
            }
            let options = providers.first { $0.prefix == parsed.type }?.options ?? []
            let allowed = Set(options.filter { !$0.isSecret }.map(\.name))
            completion(parsed.type, parsed.values.filter { allowed.contains($0.key) })
        }
    }
    nonisolated static func parseRedactedRemote(_ remote: String, output: String) -> (type: String, values: [String: String])? {
        var active = false, values: [String: String] = [:]
        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") && line.hasSuffix("]") { active = String(line.dropFirst().dropLast()) == remote; continue }
            guard active, let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if !ProviderFormPolicy.isRedacted(value) { values[key] = value }
        }
        guard let type = values.removeValue(forKey: "type") else { return nil }
        return (type, values)
    }
    func deleteRemote(_ remote: String) {
        guard !vaults.references(remote), !vaultOperationBusy, !mounts.contains(where: { $0.remote == remote }), !isConfiguringRemote, !configurationWriterActive, !isTransferring, !testingRemotes.contains(remote), !isQuitting else {
            errorMessage = String(format: L10n.string("請先卸載 %@，再刪除設定。"), remote); return
        }
        // Reserve the configuration writer before yielding to the command.
        isConfiguringRemote = true; configurationWriterActive = true
        Task {
            defer { isConfiguringRemote = false; configurationWriterActive = false }
            let result = await command(["config", "delete", remote], timeout: 10)
            guard result.succeeded else { errorMessage = friendlyError(result.output, fallback: "刪除遠端失敗："); return }
            automaticMounts.remove(remote); previewSignature = nil
            preferredMountFolders.removeValue(forKey: remote)
            settings.set(preferredMountFolders, forKey: "preferredMountFolders")
            appendLog(L10n.string("遠端設定已刪除。")); refresh()
        }
    }
    func testRemote(_ remote: String) {
        guard testingRemotes.count < 2, !testingRemotes.contains(remote), !isQuitting, !isConfiguringRemote else { return }
        let control = CommandControl(); testControls[remote] = control; testingRemotes.insert(remote)
        let testFolder = remote == selectedRemote ? folder : preferredMountFolder(for: remote)
        Task {
            defer { testingRemotes.remove(remote); testControls[remote] = nil }
            let result = await connectionTest(remote: remote, folder: testFolder, control: control)
            guard !isQuitting else { return }
            if result.succeeded {
                appendLog(String(format: L10n.string("連線測試成功：%@"), remote))
                // A successful API test does not mean a filesystem is mounted.
                for index in mounts.indices where mounts[index].remote == remote { mounts[index].problem = nil }
            } else if !result.cancelled {
                errorMessage = friendlyError(result.output, fallback: "連線測試失敗")
                appendLog(errorMessage ?? "")
            }
        }
    }
    private func connectionTest(remote: String, folder: String, control: CommandControl) async -> CommandResult {
        return await command(["lsd", RcloneHelpers.remotePath(name: remote, folder: folder), "--max-depth", "1",
            "--contimeout", "10s", "--timeout", "15s", "--retries", "1", "--low-level-retries", "1"],
            timeout: 25, control: control, outputLimit: 262_144)
    }
    private func mountRequest(remote: String? = nil) -> MountRequest {
        let name = remote ?? selectedRemote
        let proposed = remote == nil ? destination.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let path = proposed.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("CloudMounts", isDirectory: true)
            .appendingPathComponent(RcloneHelpers.safeDirectoryName(name), isDirectory: true).path : (proposed as NSString).expandingTildeInPath
        return MountRequest(remote: name, folder: remote == nil ? RcloneHelpers.normalizedFolder(folder) : preferredMountFolder(for: name),
            destination: RcloneHelpers.normalizedMountPath(path), method: method,
            readOnly: remote == nil ? readOnly : false, cacheReadFiles: cacheReadFiles,
            cacheMaxSizeGB: cacheMaxSizeGB, cacheMaxAgeHours: cacheMaxAgeHours, cacheDirectoryMinutes: cacheDirectoryMinutes)
    }
    func mount(openWhenReady: Bool = true) {
        guard !selectedRemote.isEmpty else { return }
        if selectedRemoteIsS3, let error = RcloneHelpers.s3BucketError(mountBucket) { errorMessage = error; return }
        if selectedRemoteIsS3, let error = RcloneHelpers.s3PrefixError(bucket: mountBucket, prefix: mountSubfolder) { errorMessage = error; return }
        setPreferredMountFolder(folder, for: selectedRemote)
        let request = mountRequest()
        Task { _ = await performMount(request, openWhenReady: openWhenReady) }
    }
    private func performMount(_ request: MountRequest, openWhenReady: Bool) async -> Bool {
        guard canStartMount, remotes.contains(request.remote) else { return false }
        // This also covers startup mounts, so a missing bucket never silently
        // mounts the account root or requires ListAllMyBuckets permission.
        if vaults.remoteTypes[request.remote] == "s3",
           let error = RcloneHelpers.s3BucketError(RcloneHelpers.splitS3MountPath(request.folder).bucket) {
            errorMessage = error; return false
        }
        if let existing = mounts.first(where: { RcloneHelpers.pathsEqual($0.destination, request.destination) ||
            ($0.remote == request.remote && $0.folder == request.folder) }) {
            guard existing.remote == request.remote, existing.folder == request.folder else {
                errorMessage = L10n.string("這個位置已掛載其他儲存桶或資料夾。請先卸載，再切換掛載內容。")
                return false
            }
            if openWhenReady && existing.phase.allowsOpening { openInFinder(existing) }
            return existing.phase.allowsOpening
        }
        guard !blockedPaths.contains(request.destination) else { return false }
        // Reserve before awaiting detection; a second click must not start a
        // second process while the filesystem driver is being checked.
        let id = UUID(), control = CommandControl()
        startingMountID = id; mountControls[id] = control; updateRecoveryMarker()
        mounts.append(MountRecord(id: id, remote: request.remote, folder: request.folder,
            destination: request.destination, phase: .preparing, owned: true))
        await macFuse.refresh(helperPath: helperPath)
        guard let actualMethod = macFuse.resolved(request.method, destination: request.destination, readOnly: request.readOnly) else {
            macFuse.showSetup = true
            errorMessage = L10n.string("請先安裝或更新 macFUSE，也可選擇免安裝的 NFS。")
            finishUnstartedMount(id); return false
        }
        guard await scanMountedVolumes() != nil, !isQuitting, !control.isCancelled, !Task.isCancelled else {
            finishUnstartedMount(id); return false
        }
        let prepared = await helper(["prepare", request.destination], control: control)
        guard prepared.succeeded, let preparation = try? JSONDecoder().decode(MountPreparation.self, from: Data(prepared.stdout.utf8)) else {
            if !control.isCancelled { errorMessage = helperError(prepared.output) }
            finishUnstartedMount(id); return false
        }
        let tested = await connectionTest(remote: request.remote, folder: request.folder, control: control)
        guard tested.succeeded, !control.isCancelled, !isQuitting, !Task.isCancelled else {
            if !tested.cancelled && !isQuitting { errorMessage = friendlyError(tested.output, fallback: "連線測試失敗") }
            finishUnstartedMount(id); return false
        }
        // Re-check after the network request; another application could have
        // mounted the directory while authentication was in progress.
        let rechecked = await helper(["prepare", preparation.path], control: control)
        guard rechecked.succeeded, let current = try? JSONDecoder().decode(MountPreparation.self, from: Data(rechecked.stdout.utf8)),
              !control.isCancelled, !isQuitting, !Task.isCancelled else {
            if !control.isCancelled && !isQuitting { errorMessage = helperError(rechecked.output) }
            finishUnstartedMount(id); return false
        }
        if let index = mounts.firstIndex(where: { $0.id == id }) { mounts[index].phase = .connecting }
        let logPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/CloudMount/" + id.uuidString + ".log").path
        var arguments = RcloneHelpers.mountArguments(method: actualMethod, remote: request.remote, folder: request.folder,
            destination: current.path, readOnly: request.readOnly, cacheReadFiles: request.cacheReadFiles,
            cacheMaxSizeGB: request.cacheMaxSizeGB, cacheMaxAgeHours: request.cacheMaxAgeHours,
            cacheDirectoryMinutes: request.cacheDirectoryMinutes, allowNonEmpty: current.allowNonEmpty)
            + ["--ask-password=false", "--contimeout", "10s", "--timeout", "30s", "--low-level-retries", "2", "--log-file", logPath]
        if supportsLogRotation { arguments += ["--log-file-max-size", "5M", "--log-file-max-backups", "1"] }
        mountBookmarks.removeAll { RcloneHelpers.pathsEqual($0.destination, current.path) }
        mountBookmarks.append(MountBookmark(remote: request.remote, folder: request.folder, destination: current.path))
        if let data = try? JSONEncoder().encode(mountBookmarks) { settings.set(data, forKey: "mountBookmarks") }
        let executable = rclonePath
        appendLog(String(format: L10n.string("正在掛載 %@"), request.remote))
        Task { [self] in
            let result = await CommandRunner.execute(executable, arguments: arguments, timeout: nil, control: control,
                outputLimit: 16_384, forceStop: false, logFile: logPath, environment: ["CGOFUSE_LIBFUSE_PATH": "/usr/local/lib/libfuse.2.dylib"], onOutput: { [weak self] text in
                    Task { @MainActor in
                        guard let self else { return }
                        self.appendLog(text)
                        if let status = RcloneHelpers.remoteErrorStatus(in: text), let index = self.mounts.firstIndex(where: { $0.id == id }) {
                            self.mounts[index].problem = status
                        }
                    }
                })
            await mountProcessEnded(id: id, result: result)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while ProcessInfo.processInfo.systemUptime < deadline, !control.isCancelled, !isQuitting, !Task.isCancelled {
            guard let snapshot = await scanMountedVolumes() else { break }
            guard !mountExitHandled.contains(id) else { return false }
            if snapshot.contains(where: { RcloneHelpers.pathsEqual($0.destination, current.path) }) {
                if let index = mounts.firstIndex(where: { $0.id == id }) { mounts[index].phase = .mounted }
                if startingMountID == id { startingMountID = nil }
                updateRecoveryMarker()
                if openWhenReady, let record = mounts.first(where: { $0.id == id }) { openInFinder(record) }
                return true
            }
            try? await Task.sleep(nanoseconds: 750_000_000)
        }
        guard !mountExitHandled.contains(id) else { return false }
        if !isQuitting && !control.isCancelled {
            errorMessage = L10n.string("掛載未在預期時間內完成，已停止這次連線。請查看紀錄後再試。")
            if let index = mounts.firstIndex(where: { $0.id == id }) { mounts[index].phase = .failed }
        }
        stopping.insert(id); control.cancel()
        // The reservation remains until the child has stopped and a fresh
        // snapshot proves that the mount point has been released.
        return false
    }
    private func finishUnstartedMount(_ id: UUID) {
        mountControls[id] = nil
        mounts.removeAll { $0.id == id }
        if startingMountID == id { startingMountID = nil }
        updateRecoveryMarker()
    }
    private func mountProcessEnded(id: UUID, result: CommandResult) async {
        mountExitHandled.insert(id)
        let expected = stopping.remove(id) != nil || activeUnmountID == id || result.cancelled || isQuitting
        let record = mounts.first(where: { $0.id == id })
        let snapshot = await scanMountedVolumes()
        let stillMounted = record.map { record in snapshot?.contains { RcloneHelpers.pathsEqual($0.destination, record.destination) } ?? true } ?? false
        if result.stillRunning || snapshot == nil {
            blockMountOperations()
            if let record { blockedPaths.insert(record.destination) }
            if let index = mounts.firstIndex(where: { $0.id == id }) { mounts[index].phase = .blocked }
        } else {
            mountControls[id] = nil
            if stillMounted {
                if let index = mounts.firstIndex(where: { $0.id == id }) { mounts[index].phase = .failed }
            } else { mounts.removeAll { $0.id == id } }
            if startingMountID == id { startingMountID = nil }
        }
        updateRecoveryMarker()
        if !expected, let record {
            errorMessage = friendlyError(result.output, fallback: "掛載程序已結束。請檢查連線後重試。")
            appendLog(String(format: L10n.string("掛載失敗：%@"), record.remote))
        }
    }
    func canOpen(_ record: MountRecord) -> Bool { record.phase.allowsOpening && record.problem == nil && !sessionBlocked }
    func canUnmount(_ record: MountRecord) -> Bool {
        !vaultOperationBusy && activeUnmountID == nil && (startingMountID == nil || startingMountID == record.id) && !sessionBlocked && !blockedPaths.contains(record.destination) && record.phase != .unmounting && !isQuitting
    }
    func unmount(_ record: MountRecord) {
        guard canUnmount(record) else { return }
        Task { _ = await performUnmount(record, timeout: 8) }
    }
    private func performUnmount(_ record: MountRecord, timeout: TimeInterval) async -> Bool {
        guard activeUnmountID == nil, !sessionBlocked, !blockedPaths.contains(record.destination) else { return false }
        activeUnmountID = record.id; updateRecoveryMarker()
        defer { if activeUnmountID == record.id { activeUnmountID = nil }; updateRecoveryMarker() }
        let previousPhase = mounts.first(where: { $0.id == record.id })?.phase ?? record.phase
        if let index = mounts.firstIndex(where: { $0.id == record.id }) { mounts[index].phase = .unmounting }
        if previousPhase == .preparing || previousPhase == .connecting {
            stopping.insert(record.id)
            mountControls[record.id]?.cancel()
        }
        let outcome = await UnmountOperation.run(path: record.destination, timeout: timeout,
            snapshot: { await self.scanMountedVolumes() })
        switch outcome {
        case .unmounted:
            if mountControls[record.id] != nil { stopping.insert(record.id) }
            mountControls[record.id]?.cancel()
            // Preparing commands share this cancellation token, so a cancelled
            // preflight cannot subsequently launch rclone mount.
            if mountControls[record.id] == nil { mounts.removeAll { $0.id == record.id } }
            else if previousPhase != .preparing && previousPhase != .connecting { mounts.removeAll { $0.id == record.id } }
            appendLog(String(format: L10n.string("已卸載 %@"), record.remote))
            return true
        case .unsafe:
            blockedPaths.insert(record.destination); blockMountOperations()
            if let index = mounts.firstIndex(where: { $0.id == record.id }) { mounts[index].phase = .blocked }
            if !isQuitting { errorMessage = safetyNotice }
            return false
        case .unverified:
            if let index = mounts.firstIndex(where: { $0.id == record.id }) {
                mounts[index].phase = sessionBlocked ? .blocked : MountPhase.afterUnmountFailure(
                    previous: previousPhase, current: mounts[index].phase, busy: false)
            }
            if !isQuitting { errorMessage = sessionBlocked ? safetyNotice : L10n.string("無法確認卸載狀態，請稍後重新整理。") }
            return false
        case .stillMounted(let busy, let details):
            if let index = mounts.firstIndex(where: { $0.id == record.id }) {
                mounts[index].phase = MountPhase.afterUnmountFailure(previous: previousPhase, current: mounts[index].phase, busy: busy)
            }
            let message = L10n.string(busy
                ? "空間仍保持掛載，目前正在被使用。請先儲存並關閉其中的檔案、Finder 預覽或正在存取此空間的程式，再按「重試卸載」。"
                : "未能卸載，空間仍保持掛載。請查看執行紀錄後再試。")
            appendLog(message + "\n" + details)
            if !isQuitting { errorMessage = message }
            return false
        }
    }
    func openInFinder(_ record: MountRecord) {
        guard canOpen(record) else { return }
        Task { await finderOpener.open(path: record.destination, helper: helperPath) }
    }
    func stopAllForQuit(completion: @escaping (Bool) -> Void) {
        guard !isQuitting else { return }
        isQuitting = true; automaticMountTask?.cancel(); cancelRemoteConfiguration(); installTask?.cancel()
        testControls.values.forEach { $0.cancel() }; transferControl?.cancel()
        Task {
            guard await vaults.lockAllForQuit() else { isQuitting = false; completion(false); return }
            let deadline = ProcessInfo.processInfo.systemUptime + 9
            while activeUnmountID != nil && ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            // If quitting outlasts the current operation's bounded wait, its
            // worker may no longer be supervised once this app exits. Preserve
            // the safety lock across launches instead of allowing more workers.
            if activeUnmountID != nil { blockMountOperations() }
            let owned = mounts.filter(\.owned)
            for record in owned {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 1, !sessionBlocked else { break }
                // Never launch a second unmount for a command already in flight.
                _ = await performUnmount(record, timeout: min(2, remaining))
            }
            // Established mounts whose unmount failed are left to rclone. Do
            // not kill a filesystem process that may still hold pending writes.
            for record in mounts where record.phase == .preparing || record.phase == .connecting {
                mountControls[record.id]?.cancel()
            }
            updateRecoveryMarker()
            completion(true)
        }
    }
    private func scheduleAutomaticMountsIfNeeded() {
        guard !didScheduleAutomaticMounts else { return }
        didScheduleAutomaticMounts = true
        let selected = AutoMountPolicy.requestedRemotes(enabled: autoMountEnabled, selected: automaticMounts,
            available: remotes, recovering: recoveredUnfinishedOperation || sessionBlocked, quitting: isQuitting)
        guard !selected.isEmpty else { return }
        automaticMountTask = Task {
            for remote in selected {
                guard autoMountEnabled, automaticMounts.contains(remote), !isQuitting, !sessionBlocked else { break }
                if mounts.contains(where: { $0.remote == remote }) { continue }
                guard await performMount(mountRequest(remote: remote), openWhenReady: false) else { break }
            }
        }
    }
    private var previewDate: Date?
    private var currentTransferSignature: String {
        [selectedRemote, RcloneHelpers.normalizedFolder(transferRemoteFolder),
         (transferLocal as NSString).expandingTildeInPath, transferDirection.rawValue].joined(separator: "\u{0}")
    }
    var syncPreviewReady: Bool { previewSignature == currentTransferSignature && (previewDate?.timeIntervalSinceNow ?? -.infinity) > -1800 }
    func previewSync() { runTransfer(command: "sync", dryRun: true) }
    func copyFiles() { runTransfer(command: "copy", dryRun: false) }
    func executeSync() {
        guard syncPreviewReady else { errorMessage = L10n.string("請先預覽目前的同步設定。"); return }
        runTransfer(command: "sync", dryRun: false)
    }
    func cancelTransfer() { transferControl?.cancel(); transferStatus = L10n.string("正在取消…") }
    private func runTransfer(command operation: String, dryRun: Bool) {
        guard hasRclone, remotes.contains(selectedRemote), !vaultOperationBusy, !isTransferring, !isQuitting, !isConfiguringRemote, !isInstallingRclone else { return }
        let local = (transferLocal.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard local.hasPrefix("/") else { errorMessage = L10n.string("請選擇本機資料夾。"); return }
        if operation == "sync", transferDirection == .download,
           ["/", FileManager.default.homeDirectoryForCurrentUser.path].contains(RcloneHelpers.normalizedMountPath(local)) {
            errorMessage = L10n.string("請選擇專用資料夾接收同步，不能使用磁碟根目錄或整個使用者資料夾。"); return
        }
        let remote = selectedRemote, remoteFolder = RcloneHelpers.normalizedFolder(transferRemoteFolder), direction = transferDirection
        if vaults.transferTouchesVault(remote: remote, folder: remoteFolder, deletingAncestor: operation == "sync" && direction == .upload) {
            errorMessage = L10n.string("此範圍包含加密保險箱。請從解鎖後的 Finder 保險箱操作，或選擇另一個資料夾。"); return
        }
        let vaultExclusions = vaults.copyExclusions(remote: remote, folder: remoteFolder)
        let signature = currentTransferSignature
        let control = CommandControl(); transferControl = control
        isTransferring = true; previewSignature = nil; previewDate = nil
        transferStatus = L10n.string("正在檢查連線…")
        Task { [self] in
            let directory = await helper(["directory", local], control: control)
            guard directory.succeeded, !control.isCancelled, !isQuitting, !Task.isCancelled else {
                isTransferring = false; transferControl = nil
                if !control.isCancelled { errorMessage = L10n.string("無法開啟本機資料夾，請確認位置與權限。") }
                return
            }
            guard let snapshot = await scanMountedVolumes(), !snapshot.contains(where: {
                $0.source.hasPrefix(remote + ":") && RcloneHelpers.pathContains($0.destination, local)
            }) else {
                isTransferring = false; transferControl = nil
                errorMessage = L10n.string("本機資料夾不能是同一遠端的掛載點，請選擇另一個資料夾。"); return
            }
            let arguments = RcloneHelpers.transferArguments(command: operation, remote: remote, remoteFolder: remoteFolder,
                local: local, direction: direction, dryRun: dryRun) + ["--ask-password=false", "--contimeout", "15s", "--timeout", "60s", "--retries", "2", "--low-level-retries", "2"]
                + vaultExclusions
            transferStatus = L10n.string(dryRun ? "正在預覽同步…" : "正在傳輸…")
            let result = await CommandRunner.execute(rclonePath, arguments: arguments, timeout: nil, control: control,
                outputLimit: 32_768, forceStop: false, onOutput: { [weak self] text in
                    Task { @MainActor in self?.appendLog(text) }
                })
            isTransferring = result.stillRunning
            if !result.stillRunning { transferControl = nil }
            if result.cancelled {
                transferStatus = L10n.string(result.stillRunning ? "程序尚未停止，請勿重複開始工作。" : "工作已取消")
            } else if result.succeeded {
                if dryRun { previewSignature = signature; previewDate = Date() }
                transferStatus = L10n.string(dryRun ? "預覽完成，可確認同步" : "傳輸完成")
            } else {
                transferStatus = L10n.string("傳輸未完成，請查看執行紀錄。")
                errorMessage = friendlyError(result.output, fallback: "傳輸未完成，請查看執行紀錄。")
            }
            appendLog(transferStatus)
        }
    }
    private func appendLog(_ message: String) {
        let safe = RcloneHelpers.redactLog(message).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safe.isEmpty else { return }
        log += "[\(Date().formatted(date: .omitted, time: .standard))] \(safe.suffix(16_384))\n"
        if log.count > 40_000 { log = String(log.suffix(30_000)) }
    }
    private func friendlyError(_ output: String, fallback: String) -> String {
        let text = output.lowercased()
        if text.contains("config password") || text.contains("encrypted configuration") {
            return L10n.string("rclone 設定檔已加密，無法在背景詢問密碼。請先使用未加密的設定，或設定 rclone 的密碼來源後再試。")
        }
        if text.contains("operation error s3:"), text.contains("no such host") {
            return L10n.string("S3 網址無法解析。請確認端點網址；自架服務請在編輯遠端選擇「其他 S3 相容服務」或 MinIO，避免把儲存桶名稱加到網域前面。")
        }
        if let error = RcloneHelpers.remoteErrorStatus(in: output) { return error + "\n" + L10n.string("請檢查帳號、密碼或服務網址後再試。") }
        if text.contains("macfuse") || text.contains("fuse device") || text.contains("mount_macfuse") {
            return L10n.string("macFUSE 無法掛載。請在「掛載元件」檢查安裝及系統授權，或選擇 NFS 後再試。")
        }
        let details = RcloneHelpers.redactLog(output).trimmingCharacters(in: .whitespacesAndNewlines)
        return L10n.string(fallback) + (details.isEmpty ? "" : "\n" + String(details.suffix(1800)))
    }
    private func helperError(_ output: String) -> String {
        if output.hasPrefix("not_empty:") {
            return String(format: L10n.string("掛載資料夾包含檔案：%@。請先移走這些檔案，或選擇另一個空資料夾。"), String(output.dropFirst(10)))
        }
        if output.contains("mounted_path") { return L10n.string("這個位置已掛載、包含其他掛載，或位於網路磁碟內。請先卸載或選擇本機的空資料夾。") }
        if output.contains("symlink_path") { return L10n.string("掛載位置不能使用符號連結，請選擇實際的本機資料夾。") }
        if sessionBlocked { return safetyNotice }
        return friendlyError(output, fallback: "無法安全使用掛載位置。請改用預設資料夾，並確認 app 安裝完整。")
    }

    func cancelInstallation() { installTask?.cancel() }

    func installRclone() {
        guard !isInstallingRclone else { return }
        guard canChangeRclone else {
            errorMessage = L10n.string("請先完成或卸載目前的工作，再安裝或更新 rclone。")
            return
        }
        if let bundled = Self.bundledRclone() {
            rclonePath = bundled
            installationStatus = L10n.string("已啟用內建相容引擎，無需另外下載。")
            refresh()
            return
        }
        isInstallingRclone = true
        installationStatus = L10n.string("正在取得 rclone 最新版本…")
        installTask = Task {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 180
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            do {
                let versionURL = URL(string: "https://downloads.rclone.org/version.txt")!
                let (versionData, versionResponse) = try await session.data(from: versionURL)
                let versionLine = String(data: versionData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let versionToken = versionLine?.split(whereSeparator: \.isWhitespace).last.map(String.init)
                let version = versionToken.map { $0.hasPrefix("v") ? String($0.dropFirst()) : $0 }
                guard (versionResponse as? HTTPURLResponse)?.statusCode == 200,
                      let version,
                      version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
                      Self.isSupportedDrimeVersion(version) else {
                    throw InstallationError.invalidVersion
                }
                #if arch(arm64)
                let architecture = "osx-arm64"
                #else
                let architecture = "osx-amd64"
                #endif
                let archiveName = "rclone-v\(version)-\(architecture).zip"
                let releaseBase = URL(string: "https://downloads.rclone.org/v\(version)/")!
                let (sumsData, sumsResponse) = try await session.data(from: releaseBase.appendingPathComponent("SHA256SUMS"))
                guard (sumsResponse as? HTTPURLResponse)?.statusCode == 200,
                      let sums = String(data: sumsData, encoding: .utf8),
                      let expectedHash = Self.sha256ForArchive(archiveName, in: sums) else {
                    throw InstallationError.checksumUnavailable
                }

                installationStatus = L10n.string("正在從 rclone 官方網站下載 rclone（約 30 MB）…")
                let (archiveURL, archiveResponse) = try await session.download(from: releaseBase.appendingPathComponent(archiveName))
                defer { try? FileManager.default.removeItem(at: archiveURL) }
                guard (archiveResponse as? HTTPURLResponse)?.statusCode == 200 else {
                    throw InstallationError.downloadFailed
                }

                installationStatus = L10n.string("正在驗證檔案並安裝…")
                let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CloudMount/bin", isDirectory: true)
                let destination = support.appendingPathComponent("rclone")
                let archivePath = archiveURL.path
                let destinationPath = destination.path
                let verification = Task.detached(priority: .utility) {
                    try Self.verifyAndInstall(archivePath: archivePath, destinationPath: destinationPath, expectedHash: expectedHash)
                }
                try await withTaskCancellationHandler(operation: { try await verification.value }, onCancel: { verification.cancel() })
                try Task.checkCancellation()
                rclonePath = destination.path
                refresh()
                installationStatus = String(format: L10n.string("rclone %@ 已安裝。遠端空間設定會保留。"), version)
            } catch {
                installationStatus = Task.isCancelled ? L10n.string("安裝已取消") : L10n.string("安裝失敗：") + L10n.error(error)
            }
            isInstallingRclone = false
        }
    }


    private enum InstallationError: LocalizedError {
        case invalidVersion, checksumUnavailable, downloadFailed, checksumMismatch, extractionFailed
        var errorDescription: String? {
            switch self {
            case .invalidVersion: return L10n.string("無法取得有效的 rclone 版本資訊。")
            case .checksumUnavailable: return L10n.string("無法取得這個 rclone 版本的官方 SHA-256 校驗值。")
            case .downloadFailed: return L10n.string("無法下載官方 rclone 套件。")
            case .checksumMismatch: return L10n.string("下載檔案的 SHA-256 驗證不符，已取消安裝。")
            case .extractionFailed: return L10n.string("無法從官方套件中取出 rclone 執行檔。")
            }
        }
    }

    nonisolated private static func isSupportedDrimeVersion(_ version: String) -> Bool {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return false }
        return parts[0] > 1 || (parts[0] == 1 && parts[1] >= 73)
    }

    nonisolated private static func sha256ForArchive(_ filename: String, in sums: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count >= 2 && fields.last?.trimmingCharacters(in: CharacterSet(charactersIn: "*")) == filename {
                return String(fields[0]).lowercased()
            }
        }
        return nil
    }

    nonisolated private static func verifyAndInstall(archivePath: String,
                                                      destinationPath: String,
                                                      expectedHash: String) throws {
        let archive = URL(fileURLWithPath: archivePath)
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        var hasher = SHA256()
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expectedHash else { throw InstallationError.checksumMismatch }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudMount-rclone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let extracted = CommandRunner.run("/usr/bin/ditto", arguments: ["-x", "-k", archive.path, temporary.path], timeout: 30)
        guard extracted.succeeded,
              let enumerator = FileManager.default.enumerator(at: temporary,
                                                              includingPropertiesForKeys: [.isRegularFileKey]),
              let binary = enumerator.allObjects.compactMap({ $0 as? URL })
                .first(where: { $0.lastPathComponent == "rclone" && FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw InstallationError.extractionFailed
        }
        try Task.checkCancellation()
        let target = URL(fileURLWithPath: destinationPath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = target.deletingLastPathComponent().appendingPathComponent("rclone.new")
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.copyItem(at: binary, to: staged)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: target)
        }
    }


}
