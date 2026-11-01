import AppKit
import Combine
import CryptoKit
import Foundation
import Darwin

struct MacFuseInstallation: Equatable, Sendable {
    let version: String?
    let runtimePresent: Bool
    let fsKitMinimumOS: String?
    var kernelLoaded = false
    var fsKitEnabled: Bool? = nil
    var fsKitVisible: Bool? = nil
    static let missing = Self(version: nil, runtimePresent: false, fsKitMinimumOS: nil)

    var usable: Bool {
        guard runtimePresent, let version else { return false }
        return version.compare("5.4.0", options: .numeric) != .orderedAscending
    }
    func supportsFSKit(on systemVersion: String) -> Bool {
        guard usable, let minimum = fsKitMinimumOS else { return false }
        return systemVersion.compare(minimum, options: .numeric) != .orderedAscending
    }
    func resolve(_ preference: MountMethod, systemVersion: String, destination: String? = nil, readOnly: Bool = false) -> MountMethod? {
        // These fixes are first documented in 5.5. Do not send a known-bad
        // request to 5.4 and then race it with a second mount implementation.
        let oldFSKit = (version ?? "0").compare("5.5.0", options: .numeric) == .orderedAscending
        let complexPath = destination?.unicodeScalars.contains { !$0.isASCII || CharacterSet.whitespaces.contains($0) } == true
        let compatible = !(oldFSKit && complexPath) && (!readOnly || (!oldFSKit && systemVersion.compare("26.4", options: .numeric) != .orderedAscending))
        switch preference {
        case .automatic:
            guard usable else { return .nfs }
            return supportsFSKit(on: systemVersion) && fsKitEnabled == true && compatible ? .fskit : (kernelLoaded ? .fuse : .nfs)
        case .nfs: return .nfs
        case .fuse: return usable ? .fuse : nil
        case .fskit: return supportsFSKit(on: systemVersion) && fsKitEnabled == true && compatible ? .fskit : nil
        }
    }
    static func inspect(root: URL = URL(fileURLWithPath: "/Library/Filesystems/macfuse.fs", isDirectory: true),
                        library: String = "/usr/local/lib/libfuse.2.dylib") -> Self {
        func plist(_ relative: String) -> [String: Any]? {
            guard let data = try? Data(contentsOf: root.appendingPathComponent(relative, isDirectory: false)), data.count < 131_072 else { return nil }
            return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        }
        let version = plist("Contents/version.plist")?["CFBundleShortVersionString"] as? String
        let helper = root.appendingPathComponent("Contents/Resources/mount_macfuse", isDirectory: false).path
        let runtime = FileManager.default.isReadableFile(atPath: library) && FileManager.default.isExecutableFile(atPath: helper)
        // FSKit itself debuted in 15.4. The official macFUSE 5.4 network-file-
        // system module requires macOS 26. Read its actual deployment target.
        let module = "Contents/Resources/macfuse.app/Contents/Extensions/io.macfuse.app.fsmodule.macfuse.appex/Contents/Info.plist"
        var size = 0
        var loaded = false
        if sysctlbyname("vfs.generic.macfuse.version.number", nil, &size, nil, 0) == 0, size > 0, size < 128 {
            var bytes = [CChar](repeating: 0, count: size)
            if sysctlbyname("vfs.generic.macfuse.version.number", &bytes, &size, nil, 0) == 0, let version {
                loaded = String(cString: bytes).compare(version, options: .numeric) == .orderedSame
            }
        }
        return Self(version: version, runtimePresent: runtime, fsKitMinimumOS: plist(module)?["LSMinimumSystemVersion"] as? String, kernelLoaded: loaded)
    }
}

enum MacFuseInstaller {
    // Pin an official stable release rather than silently installing previews.
    static let version = "5.4.0"
    static let download = URL(string: "https://github.com/macfuse/macfuse/releases/download/macfuse-5.4.0/macfuse-5.4.0.dmg")!
    static let checksum = "861814f0ac7fa8f6547ea40cdd49a36ac84bcc7d34f38a1fa74e8cf68b0401c5"
    static let website = URL(string: "https://macfuse.github.io/")!
    static let instructions = URL(string: "https://github.com/macfuse/macfuse/wiki/Getting-Started")!

    struct Failure: LocalizedError {
        let key: String
        var blocksRetry = false
        var errorDescription: String? { L10n.string(key) }
    }
    static func validArchive(_ data: Data) -> Bool {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == checksum
    }
    static func prepare() async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (temporary, response) = try await session.download(from: download)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size < 64 * 1_048_576 else { throw Failure(key: "無法下載 macFUSE 官方安裝程式。請稍後重試，或開啟官方網站。") }
        let valid = try await Task.detached(priority: .utility) {
            validArchive(try Data(contentsOf: temporary, options: .mappedIfSafe))
        }.value
        guard valid else { throw Failure(key: "macFUSE 安裝檔校驗不符，已停止安裝。請重新下載。") }
        try Task.checkCancellation()
        let stage = try VaultDisk.privateDirectory(FileManager.default.temporaryDirectory.appendingPathComponent("cloudmount-macfuse-" + UUID().uuidString, isDirectory: true))
        let image = stage.appendingPathComponent("macFUSE.dmg", isDirectory: false)
        let volume = stage.appendingPathComponent("image", isDirectory: true)
        let package = stage.appendingPathComponent("Install macFUSE.pkg", isDirectory: false)
        try FileManager.default.moveItem(at: temporary, to: image)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: false)
        let attached = await CommandRunner.execute("/usr/bin/hdiutil", arguments: ["attach", image.path, "-readonly", "-nobrowse", "-mountpoint", volume.path, "-plist"], timeout: 20)
        // Even an interrupted attach can leave an image mounted. Always try a
        // normal detach of this exact private path; never force-detach images.
        var failure: Error?
        do {
            guard attached.succeeded else { throw Failure(key: "無法開啟 macFUSE 安裝映像。請稍後重試，或開啟官方網站。") }
            try Task.checkCancellation()
            let packages = try FileManager.default.contentsOfDirectory(at: volume, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                .filter { $0.pathExtension == "pkg" }
            guard packages.count == 1, let source = packages.first,
                  try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                  try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw Failure(key: "macFUSE 安裝包內容不完整，已停止安裝。") }
            try FileManager.default.copyItem(at: source, to: package)
            let signature = await CommandRunner.execute("/usr/sbin/pkgutil", arguments: ["--check-signature", package.path], timeout: 15, outputLimit: 16_384)
            guard signature.succeeded, signature.stdout.contains("(3T5GSNBU6W)") else { throw Failure(key: "無法驗證 macFUSE 官方安裝包簽章，已停止安裝。") }
        } catch { failure = error }
        let detached = await CommandRunner.execute("/usr/bin/hdiutil", arguments: ["detach", volume.path], timeout: 10, forceStop: false)
        if attached.succeeded && !detached.succeeded {
            throw Failure(key: "安裝映像仍在使用中。請在 Finder 退出 macFUSE 安裝磁碟，再重新開啟 CloudMount。", blocksRetry: true)
        }
        if attached.stillRunning || detached.stillRunning { throw Failure(key: "安裝工具尚未停止，已暫停重複操作。請稍後檢查，必要時重新啟動 Mac。", blocksRetry: true) }
        if let failure { if detached.succeeded { try? FileManager.default.removeItem(at: stage) }; throw failure }
        try? FileManager.default.removeItem(at: image)
        try? FileManager.default.removeItem(at: volume)
        // The copied, verified package stays available while Apple's Installer
        // uses it. macOS cleans this private temporary directory later.
        return package
    }
}

@MainActor
final class MacFuseSupport: ObservableObject {
    @Published private(set) var installation = MacFuseInstallation.missing
    @Published private(set) var checking = false
    @Published private(set) var preparingInstaller = false
    @Published private(set) var installationPending = false
    @Published var showSetup = false
    @Published var installerMessage = ""
    @Published var installerError: String?
    @Published private(set) var installerBlocked = false
    private var installedPackage: URL?
    private var refreshTask: Task<MacFuseInstallation, Never>?
    nonisolated static var systemVersion: String {
        let value = ProcessInfo.processInfo.operatingSystemVersion
        return "\(value.majorVersion).\(value.minorVersion).\(value.patchVersion)"
    }
    var installationLabel: String {
        guard let version = installation.version else { return L10n.string("尚未安裝 macFUSE") }
        return String(format: L10n.string(installation.usable ? "已安裝 macFUSE %@" : "macFUSE %@ 需要更新或修復"), version)
    }
    func refresh(helperPath: String) async {
        if let task = refreshTask { installation = await task.value; return }
        checking = true
        let task = Task.detached(priority: .utility) {
            var value = MacFuseInstallation.inspect()
            if value.supportsFSKit(on: Self.systemVersion) {
                let result = await CommandRunner.execute(helperPath, arguments: ["macfuse-status"], timeout: 3, outputLimit: 4096)
                if result.succeeded, let status = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Bool] {
                    value.fsKitEnabled = status["enabled"]
                    value.fsKitVisible = status["visible"]
                }
            }
            return value
        }
        refreshTask = task
        installation = await task.value
        refreshTask = nil; checking = false
    }
    func resolved(_ preference: MountMethod, destination: String? = nil, readOnly: Bool = false) -> MountMethod? {
        installation.resolve(preference, systemVersion: Self.systemVersion, destination: destination, readOnly: readOnly)
    }
    func description(for preference: MountMethod) -> String {
        if installationPending { return L10n.string("請先完成 macFUSE 安裝，再到掛載設定按「重新檢查」。") }
        guard let actual = resolved(preference) else { return L10n.string("請先安裝或更新 macFUSE，也可選擇免安裝的 NFS。") }
        if actual == .nfs, preference == .automatic, installation.usable {
            return L10n.string(installation.supportsFSKit(on: Self.systemVersion)
                ? "macFUSE 已安裝，檔案系統擴充尚未就緒，目前使用 NFS。請在系統設定啟用 macFUSE，再按重新檢查。"
                : "macFUSE 核心擴充尚未啟用，目前使用 NFS。可在掛載設定中選擇核心擴充，依照官方說明完成授權。")
        }
        switch actual {
        case .fskit: return L10n.string("優先使用 macFUSE FSKit，並依元件版本與掛載選項選擇可用方式。")
        case .fuse: return L10n.string("新掛載使用 macFUSE 核心擴充；首次使用可能需要系統核准及重新啟動。")
        default: return L10n.string(preference == .automatic ? "目前使用 NFS；安裝 macFUSE 後，新掛載會優先使用 macFUSE。" : "新掛載使用 NFS，不需要額外安裝。")
        }
    }
    func confirmInstallation(helperPath: String) async {
        await refresh(helperPath: helperPath)
        // The user confirms that Installer has finished or was cancelled.
        // Missing/partial components then resolve to NFS through normal policy.
        installationPending = false
    }
    func setupFSKit(helperPath: String) {
        guard installation.usable, !preparingInstaller, !installerBlocked else { return }
        preparingInstaller = true; installerError = nil
        installerMessage = L10n.string("正在準備 macFUSE FSKit 設定…")
        Task {
            defer { preparingInstaller = false }
            if installation.fsKitVisible != true {
                let tool = "/Library/Filesystems/macfuse.fs/Contents/Resources/macfuse.app/Contents/MacOS/macfuse"
                let registered = await CommandRunner.execute(tool, arguments: ["install", "--components", "file-system-extensions"], timeout: 20, outputLimit: 4096)
                guard registered.succeeded else {
                    installerMessage = ""; installerBlocked = registered.stillRunning
                    installerError = L10n.string("無法準備 macFUSE 檔案系統擴充。請依照官方說明完成安裝後再試。")
                    return
                }
            }
            // The official installer can return success while PluginKit still
            // lacks the module. Repair only this vendor's non-local extension.
            let identifier = "io.macfuse.app.fsmodule.macfuse"
            var listing = await CommandRunner.execute("/usr/bin/pluginkit", arguments: ["-m", "-A", "-D", "-i", identifier], timeout: 3, outputLimit: 8192)
            if listing.succeeded && !listing.stdout.contains(identifier) {
                let module = "/Library/Filesystems/macfuse.fs/Contents/Resources/macfuse.app/Contents/Extensions/" + identifier + ".appex"
                let added = await CommandRunner.execute("/usr/bin/pluginkit", arguments: ["-a", module], timeout: 5, outputLimit: 4096)
                guard added.succeeded else {
                    installerBlocked = added.stillRunning
                    installerError = L10n.string("無法準備 macFUSE 檔案系統擴充。請依照官方說明完成安裝後再試。")
                    installerMessage = ""; return
                }
                listing = await CommandRunner.execute("/usr/bin/pluginkit", arguments: ["-m", "-A", "-D", "-i", identifier], timeout: 3, outputLimit: 8192)
            }
            guard listing.succeeded, listing.stdout.contains(identifier) else {
                installerBlocked = listing.stillRunning
                installerError = L10n.string("無法準備 macFUSE 檔案系統擴充。請依照官方說明完成安裝後再試。")
                installerMessage = ""; return
            }
            await refresh(helperPath: helperPath)
            _ = await CommandRunner.execute("/usr/bin/open", arguments: ["x-apple.systempreferences:com.apple.LoginItems-Settings.extension?ExtensionItems"], timeout: 5, outputLimit: 4096)
            installerMessage = L10n.string("請切換為「按照類別」，進入「檔案系統延伸功能」開啟 macFUSE，再回到 CloudMount 按「重新檢查」。")
        }
    }
    func openInstaller() {
        guard !preparingInstaller, !installerBlocked else { return }
        preparingInstaller = true; installerError = nil
        installerMessage = L10n.string("正在下載並驗證 macFUSE 官方安裝程式…")
        Task {
            defer { preparingInstaller = false }
            do {
                let package: URL
                if let installedPackage, FileManager.default.fileExists(atPath: installedPackage.path) { package = installedPackage }
                else { package = try await MacFuseInstaller.prepare(); installedPackage = package }
                let result = await CommandRunner.execute("/usr/bin/open", arguments: ["-b", "com.apple.installer", package.path], timeout: 5, outputLimit: 4096)
                guard result.succeeded else { throw MacFuseInstaller.Failure(key: "無法開啟系統安裝程式。請使用官方網站安裝 macFUSE。") }
                installationPending = true
                installerMessage = L10n.string("已開啟系統安裝程式。完成安裝後，按「重新檢查」即可。")
            } catch {
                installerMessage = ""
                installerBlocked = (error as? MacFuseInstaller.Failure)?.blocksRetry == true
                installerError = (error as? MacFuseInstaller.Failure)?.localizedDescription ?? L10n.string("無法下載 macFUSE 官方安裝程式。請稍後重試，或開啟官方網站。")
            }
        }
    }
}
