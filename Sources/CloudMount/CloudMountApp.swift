import SwiftUI
import AppKit
import CloudMountLocalization

@main
struct CloudMountApp: App {
    @StateObject private var model = AppModel(startup: SessionSafety.acquireInstanceLock())
    @NSApplicationDelegateAdaptor(CloudMountAppDelegate.self) private var appDelegate

    init() {
        if !SessionSafety.acquireInstanceLock() {
            DispatchQueue.main.async {
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.codex.cloudmount").first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })?.activate()
                NSApp.terminate(nil)
            }
        }
    }

    var body: some Scene {
        Window("CloudMount", id: "main") {
            ContentView(model: model)
                .environment(\.locale, L10n.locale)
                .frame(minWidth: 860, minHeight: 610)
                .onAppear {
                    appDelegate.setModel(model)
                    NSApp.setActivationPolicy(.regular)
                }
                .onDisappear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { NSApp.setActivationPolicy(.accessory) }
                    }
                }
        }
        .windowStyle(.titleBar)
        .commands { CloudMountInfoCommands() }

        MenuBarExtra {
            MenuBarContent(model: model)
            .environment(\.locale, L10n.locale)
            .onAppear { appDelegate.setModel(model) }
        } label: {
            Image(systemName: "externaldrive.badge.wifi")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.primary)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class CloudMountAppDelegate: NSObject, NSApplicationDelegate {
    private weak var model: AppModel?
    private var isPreparingToTerminate = false

    func setModel(_ model: AppModel) {
        self.model = model
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !isPreparingToTerminate else { return .terminateCancel }
        isPreparingToTerminate = true
        model.stopAllForQuit { success in
            if !success {
                self.isPreparingToTerminate = false
                NSApp.setActivationPolicy(.regular)
                NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            sender.reply(toApplicationShouldTerminate: success)
        }
        return .terminateLater
    }
}

struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Button(L10n.string("開啟 CloudMount")) {
                NSApp.setActivationPolicy(.regular)
                openWindow(id: "main")
            }
            Divider()
            if model.mounts.isEmpty {
                Text(L10n.string("沒有已掛載空間"))
            } else {
                Section(L10n.string("目前已掛載")) {
                    ForEach(model.mounts) { mount in
                        Menu {
                            Button(L10n.string("在 Finder 開啟")) { model.openInFinder(mount) }.disabled(!model.canOpen(mount))
                            Button(mount.phase.unmountActionTitle) { model.unmount(mount) }.disabled(!model.canUnmount(mount))
                        } label: {
                            Label("\(mount.remote) · \((mount.destination as NSString).lastPathComponent)", systemImage: "externaldrive")
                        }
                    }
                }
            }
            VaultMenu(manager: model.vaults)
            Divider()
            Button(L10n.string("關於 CloudMount")) { AboutCloudMount.show() }
            Button(L10n.string("結束 CloudMount")) { NSApp.terminate(nil) }
        }
    }
}

private enum RemoteSetupAction: Identifiable {
    case create, edit(String)
    var remote: String? { if case .edit(let name) = self { return name }; return nil }
    var id: String { remote.map { "edit:" + $0 } ?? "create" }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showLog = false
    @State private var showSyncConfirmation = false
    @State private var remoteSetup: RemoteSetupAction?
    @State private var remoteToDelete: String?
    @State private var showMountOptions = false
    @State private var showPreferences = false
    @State private var showMountFolderBrowser = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $model.selectedRemote) {
                    Section(L10n.string("遠端空間")) {
                        ForEach(model.remotes, id: \.self) { remote in
                            Label(remote, systemImage: "externaldrive")
                                .tag(remote)
                                .contextMenu {
                                    Button(L10n.string("測試連線")) { model.testRemote(remote) }
                                    Button(L10n.string("編輯遠端設定")) {
                                        remoteSetup = .edit(remote)
                                    }
                                    Button(L10n.string("刪除遠端設定"), role: .destructive) { remoteToDelete = remote }
                                        .disabled(model.mounts.contains(where: { $0.remote == remote }))
                                }
                        }
                    }
                }
                .listStyle(.sidebar)
                Divider()
                HStack {
                    Button {
                        remoteSetup = .create
                    } label: {
                        Label(L10n.string("新增遠端"), systemImage: "plus")
                    }
                    .disabled(!model.hasRclone || model.isLoadingProviders || model.isConfiguringRemote || model.configurationWriterActive)
                    Menu {
                        if !model.selectedRemote.isEmpty {
                            Button(L10n.string("編輯遠端設定")) {
                                remoteSetup = .edit(model.selectedRemote)
                            }
                            Button(L10n.string("測試連線")) { model.testRemote(model.selectedRemote) }
                            Button(L10n.string("刪除遠端設定"), role: .destructive) { remoteToDelete = model.selectedRemote }
                                .disabled(model.mounts.contains(where: { $0.remote == model.selectedRemote }))
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .help(L10n.string("管理所選遠端"))
                    .disabled(model.selectedRemote.isEmpty)
                    Spacer()
                    Button {
                        model.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help(L10n.string("重新整理遠端清單"))
                    .disabled(!model.hasRclone || model.isRefreshing)
                }
                .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 240)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    MountDriverCard(model: model, support: model.macFuse)
                    if !model.hasRclone || (model.version.isEmpty && !model.isRefreshing) { installCard }
                    else {
                        if !model.safetyNotice.isEmpty {
                            Label(model.safetyNotice, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange).textSelection(.enabled)
                        }
                        if model.isRefreshing { ProgressView(L10n.string("正在讀取設定…")) }
                        mountCard
                        activeMountsCard
                        FinderRequestNotice(opener: model.finderOpener)
                        VaultCard(manager: model.vaults, model: model)
                        startupCard
                        DisclosureGroup(L10n.string("偏好設定與進階功能"), isExpanded: $showPreferences) {
                            VStack(spacing: 20) { cacheCard; transferCard; rcloneCard; guideCard }.padding(.top, 12)
                        }
                    }
                    if showLog { logCard }
                }
                .padding(28)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .alert("CloudMount", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button(L10n.string("確定"), role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(item: $remoteSetup) { action in
            RemoteSetupSheet(model: model, editingRemote: action.remote)
        }
        .sheet(isPresented: $showMountFolderBrowser) {
            VaultFolderBrowser(manager: model.vaults, remote: model.selectedRemote, initialPath: model.folder) { model.folder = $0 }
        }
        .confirmationDialog(L10n.string("刪除遠端設定？"), isPresented: Binding(
            get: { remoteToDelete != nil },
            set: { if !$0 { remoteToDelete = nil } }
        ), titleVisibility: .visible) {
            Button(L10n.string("刪除設定"), role: .destructive) {
                if let remoteToDelete { model.deleteRemote(remoteToDelete) }
                remoteToDelete = nil
            }
            Button(L10n.string("取消"), role: .cancel) { remoteToDelete = nil }
        } message: {
            Text(String(format:L10n.string("這會從 rclone 設定中移除 %@。雲端檔案不會被刪除。"),remoteToDelete ?? ""))
        }
        .confirmationDialog(L10n.string("執行同步？"), isPresented: $showSyncConfirmation) {
            Button(L10n.string("確認同步（會刪除目的地多餘檔案）"), role: .destructive) {
                model.executeSync()
                showLog = true
            }
            Button(L10n.string("取消"), role: .cancel) {}
        } message: {
            Text(L10n.string("rclone sync 會讓目的地與來源一致。目的地中來源沒有的檔案會被刪除。請先確認預覽紀錄。"))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.wifi")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.blue)
                Text("CloudMount")
                    .font(.largeTitle.bold())
                Text(AppInformation.version)
                    .font(.caption).foregroundStyle(.secondary)
                Button { AboutCloudMount.show() } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.plain)
                    .help(L10n.string("關於 CloudMount"))
                    .accessibilityLabel(L10n.string("關於 CloudMount"))
            }
            Text(L10n.string("在 Finder 中使用 Drime 與其他 rclone 遠端空間"))
                .foregroundStyle(.secondary)
        }
    }

    private var installCard: some View {
        card {
            Label(L10n.string("尚未找到 rclone"), systemImage: "arrow.down.circle")
                .font(.title3.bold())
            Text(L10n.string("CloudMount 可從 rclone 官方網站下載並安裝執行檔，不需要 Homebrew 或系統管理員權限。"))
                .foregroundStyle(.secondary)
            HStack {
                Button(L10n.string("一鍵安裝 rclone")) { model.installRclone() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isInstallingRclone)
                Button(L10n.string("選擇 rclone 執行檔")) { model.chooseRclone() }
                    .disabled(model.isInstallingRclone)
                Button(L10n.string("查看安裝說明")) {
                    NSWorkspace.shared.open(URL(string: "https://rclone.org/install/")!)
                }
            }
            if model.isInstallingRclone { HStack { ProgressView(); Button(L10n.string("取消安裝")) { model.cancelInstallation() } } }
            if !model.installationStatus.isEmpty {
                Text(model.installationStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var rcloneCard: some View {
        card {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Label(L10n.string("rclone 已就緒"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.headline)
                    Text(model.version.isEmpty ? model.rclonePath : "\(model.version) · \(model.rclonePath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button(L10n.string("更換")) { model.chooseRclone() }.disabled(!model.canChangeRclone)
                Button(L10n.string("安裝 / 更新")) { model.installRclone() }
                    .disabled(model.isInstallingRclone || !model.mounts.isEmpty || model.isTransferring)
            }
            if model.isInstallingRclone { HStack { ProgressView(); Button(L10n.string("取消安裝")) { model.cancelInstallation() } } }
            if !model.installationStatus.isEmpty {
                Text(model.installationStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var mountCard: some View {
        card {
            Label(L10n.string("掛載遠端空間"), systemImage: "externaldrive.fill.badge.person.crop")
                .font(.title3.bold())
            if model.remotes.isEmpty {
                Text(L10n.string("尚未設定遠端。按左下角「新增遠端」並依表單輸入連線資訊。設定 Drime 時，選擇 Drime 類型並填入 API 存取權杖。"))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(L10n.string("遠端"))
                            .frame(width: 100, alignment: .leading)
                        Picker(L10n.string("遠端"), selection: $model.selectedRemote) {
                            ForEach(model.remotes, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                    }
                    if model.selectedRemoteIsS3 {
                        HStack {
                            Text(L10n.string("儲存桶（必填）"))
                                .frame(width: 100, alignment: .leading)
                            TextField(L10n.string("填入或選擇儲存桶名稱"), text: Binding(get: { model.mountBucket }, set: { model.mountBucket = $0 }))
                                .textFieldStyle(.roundedBorder)
                            Button(L10n.string("選擇…")) { showMountFolderBrowser = true }
                                .disabled(model.vaultOperationBusy || model.isConfiguringRemote || model.isQuitting)
                        }
                        Text(L10n.string("請指定要掛載的儲存桶；路徑前綴可留空。"))
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text(L10n.string("路徑前綴（選填）"))
                                .frame(width: 100, alignment: .leading)
                            TextField(L10n.string("例如 notes/；留空則使用整個儲存桶"), text: Binding(get: { model.mountSubfolder }, set: { model.mountSubfolder = $0 }))
                                .textFieldStyle(.roundedBorder)
                                .disabled(model.mountBucket.isEmpty)
                        }
                    }
                    DisclosureGroup(L10n.string("掛載選項（通常不需要修改）"), isExpanded: $showMountOptions) {
                    VStack(alignment: .leading, spacing: 14) {
                    if !model.selectedRemoteIsS3 { HStack {
                        Text(L10n.string("遠端子資料夾"))
                            .frame(width: 100, alignment: .leading)
                        TextField(L10n.string(model.selectedRemoteIsS3 ? "留空則掛載整個儲存桶" : "留空則掛載整個空間"), text: Binding(get: { model.mountSubfolder }, set: { model.mountSubfolder = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .disabled(model.selectedRemoteIsS3 && model.mountBucket.isEmpty)
                    } }
                    HStack {
                        Text(L10n.string("本機資料夾"))
                            .frame(width: 100, alignment: .leading)
                        TextField(L10n.string("預設：~/CloudMounts/遠端名稱"), text: $model.destination)
                            .textFieldStyle(.roundedBorder)
                        Button(L10n.string("選擇…")) { model.chooseDestination() }
                    }
                    Toggle(L10n.string("唯讀掛載"), isOn: $model.readOnly)
                    }
                    .padding(.top, 8)
                    }
                    HStack {
                        Button(L10n.string("掛載並在 Finder 開啟")) { model.mount() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.selectedRemote.isEmpty || !model.canStartMount)

                    }
                }
            }
        }
    }

    private var startupCard: some View {
        card {
            Label(L10n.string("登入與自動掛載"), systemImage: "power")
                .font(.title3.bold())
            Toggle(L10n.string("登入 macOS 時啟動 CloudMount"), isOn: Binding(
                get: { model.launchesAtLogin },
                set: { model.setLaunchesAtLogin($0) }
            ))
            Toggle(L10n.string("隨 app 啟動自動掛載已勾選空間"), isOn: $model.autoMountEnabled)
            Text(L10n.string("未開啟自動掛載時，啟動 app 只會讀取設定，不會建立遠端掛載。登入啟動與自動掛載分別控制。"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if model.remotes.isEmpty {
                Text(L10n.string("先新增遠端空間，之後即可選擇自動掛載項目。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.autoMountEnabled {
                VStack(spacing: 8) {
                    ForEach(model.remotes, id: \.self) { remote in
                        Toggle(isOn: Binding(
                            get: { model.automaticMounts.contains(remote) },
                            set: { model.setAutomaticMount(remote, enabled: $0) }
                        )) {
                            Label(remote, systemImage: "externaldrive")
                        }
                    }
                }
                .padding(.leading, 4)
            }
            if !model.loginItemStatus.isEmpty {
                Text(model.loginItemStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var cacheCard: some View {
        card {
            Label(L10n.string("本機快取"), systemImage: "internaldrive")
                .font(.title3.bold())
            Toggle(L10n.string("快取讀取過的檔案"), isOn: $model.cacheReadFiles)
            Text(L10n.string("開啟後，讀取過的檔案內容也會暫存在本機，重讀時可減少網路存取；這不會自動下載整個遠端空間。"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Text(L10n.string("快取空間上限"))
                    .frame(width: 130, alignment: .leading)
                TextField("20", value: Binding(
                    get: { model.cacheMaxSizeGB },
                    set: { model.cacheMaxSizeGB = max(1, min($0, 1000)) }
                ), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
                Text("GB")
            }
            HStack {
                Text(L10n.string("保留閒置快取"))
                    .frame(width: 130, alignment: .leading)
                TextField("24", value: Binding(
                    get: { model.cacheMaxAgeHours },
                    set: { model.cacheMaxAgeHours = max(1, min($0, 8760)) }
                ), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
                Text(L10n.string("小時"))
            }
            Text(L10n.string("rclone 依快取檔案最後使用時間清理舊檔；正在使用的檔案可能讓實際用量短暫超過上限。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(L10n.string("目錄更新間隔"))
                    .frame(width: 130, alignment: .leading)
                Stepper(value: Binding(get: { model.cacheDirectoryMinutes },
                    set: { model.cacheDirectoryMinutes = MountCachePolicy.directoryMinutes($0) }), in: 1...60) {
                    Text(String(format: L10n.string("%d 分鐘"), model.cacheDirectoryMinutes))
                }.frame(width: 150)
            }
            Text(L10n.string("目錄清單在掛載期間暫存於記憶體。間隔越長，重複查詢越少，但其他電腦的變更可能較晚出現；預設 5 分鐘。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.string("Finder 縮圖由 macOS 產生與管理。首次預覽仍可能下載原圖；開啟檔案快取可重用已讀內容，不會預先掃描或下載所有圖片。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.string("系統會盡量保留 1 GB 可用空間，並降低每個讀取的記憶體緩衝；未上傳或正在使用的快取不會為了清理而刪除。"))
                .font(.caption).foregroundStyle(.secondary)
            Label(L10n.string("設定只套用於新掛載；請卸載後重新掛載，讓設定生效。"), systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var activeMountsCard: some View {
        card {
            Label(L10n.string("目前掛載"), systemImage: "square.stack.3d.up")
                .font(.title3.bold())
            if model.mounts.isEmpty {
                Text(L10n.string("尚未掛載任何遠端空間。"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.mounts) { mount in
                    HStack(spacing: 12) {
                        Image(systemName: "externaldrive")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(RcloneHelpers.remotePath(name: mount.remote, folder: mount.folder))
                                .fontWeight(.medium)
                            Text(mount.destination)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Text(L10n.string(mount.status))
                            .font(.caption)
                            .foregroundStyle(mount.status == L10n.string("已掛載") ? Color.secondary : Color.orange)
                        if !mount.owned { Text(L10n.string("由其他程序掛載")).font(.caption2).foregroundStyle(.secondary) }
                        Button("Finder") { model.openInFinder(mount) }.disabled(!model.canOpen(mount))
                        Button(mount.phase.unmountActionTitle) { model.unmount(mount) }.disabled(!model.canUnmount(mount))
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private var transferCard: some View {
        card {
            Label(L10n.string("複製與同步"), systemImage: "arrow.left.arrow.right")
                .font(.title3.bold())
            Text(L10n.string("複製只新增或更新檔案；同步會刪除目的地多出的檔案，執行前須先預覽。"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Text(L10n.string("方向"))
                    .frame(width: 100, alignment: .leading)
                Picker(L10n.string("方向"), selection: $model.transferDirection) {
                    ForEach(TransferDirection.allCases) { Text(L10n.string($0.rawValue)).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
            HStack {
                Text(L10n.string("本機資料夾"))
                    .frame(width: 100, alignment: .leading)
                TextField(L10n.string("選擇來源或目的地"), text: $model.transferLocal)
                    .textFieldStyle(.roundedBorder)
                Button(L10n.string("選擇…")) { model.chooseTransferLocal() }
            }
            HStack {
                Text(L10n.string("遠端資料夾"))
                    .frame(width: 100, alignment: .leading)
                TextField(L10n.string("留空則為遠端根目錄"), text: $model.transferRemoteFolder)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 10) {
                Button(L10n.string("複製")) {
                    model.copyFiles()
                    showLog = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isTransferring)
                Button(L10n.string("預覽同步")) {
                    model.previewSync()
                    showLog = true
                }
                .disabled(model.isTransferring)
                Button(L10n.string("確認同步")) { showSyncConfirmation = true }
                    .disabled(!model.syncPreviewReady || model.isTransferring)
                if model.isTransferring { Button(L10n.string("取消工作")) { model.cancelTransfer() } }
                Spacer()
                Text(model.transferStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(model.selectedRemote.isEmpty)
        }
    }

    private var guideCard: some View {
        card {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.string("設定 Drime"))
                        .font(.headline)
            Text(L10n.string("在 Drime 網站的 Settings → Developer 建立 API token，再於「新增遠端」表單選擇 Drime 並填入權杖。"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.string("官方指南")) {
                    NSWorkspace.shared.open(URL(string: "https://rclone.org/drime/")!)
                }
            }
            Divider()
            Button(L10n.string(showLog ? "隱藏執行紀錄" : "顯示執行紀錄")) { showLog.toggle() }
        }
    }

    private var logCard: some View {
        card {
            Text(L10n.string("執行紀錄"))
                .font(.headline)
            ScrollView {
                Text(L10n.string(model.log.isEmpty ? "暫無紀錄" : model.log))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 160)
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.08)))
    }
}

private struct RemoteSetupSheet: View {
    @ObservedObject var model: AppModel
    let editingRemote: String?
    @Environment(\.dismiss) private var dismiss
    @State private var remoteName = ""
    @State private var selectedProvider = ""
    @State private var values: [String: String] = [:]
    @State private var showAdvanced = false
    @State private var showOptional = false
    @State private var questionAnswer = ""
    @State private var remoteConfig: [String: String] = [:]
    @State private var remoteBackend = ""
    @State private var wizardStep = 1
    @State private var providerSearch = ""
    @State private var webdavAuthentication = "password"
    @State private var sftpAuthentication = "password"
    @State private var clearedKeys: Set<String> = []
    @State private var s3Bucket = ""
    @State private var s3Subfolder = ""

    private var formPolicy: ProviderFormPolicy? {
        provider.map { ProviderFormPolicy(provider: $0, values: values, editing: editingRemote != nil,
            webdavAuthentication: webdavAuthentication, sftpAuthentication: sftpAuthentication) }
    }

    private var provider: RcloneProvider? { model.providers.first(where: { $0.prefix == selectedProvider }) }
    private var basicOptions: [RcloneProviderOption] { formPolicy?.basic ?? [] }
    private var optionalOptions: [RcloneProviderOption] {
        let inactive: Set<String>
        if selectedProvider == "webdav" { inactive = webdavAuthentication == "token" ? ["user", "pass"] : webdavAuthentication == "none" ? ["user", "pass", "bearer_token"] : ["bearer_token"] }
        else if selectedProvider == "sftp" { inactive = sftpAuthentication == "password" ? ["key_file", "key_file_pass", "key_pem", "key_use_agent"] : sftpAuthentication == "key" ? ["pass", "key_use_agent"] : ["pass", "key_file", "key_file_pass", "key_pem"] }
        else { inactive = [] }
        return (formPolicy?.optional ?? []).filter { !inactive.contains($0.name) }
    }
    private var advancedOptions: [RcloneProviderOption] { formPolicy?.advanced ?? [] }
    private var filteredProviders: [RcloneProvider] {
        let query = providerSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let favorites = ["drime", "webdav", "internxt", "drive", "onedrive", "dropbox", "sftp", "s3", "smb", "ftp"]
        return model.providers.filter {
            query.isEmpty || $0.description.localizedCaseInsensitiveContains(query) || $0.prefix.localizedCaseInsensitiveContains(query) ||
                L10n.providerName(prefix: $0.prefix, fallback: $0.description).localizedCaseInsensitiveContains(query)
        }.sorted { (favorites.firstIndex(of: $0.prefix) ?? 999) < (favorites.firstIndex(of: $1.prefix) ?? 999) }
    }
    private var validName: Bool { RcloneHelpers.isValidRemoteName(remoteName.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var validationError: String? {
        formPolicy?.validationError ?? (selectedProvider == "s3" ? RcloneHelpers.s3BucketError(s3Bucket) ?? RcloneHelpers.s3PrefixError(bucket: s3Bucket, prefix: s3Subfolder) : nil)
    }
    private var defaultMountFolder: String? {
        selectedProvider == "s3" ? RcloneHelpers.s3MountPath(bucket: s3Bucket, subfolder: s3Subfolder) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string(editingRemote == nil ? "新增遠端空間" : "編輯遠端設定")).font(.title2.bold())
                    Text(L10n.string(editingRemote == nil ? "先選擇雲端服務，再依步驟填寫連線資訊。" : "依表單修改遠端連線資訊。OAuth 和補充設定會在此視窗接續。"))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.string("關閉")) { model.cancelRemoteConfiguration(); dismiss() }
            }
            Divider()
            if model.isLoadingProviders {
                ProgressView(L10n.string("正在載入 rclone 支援的雲端類型…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.providers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "externaldrive.badge.xmark").font(.largeTitle)
                    Text(L10n.string("無法載入 rclone 雲端類型"))
                    Text(L10n.string("請確認 rclone 已安裝，再重新整理遠端清單。"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let question = model.configurationQuestion {
                authorizationQuestion(question)
            } else if editingRemote == nil && wizardStep == 1 {
                VStack(alignment: .leading, spacing: 14) {
                    Label(L10n.string("步驟 1／2：選擇雲端服務"), systemImage: "1.circle.fill")
                        .font(.headline)
                    TextField(L10n.string("遠端名稱，例如 Drime"), text: $remoteName)
                        .textFieldStyle(.roundedBorder)
                    TextField(L10n.string("搜尋雲端服務"), text: $providerSearch)
                        .textFieldStyle(.roundedBorder)
                    List(filteredProviders) { item in
                        Button {
                            selectedProvider = item.prefix
                            if remoteName.isEmpty {
                                let base = item.prefix.capitalized
                                var name = base, index = 2
                                while model.remotes.contains(name) { name = "\(base)-\(index)"; index += 1 }
                                remoteName = name
                            }
                        } label: {
                            HStack {
                                Image(systemName: selectedProvider == item.prefix ? "checkmark.circle.fill" : "externaldrive")
                                    .foregroundStyle(selectedProvider == item.prefix ? .blue : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L10n.providerName(prefix: item.prefix, fallback: item.description.isEmpty ? item.name : item.description)).fontWeight(.medium).lineLimit(2)
                                    Text(item.prefix).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(minHeight: 170, maxHeight: 230)
                    if let provider {
                        Text(L10n.providerDescription(prefix: provider.prefix, fallback: provider.description))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if editingRemote == nil {
                            Label(L10n.string("步驟 2／2：填寫連線資訊"), systemImage: "2.circle.fill")
                                .font(.headline)
                            HStack {
                                Text(provider.map { L10n.providerName(prefix: $0.prefix, fallback: $0.description.isEmpty ? $0.name : $0.description) } ?? selectedProvider).fontWeight(.medium)
                                Spacer()
                                Button(L10n.string("更改服務")) { wizardStep = 1 }.disabled(model.isConfiguringRemote)
                            }
                        } else {
                            LabeledContent(L10n.string("遠端名稱"), value: remoteName)
                            LabeledContent(L10n.string("雲端類型"), value: provider.map { L10n.providerName(prefix: $0.prefix, fallback: $0.description.isEmpty ? $0.name : $0.description) } ?? remoteBackend)
                        }
                        if let provider {
                            Text(L10n.providerDescription(prefix: provider.prefix, fallback: provider.description))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(L10n.string("只需填寫必填欄位。已有預設值的項目會自動套用，其餘設定可按需要展開。"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if selectedProvider == "webdav" {
                                Picker(L10n.string("登入方式"), selection: $webdavAuthentication) {
                                    Text(L10n.string("帳號與密碼")).tag("password")
                                    Text(L10n.string("存取權杖")).tag("token")
                                    Text(L10n.string("不需要登入")).tag("none")
                                }
                            }
                            if selectedProvider == "sftp" {
                                Picker(L10n.string("登入方式"), selection: $sftpAuthentication) {
                                    Text(L10n.string("密碼")).tag("password")
                                    Text(L10n.string("SSH 私密金鑰檔")).tag("key")
                                    Text(L10n.string("SSH 代理程式")).tag("agent")
                                }
                            }
                            if basicOptions.isEmpty { Text(L10n.string("可直接建立，若服務需要額外授權，會接續顯示步驟。")).foregroundStyle(.secondary) }
                            ForEach(basicOptions) { option in
                                optionField(option)
                            }
                            if selectedProvider == "s3" {
                                if RcloneHelpers.s3NeedsCompatibleProvider(values) {
                                    Label(L10n.string("自架 S3 通常應選「其他 S3 相容服務」或 MinIO；AWS 模式可能將儲存桶加到網域前面，造成找不到伺服器。"), systemImage: "info.circle")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                                Text(L10n.string("預設掛載儲存桶（必填）")).fontWeight(.medium)
                                TextField(L10n.string("填入服務提供的儲存桶名稱"), text: $s3Bucket)
                                    .textFieldStyle(.roundedBorder)
                                Text(L10n.string("請指定要掛載的儲存桶；路徑前綴可留空。"))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(L10n.string("路徑前綴（選填）")).fontWeight(.medium)
                                TextField(L10n.string("例如 notes/；留空則使用整個儲存桶"), text: $s3Subfolder)
                                    .textFieldStyle(.roundedBorder)
                                Text(L10n.string("使用存取金鑰連線至私有儲存桶；此設定不會變更雲端的公開權限。"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if !optionalOptions.isEmpty {
                                DisclosureGroup(String(format: L10n.string("選填設定（%@）"), String(optionalOptions.count)), isExpanded: $showOptional) {
                                    VStack(alignment: .leading, spacing: 14) {
                                        Text(L10n.string("大多數情況可留空；只有服務要求時再填寫。"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        ForEach(optionalOptions) { option in optionField(option) }
                                    }
                                    .padding(.top, 10)
                                }
                            }
                            if !advancedOptions.isEmpty {
                                DisclosureGroup(String(format: L10n.string("進階選項（%@）"), String(advancedOptions.count)), isExpanded: $showAdvanced) {
                                    VStack(alignment: .leading, spacing: 14) {
                                        ForEach(advancedOptions) { option in optionField(option) }
                                    }
                                    .padding(.top, 10)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            if wizardStep == 2, let error = validationError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if !model.configurationStatus.isEmpty {
                Text(model.configurationStatus).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if let question = model.configurationQuestion {
                    Button(L10n.string("繼續")) {
                        model.answerConfigurationQuestion(questionAnswer)
                        questionAnswer = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.configurationBusy || !question.accepts(answer: questionAnswer))
                } else if editingRemote == nil && wizardStep == 1 {
                    Button(L10n.string("下一步")) { wizardStep = 2 }
                        .buttonStyle(.borderedProminent)
                        .disabled(provider == nil || !validName)
                } else {
                    if editingRemote == nil {
                        Button(L10n.string("上一步")) { wizardStep = 1 }
                            .disabled(model.isConfiguringRemote)
                    }
                    Button(L10n.string(editingRemote == nil ? "建立遠端" : "儲存變更")) {
                        guard let provider else { return }
                        if editingRemote == nil {
                            model.createRemote(name: remoteName, provider: provider, values: formPolicy?.submittedValues ?? values, mountFolder: defaultMountFolder)
                        } else {
                            model.updateRemote(name: remoteName, provider: provider, values: formPolicy?.submittedValues ?? values, clearing: clearedKeys, mountFolder: defaultMountFolder)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isConfiguringRemote || provider == nil || !validName || validationError != nil || !model.remoteEditorStatus.isEmpty)
                }
            }
        }
        .padding(22)
        .frame(width: 620, height: 650)
        .onAppear {
            model.beginRemoteEditor()
            remoteName = editingRemote ?? ""
            if let editingRemote {
                let path = RcloneHelpers.splitS3MountPath(model.preferredMountFolder(for: editingRemote))
                s3Bucket = path.bucket; s3Subfolder = path.subfolder
            }
            wizardStep = editingRemote == nil ? 1 : 2
            model.loadProviders()
            if let editingRemote {
                model.loadRemoteConfiguration(editingRemote) { backend, config in
                    remoteBackend = backend
                    remoteConfig = config
                    selectedProvider = backend
                    applyRemoteValues()
                }
            }
        }
        .onChange(of: model.providers) { providers in
            applyRemoteValues()
        }
        .onChange(of: selectedProvider) { _ in
            if editingRemote == nil {
                values = selectedProvider == "s3" ? ["provider": "Other"] : [:]
                s3Bucket = ""; s3Subfolder = ""
                clearedKeys = []; showOptional = false; showAdvanced = false
            } else { applyRemoteValues() }
        }
        .onChange(of: webdavAuthentication) { mode in
            let inactive = mode == "token" ? ["user", "pass"] : mode == "none" ? ["user", "pass", "bearer_token"] : ["bearer_token"]
            for key in ["user", "pass", "bearer_token"] { clearedKeys.remove(key) }
            for key in inactive { values.removeValue(forKey: key); if editingRemote != nil { clearedKeys.insert(key) } }
        }
        .onChange(of: sftpAuthentication) { mode in
            let inactive = mode == "password" ? ["key_file", "key_pem", "key_use_agent"] : mode == "key" ? ["pass", "key_use_agent"] : ["pass", "key_file", "key_pem"]
            for key in ["pass", "key_file", "key_pem", "key_use_agent"] { clearedKeys.remove(key) }
            for key in inactive { values.removeValue(forKey: key); if editingRemote != nil { clearedKeys.insert(key) } }
            if mode == "agent" { values["key_use_agent"] = "true" }
        }
        .onChange(of: model.configurationQuestion.map { $0.state + "|" + $0.option.name }) { _ in questionAnswer = model.configurationQuestion?.option.defaultValue ?? "" }
        .onDisappear { model.cancelRemoteConfiguration() }
        .onChange(of: model.configurationStatus) { status in
            if status == L10n.string("遠端已建立。") || status == L10n.string("遠端已更新。") { dismiss() }
        }
        .alert(L10n.string("遠端設定"), isPresented: Binding(
            get: { model.configurationError != nil },
            set: { if !$0 { model.configurationError = nil } }
        )) {
            Button(L10n.string("確定"), role: .cancel) { model.configurationError = nil }
        } message: {
            Text(model.configurationError ?? "")
        }
        .overlay {
            if model.configurationBusy || !model.remoteEditorStatus.isEmpty {
                ProgressView(L10n.string(editingRemote != nil && !model.remoteEditorStatus.isEmpty ? "正在讀取遠端設定…" : "正在設定遠端…"))
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    @ViewBuilder
    private func optionField(_ option: RcloneProviderOption) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(L10n.optionLabel(providerPrefix: selectedProvider, optionName: option.name)).fontWeight(.medium)
                if (option.required || selectedProvider == "drime" && option.name == "access_token") && !(editingRemote != nil && option.isSecret) { Text(L10n.string("必填")).font(.caption2).foregroundStyle(.orange) }
            }
            if selectedProvider == "s3", option.name == "force_path_style" {
                let supported = RcloneHelpers.s3AllowsPathStyle(provider: formPolicy?.effectiveProvider ?? "Other")
                Picker(L10n.string("URL 風格"), selection: Binding(
                    get: { supported ? values[option.name] ?? "" : "" },
                    set: { values[option.name] = $0 }
                )) {
                    Text(L10n.string("依服務預設")).tag("")
                    Text(L10n.string("路徑式：endpoint/bucket/key")).tag("true").disabled(!supported)
                    Text(L10n.string("網域式：bucket.endpoint/key")).tag("false")
                }.labelsHidden().disabled(!supported)
                Text(L10n.optionHelp(providerPrefix: selectedProvider, option: option))
                    .font(.caption).foregroundStyle(.secondary)
                if !supported {
                    Text(L10n.string("此服務類型固定使用網域式網址；若自架服務需要 Path style，請選「其他 S3 相容服務」或 MinIO。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if option.type.lowercased() == "bool" {
                Toggle(L10n.optionHelp(providerPrefix: selectedProvider, option: option), isOn: Binding(
                    get: { values[option.name].map { $0.lowercased() == "true" } ?? (option.defaultValue == "true") },
                    set: { values[option.name] = String($0) }
                ))
                .toggleStyle(.checkbox)
            } else if (option.exclusive || selectedProvider == "s3" && option.name == "provider") && !option.examples.isEmpty {
                Picker(L10n.optionLabel(providerPrefix: selectedProvider, optionName: option.name), selection: valueBinding(option)) {
                    Text(L10n.string("選擇…")).tag("")
                    ForEach(option.examples.filter { ProviderFormPolicy.matches($0.provider ?? "", provider: formPolicy?.effectiveProvider ?? "") }, id: \.value) { example in
                        Text(L10n.optionExample(provider:selectedProvider,option:option.name,value:example.value,help:example.help)).tag(example.value)
                    }
                }
                .labelsHidden()
            } else if option.isSecret {
                SecureField(L10n.string(option.required ? "請輸入必要資訊" : (editingRemote == nil ? "選填" : "留空以保留已儲存的密碼")), text: valueBinding(option))
                    .textFieldStyle(.roundedBorder)
                if editingRemote != nil {
                    Button(L10n.string(clearedKeys.contains(option.name) ? "保留已儲存值" : "清除已儲存值")) {
                        if clearedKeys.contains(option.name) { clearedKeys.remove(option.name) }
                        else { values.removeValue(forKey: option.name); clearedKeys.insert(option.name) }
                    }.font(.caption)
                    if clearedKeys.contains(option.name) { Text(L10n.string("儲存後會清除此值")).font(.caption).foregroundStyle(.orange) }
                }
            } else {
                TextField((option.defaultValue ?? "").isEmpty ? L10n.string(option.required ? "請輸入必要資訊" : "選填") : String(format: L10n.string("預設：%@"), option.defaultValue!), text: valueBinding(option))
                    .textFieldStyle(.roundedBorder)
            }
            let help = L10n.optionHelp(providerPrefix: selectedProvider, option: option)
            if !option.help.isEmpty && option.help != help && !L10n.hasOptionHelp(providerPrefix: selectedProvider, option: option) {
                DisclosureGroup(L10n.string("服務原始技術說明（可能是英文）")) { Text(verbatim:option.help).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            if !help.isEmpty && option.type.lowercased() != "bool" {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func valueBinding(_ option: RcloneProviderOption) -> Binding<String> {
        Binding(get: { values[option.name] ?? (option.isSecret ? "" : option.defaultValue ?? "") }, set: { values[option.name] = $0; if !$0.isEmpty { clearedKeys.remove(option.name) } })
    }

    private func applyRemoteValues() {
        guard editingRemote != nil, let provider, provider.prefix == remoteBackend else { return }
        values = Dictionary(uniqueKeysWithValues: provider.options.filter { !$0.hidden && $0.type.lowercased() != "configmap" }.compactMap { option in
            guard !option.isSecret, let value = remoteConfig[option.name], !ProviderFormPolicy.isRedacted(value) else { return nil }
            return (option.name, value)
        })
    }

    private func authorizationQuestion(_ question: RcloneConfigQuestion) -> some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            Label(L10n.string("需要額外授權"), systemImage: "person.crop.circle.badge.key").font(.headline)
            if !question.error.isEmpty { Text(L10n.configurationError(question.error)).foregroundStyle(.orange) }
            Text(L10n.optionLabel(providerPrefix: selectedProvider, optionName: question.option.name)).fontWeight(.medium)
            let help = L10n.optionHelp(providerPrefix: selectedProvider, option: question.option)
            if !help.isEmpty {
                Text(.init(help)).font(.caption).foregroundStyle(.secondary)
            }
            if question.option.isSecret {
                SecureField(L10n.string("請輸入答案"), text: $questionAnswer).textFieldStyle(.roundedBorder)
            } else if question.option.exclusive && !question.option.examples.isEmpty {
                Picker(L10n.string("選擇"), selection: $questionAnswer) {
                    Text(L10n.string("選擇…")).tag("")
                    ForEach(question.option.examples, id: \.value) { example in
                        Text(L10n.optionExample(provider:selectedProvider,option:question.option.name,value:example.value,help:example.help)).tag(example.value)
                    }
                }
            } else if question.option.type.lowercased() == "bool" {
                Picker(L10n.string("請選擇"), selection: $questionAnswer) {
                    Text(L10n.string(question.option.required ? "請選擇" : "使用預設值")).tag("")
                    Text(L10n.string("是")).tag("true")
                    Text(L10n.string("否")).tag("false")
                }
            } else {
                TextField(L10n.string("請輸入答案"), text: $questionAnswer).textFieldStyle(.roundedBorder)
            }
            if question.option.help != help, !question.option.help.isEmpty {
                DisclosureGroup(L10n.string("服務原始技術說明（可能是英文）")) { Text(verbatim:question.option.help).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            Text(L10n.string("rclone 要求的 OAuth 或補充設定會逐步顯示在這裡。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(L10n.string(question.option.required ? "此項必須填寫。" : "此項可留空，使用 rclone 預設值。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}
