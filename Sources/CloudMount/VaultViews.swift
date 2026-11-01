import SwiftUI
import AppKit

struct VaultMenu: View {
    @ObservedObject var manager: VaultManager
    var body: some View {
        if !manager.locations.isEmpty {
            Section(L10n.string("加密保險箱")) {
                ForEach(manager.locations) { location in
                    Menu {
                        Text(manager.status(location.id))
                        if manager.isOpen(location.id) {
                            Button(L10n.string("在 Finder 開啟")) { manager.openFinder(location.id) }
                        }
                        if manager.isRunning(location.id) {
                            Button(L10n.string("鎖定保險箱")) { Task { _ = await manager.lock(location.id) } }.disabled(manager.busy)
                        }
                    } label: { Label(location.name, systemImage: manager.isOpen(location.id) ? "lock.open" : "lock") }
                }
            }
        }
    }
}

struct VaultCard: View {
    @ObservedObject var manager: VaultManager
    @ObservedObject var model: AppModel
    @State private var sheet: VaultSheetAction?
    @State private var removing: VaultLocation?
    @State private var inspecting: VaultLocation?
    @State private var deletingVault: VaultLocation?
    @State private var repairingVault: VaultLocation?
    @State private var recoveryVault: VaultLocation?
    private func showRecovery(_ location: VaultLocation) {
        Task { if await manager.prepareRecovery(location.id) { recoveryVault = location } }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(L10n.string("加密保險箱"), systemImage: "lock.shield").font(.title3.bold())
                Spacer()
                Button(L10n.string("建立保險箱")) { sheet = .create }.disabled(!manager.available)
                Button(L10n.string("加入已有保險箱")) { sheet = .join }.disabled(!manager.available)
            }
            Text(L10n.string("檔案在雲端保持加密；解鎖一次，即可在 Finder 正常使用。"))
                .font(.subheadline).foregroundStyle(.secondary)
            if !model.version.contains("cloudmount.1"), manager.locations.contains(where: { manager.remoteTypes[$0.remote] == "drime" }) {
                Text(L10n.string("Drime 目前有覆寫相容性問題：新檔可上傳，但修改既有檔案可能反覆重試。未確認上傳與鎖定完成前，請勿刪除本機快取或換電腦編輯。"))
                    .font(.caption).foregroundStyle(.orange)
            }
            if manager.locations.isEmpty {
                Text(L10n.string("另一台電腦安裝 CloudMount 後，連接同一雲端，再加入已有保險箱即可。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(manager.locations) { location in
                Divider()
                HStack(spacing: 12) {
                    Image(systemName: manager.isOpen(location.id) ? "lock.open.fill" : "lock.fill")
                        .font(.title2).foregroundStyle(manager.isOpen(location.id) ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(location.name).fontWeight(.medium)
                        Text(location.remote).font(.caption).foregroundStyle(.secondary)
                        Text(L10n.string(location.formatVersion == 8 ? "標準 Cryptomator" : "舊版測試格式")).font(.caption).foregroundStyle(.secondary)
                        Text(manager.status(location.id)).font(.caption).foregroundStyle(manager.uploadReports[location.id]?.warning == true || !manager.isOpen(location.id) ? Color.orange : Color.secondary)
                    }
                    Spacer()
                    if location.formatVersion == 8 {
                        Button(L10n.string("復原金鑰")) { showRecovery(location) }
                            .disabled(!manager.isOpen(location.id) || manager.busy)
                            .help(L10n.string("解鎖後可查看 44 詞復原金鑰。"))
                    }
                    if manager.isOpen(location.id) {
                        Button("Finder") { manager.openFinder(location.id) }
                        Button(L10n.string("上傳狀態")) { inspecting = location }
                    }
                    if manager.isRunning(location.id) {
                        if manager.canResume(location.id) { Button(L10n.string("重新解鎖")) { Task { await manager.resume(location.id) } } }
                        Button(L10n.string("鎖定")) { Task { _ = await manager.lock(location.id) } }.disabled(manager.busy)
                    } else {
                        Button(L10n.string("解鎖")) {
                            if manager.isRemembered(location.id) {
                                Task {
                                    if !(await manager.unlock(location, password: "", remember: true)), manager.shouldAskPassword(location.id) { sheet = .unlock(location) }
                                }
                            } else { sheet = .unlock(location) }
                        }.disabled(!manager.available)
                    }
                    Menu {
                        Button(L10n.string("保險箱資訊與雲端位置")) { inspecting = location }
                        Button(L10n.string("修復上傳…")) { repairingVault = location }.disabled(!manager.canRepairUploads(location.id))
                        if location.formatVersion == 8 {
                            Button(L10n.string("顯示復原詞")) { showRecovery(location) }.disabled(!manager.isOpen(location.id))
                        }
                        Button(L10n.string("匯出復原檔")) { manager.exportRecovery(location.id) }.disabled(!manager.isOpen(location.id))
                        if manager.pendingCleanup.contains(location.id) {
                            Button(L10n.string("清理舊寫入標記")) { Task { await manager.clearPendingMarker(location.id) } }
                        }
                        Toggle(L10n.string("隨 app 啟動解鎖"), isOn: Binding(get: { location.automaticUnlock }, set: { manager.setAutomatic(location.id, enabled: $0) }))
                            .disabled(!manager.isRemembered(location.id))
                        Button(L10n.string("不再記住密碼")) { manager.forgetPassword(location.id) }.disabled(!manager.isRemembered(location.id))
                        Button(L10n.string("從這台 Mac 移除"), role: .destructive) { removing = location }.disabled(manager.isRunning(location.id))
                        Divider()
                        Button(L10n.string("刪除雲端保險箱…"), role: .destructive) { deletingVault = location }
                            .disabled(manager.isRunning(location.id) || !manager.available)
                            .help(L10n.string("請先鎖定保險箱。"))
                    } label: { Image(systemName: "ellipsis.circle") }.frame(width: 48).disabled(manager.busy)
                }
            }
            if manager.busy { ProgressView(manager.progress).controlSize(.small) }
            if let error = manager.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            DisclosureGroup(L10n.string("保險箱使用說明")) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.string("所有讀寫與加密上傳會自動處理，不會因一般檔案操作再次詢問密碼。"))
                    Text(L10n.string("換電腦前請等待上傳完成並鎖定保險箱。同時使用其他電腦時，可選擇唯讀開啟。"))
                    Text(L10n.string("同一保險箱請一次只在一台電腦編輯。官方 Cryptomator 不會遵循 CloudMount 的寫入標記，請先在其他程式鎖定再開啟。"))
                    Text(L10n.string("記住密碼不會自行啟動掛載；啟動解鎖還需開啟下方的自動掛載總開關。"))
                    Text(L10n.string("本機快取可能包含解密資料，建議啟用 FileVault。雲端只會收到密文。"))
                    Text(L10n.string("新保險箱採用標準 Cryptomator 格式，可用官方 Cryptomator 開啟。換電腦時連接相同雲端、加入保險箱並輸入同一密碼即可。"))
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }
        }
        .padding(22).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .sheet(item: $sheet) { action in VaultSetupSheet(manager: manager, model: model, action: action) }
        .sheet(item: $deletingVault) { location in VaultDeleteSheet(manager: manager, location: location) }
        .sheet(item: $repairingVault) { location in VaultRepairSheet(manager: manager, location: location) }
        .sheet(item: $recoveryVault) { location in VaultRecoveryWordsSheet(manager: manager, location: location) }
        .popover(item: $inspecting) { location in
            VaultUploadDetails(manager: manager, location: location)
        }
        .confirmationDialog(L10n.string("從這台 Mac 移除保險箱？"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button(L10n.string("移除本機項目"), role: .destructive) { if let removing { Task { await manager.removeLocal(removing.id) } }; removing = nil }
            Button(L10n.string("取消"), role: .cancel) { removing = nil }
        } message: { Text(L10n.string("只移除這台電腦的清單與記住的密碼，雲端加密資料會保留。")) }
    }
}

private struct VaultUploadDetails: View {
    @ObservedObject var manager: VaultManager
    let location: VaultLocation
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(location.name).font(.headline)
            Text(manager.status(location.id)).fontWeight(.medium)
            if let report = manager.uploadReports[location.id] {
                Text(report.explanation)
                if report.queued + report.uploading + report.retrying > 0 {
                    Text(String(format: L10n.string("傳送中：%d　等待：%d　重試：%d"), report.uploading, report.queued, report.retrying))
                    if report.retryAfter > 0 {
                        Text(String(format: L10n.string("約 %d 秒後再次嘗試。"), report.retryAfter)).foregroundStyle(.secondary)
                    }
                    if report.finderSettingsOnly {
                        Text(L10n.string("待處理項目只有 Finder 顯示設定檔，不是你的文件內容。仍需通過鎖定檢查才能安全結束。"))
                    }
                }
                HStack { Text(L10n.string("最近檢查")); Text(report.checkedAt, style: .time) }.font(.caption).foregroundStyle(.secondary)
            } else if manager.isRunning(location.id) {
                Text(L10n.string("無法確認上傳狀態，請檢查連線"))
            }
            Divider()
            Text(L10n.string("雲端存放位置")).fontWeight(.medium)
            Text(location.root).font(.caption.monospaced()).textSelection(.enabled)
            if location.formatVersion == 8 {
                Text(L10n.string("使用官方 Cryptomator 時，先將整個保險箱資料夾下載到本機，再加入其中的 vault.cryptomator。保留 masterkey.cryptomator 與 d 資料夾，使用相同密碼即可解鎖。"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(L10n.string("這是舊版測試保險箱，不能用官方 Cryptomator 開啟。請建立新保險箱，再複製解鎖後的檔案；確認上傳完成並鎖定後，再決定是否移除舊保險箱。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(L10n.string("複製雲端位置")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(location.root, forType: .string)
            }
            Text(L10n.string("雲端資料夾以識別碼命名；保險箱顯示名稱存在描述檔內。另一台電腦搜尋相同位置時會顯示此名稱。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.string("從這台 Mac 移除不會刪除雲端資料。若要永久刪除，請先在各電腦鎖定並備份，再從更多選單選擇「刪除雲端保險箱」。"))
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text(L10n.string("關閉主視窗後仍會在背景上傳。要完全結束或換電腦，請先鎖定；未完成時 app 會保留快取並阻止正常結束。"))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 380)
    }
}

private struct VaultRepairSheet: View {
    @ObservedObject var manager: VaultManager
    let location: VaultLocation
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("修復上傳")).font(.title2.bold())
            Text(location.name).font(.headline)
            Text(L10n.string("請先儲存並關閉使用保險箱的檔案。CloudMount 會正常卸載、停止舊工作程序，再用內建相容引擎接回同一保險箱與快取，繼續上傳。"))
            Text(L10n.string("待上傳修改與寫入標記會保留；若無法正常卸載或確認舊程序停止，就不會建立重複掛載。"))
                .font(.caption).foregroundStyle(.secondary)
            if !manager.canRepairWithoutPassword(location.id) {
                SecureField(L10n.string("保險箱密碼"), text: $password).textFieldStyle(.roundedBorder)
            }
            if let error = manager.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if manager.busy { ProgressView(manager.progress).controlSize(.small) }
            HStack {
                Spacer()
                Button(L10n.string("取消")) { dismiss() }.disabled(manager.busy)
                Button(L10n.string("保留修改並修復上傳")) {
                    Task { if await manager.repairUploads(location.id, password: password) { password = ""; dismiss() } }
                }.disabled(manager.busy || (!manager.canRepairWithoutPassword(location.id) && password.isEmpty))
            }
        }.padding(24).frame(width: 520).interactiveDismissDisabled(manager.busy)
    }
}

private struct VaultDeleteSheet: View {
    @ObservedObject var manager: VaultManager
    let location: VaultLocation
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = ""
    @State private var acknowledged = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L10n.string("刪除雲端保險箱"), systemImage: "exclamationmark.triangle").font(.title2.bold()).foregroundStyle(.orange)
            Text(location.name).font(.headline)
            Text(L10n.string("這會刪除雲端保險箱內的所有加密檔案，其他電腦也會失去存取。復原檔只能解鎖，不能還原被刪除的資料。"))
            Text(location.root).font(.caption.monospaced()).textSelection(.enabled)
            Toggle(L10n.string("我已確認各電腦已鎖定，且需要保留的檔案已另行備份。"), isOn: $acknowledged)
            Text(L10n.string("輸入保險箱完整名稱以確認刪除。"))
            TextField(location.name, text: $confirmation).textFieldStyle(.roundedBorder)
            Text(L10n.string("刪除可能無法復原；若網路中斷，可能只完成部分刪除。"))
                .font(.caption).foregroundStyle(.secondary)
            if let error = manager.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            if manager.busy { ProgressView(manager.progress).controlSize(.small) }
            HStack {
                Spacer()
                Button(L10n.string("取消")) { dismiss() }.disabled(manager.busy)
                Button(L10n.string("刪除雲端保險箱"), role: .destructive) {
                    Task { if await manager.deleteCloud(location.id, confirmation: confirmation) { dismiss() } }
                }.disabled(manager.busy || !acknowledged || confirmation != location.name)
            }
        }.padding(24).frame(width: 520).interactiveDismissDisabled(manager.busy)
    }
}

enum VaultSheetAction: Identifiable {
    case create, join, unlock(VaultLocation)
    var id: String { switch self { case .create: return "create"; case .join: return "join"; case .unlock(let location): return location.id.uuidString } }
}

struct VaultSetupSheet: View {
    @ObservedObject var manager: VaultManager
    @ObservedObject var model: AppModel
    let action: VaultSheetAction
    @Environment(\.dismiss) private var dismiss
    @State private var remote = ""
    @State private var parent = ""
    @State private var name = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var remember = true
    @State private var readOnly = false
    @State private var exact = false
    @State private var selected: UUID?
    @State private var completed: UUID?
    @State private var advanced = false
    @State private var takeover = false
    @State private var confirmTakeover = false
    @State private var showFolderBrowser = false
    @State private var showRecoveryWords = false
    private var creating: Bool { if case .create = action { return true }; return false }
    private var joining: Bool { if case .join = action { return true }; return false }
    private var location: VaultLocation? {
        if case .unlock(let location) = action { return location }
        return manager.discoveries.first { $0.id == selected }?.location
    }
    private var title: String { L10n.string(creating ? "建立加密保險箱" : joining ? "加入已有保險箱" : "解鎖保險箱") }
    private var ready: Bool {
        !manager.busy && !password.isEmpty && (creating ? !remote.isEmpty && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && password.count >= 10 && password == confirmation : location != nil)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(completed == nil ? title : L10n.string("保險箱已準備好")).font(.title2.bold()); Spacer(); Button(L10n.string("關閉")) { password = ""; confirmation = ""; dismiss() }.disabled(manager.busy) }
            Divider()
            if let completed {
                VStack(alignment: .leading, spacing: 16) {
                    Label(L10n.string("已解鎖，可以開始使用"), systemImage: "checkmark.shield.fill").font(.headline).foregroundStyle(.green)
                    Text(L10n.string("將檔案放入開啟的 Finder 保險箱，CloudMount 會自動加密並上傳。"))
                    Text(L10n.string("建議現在保存復原檔，供遺失密碼或更換電腦時救援。日常跨電腦使用只需同一個保險箱密碼。"))
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        if manager.recoveryWords(completed) != nil {
                            Button(L10n.string("查看 44 詞復原金鑰")) { showRecoveryWords = true }
                        }
                        Button(L10n.string("儲存復原檔…")) { manager.exportRecovery(completed) }
                        Button(L10n.string("在 Finder 開啟")) { manager.openFinder(completed) }
                    }
                    if manager.recoverySaved.contains(completed) {
                        Label(L10n.string("復原檔已儲存"), systemImage: "checkmark.circle").foregroundStyle(.green)
                    }
                    if let error = manager.error { Text(error).font(.callout).foregroundStyle(.orange) }
                }.padding(.vertical, 14)
                Spacer()
                HStack { Spacer(); Button(L10n.string("完成")) { dismiss() }.keyboardShortcut(.defaultAction) }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if creating || joining {
                            Text(L10n.string("選擇雲端空間")).fontWeight(.medium)
                            Picker(L10n.string("遠端"), selection: $remote) {
                                Text(L10n.string("選擇…")).tag("")
                                ForEach(manager.supportedRemotes, id: \.self) { Text($0).tag($0) }
                            }.labelsHidden()
                            if manager.supportedRemotes.isEmpty { Text(L10n.string("請先新增 Drime、WebDAV 或 S3 相容遠端。")) }
                            if manager.remoteTypes[remote] == "s3" {
                                TextField(L10n.string("儲存桶名稱，例如 my-backup"), text: $parent).textFieldStyle(.roundedBorder)
                                Button(L10n.string("選擇資料夾…")) { showFolderBrowser = true }.disabled(remote.isEmpty)
                                Text(L10n.string("可填儲存桶名稱，或儲存桶／子資料夾。請使用與另一台電腦相同的位置。"))
                                    .font(.caption).foregroundStyle(.secondary)
                            } else if manager.remoteTypes[remote] == "webdav" {
                                Text(L10n.string("存放位置")).fontWeight(.medium)
                                HStack {
                                    Text(parent.isEmpty ? L10n.string("雲端根目錄") : parent).lineLimit(2).textSelection(.enabled)
                                    Spacer()
                                    Button(L10n.string("選擇資料夾…")) { showFolderBrowser = true }.disabled(remote.isEmpty)
                                }
                                Text(L10n.string("NAS 的最上層通常只列出共用資料夾；請選擇 home 或其他可寫入的資料夾。"))
                                    .font(.caption).foregroundStyle(.secondary)
                                DisclosureGroup(L10n.string("手動輸入存放位置"), isExpanded: $advanced) {
                                    TextField(L10n.string("留空使用雲端根目錄"), text: $parent).textFieldStyle(.roundedBorder).padding(.top, 8)
                                }
                            } else {
                                DisclosureGroup(L10n.string("指定存放資料夾（選填）"), isExpanded: $advanced) {
                                    TextField(L10n.string("留空使用雲端根目錄"), text: $parent).textFieldStyle(.roundedBorder).padding(.top, 8)
                                    Button(L10n.string("選擇資料夾…")) { showFolderBrowser = true }.disabled(remote.isEmpty)
                                }
                            }
                            if joining {
                                Toggle(L10n.string("使用完整保險箱資料夾路徑"), isOn: $exact)
                                if exact { TextField(L10n.string("保險箱資料夾路徑"), text: $parent).textFieldStyle(.roundedBorder) }
                                Button(L10n.string("尋找保險箱")) {
                                    selected = nil
                                    Task {
                                        if exact { await manager.discoverExact(remote: remote, path: parent) }
                                        else { await manager.discover(remote: remote, parent: parent) }
                                        if manager.discoveries.count == 1 { selected = manager.discoveries.first?.id }
                                    }
                                }.disabled(remote.isEmpty || manager.busy)
                                ForEach(manager.discoveries) { item in
                                    Button { selected = item.id } label: {
                                        HStack { Image(systemName: selected == item.id ? "checkmark.circle.fill" : "circle"); Text(item.envelope.name); Spacer() }.padding(10)
                                    }.buttonStyle(.bordered)
                                }
                                Text(L10n.string("找到保險箱後，輸入與第一台電腦相同的密碼即可。"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if creating {
                            TextField(L10n.string("保險箱名稱，例如私人文件"), text: $name).textFieldStyle(.roundedBorder)
                            Text(L10n.string("保險箱名稱可在雲端辨識，內部檔名與內容都會加密。"))
                                .font(.caption).foregroundStyle(.secondary)
                        } else if let location { Label(location.name, systemImage: "lock.shield").font(.headline) }
                        if creating || location != nil {
                            SecureField(L10n.string("保險箱密碼"), text: $password).textFieldStyle(.roundedBorder)
                            if creating {
                                SecureField(L10n.string("再次輸入密碼"), text: $confirmation).textFieldStyle(.roundedBorder)
                                if !confirmation.isEmpty && confirmation != password {
                                    Text(L10n.string("兩次輸入的密碼不一致。")).font(.caption).foregroundStyle(.orange)
                                }
                                Text(L10n.string("至少 10 個字元。另一台電腦也使用這個密碼。"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Toggle(L10n.string("在這台 Mac 記住密碼"), isOn: $remember)
                            Text(L10n.string("解鎖後，開啟、儲存與加密上傳都會自動處理。"))
                                .font(.caption).foregroundStyle(.secondary)
                            if !creating { Toggle(L10n.string("以唯讀開啟"), isOn: $readOnly) }
                            if !creating && !readOnly {
                                DisclosureGroup(L10n.string("另一台電腦未正常關閉？")) {
                                    VStack(alignment: .leading, spacing: 7) {
                                        Text(L10n.string("請先確認另一台電腦已停止使用且沒有待上傳修改。接管無法合併兩台電腦尚未上傳的編輯。"))
                                            .font(.caption).foregroundStyle(.secondary)
                                        Button(takeover ? L10n.string("已確認接管寫入") : L10n.string("接管舊寫入標記…")) { confirmTakeover = true }
                                    }.padding(.top, 8)
                                }
                            }
                        }
                        if let error = manager.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                        if manager.busy { ProgressView(manager.progress) }
                    }.padding(.vertical, 5)
                }.disabled(manager.busy)
                HStack {
                    if !creating {
                        Button(L10n.string("使用復原檔…")) {
                            let panel = NSOpenPanel(); panel.canChooseDirectories = false
                            guard panel.runModal() == .OK, let file = panel.url else { return }
                            let selectedRemote = location?.remote ?? remote
                            Task { if await manager.recover(remote: selectedRemote, file: file, remember: remember) { password = ""; dismiss() } }
                        }.disabled(manager.busy || (location?.remote ?? remote).isEmpty)
                    }
                    Spacer()
                    if manager.busy { Button(L10n.string("取消工作")) { manager.cancel() }.disabled(!manager.canCancel) }
                    Button(creating ? L10n.string("建立並解鎖") : L10n.string("解鎖並開啟")) {
                        Task {
                            if creating {
                                if let id = await manager.create(remote: remote, parent: parent, name: name, password: password, remember: remember) { completed = id; password = ""; confirmation = "" }
                            } else if let location {
                                if await manager.unlock(location, password: password, remember: remember, readOnly: readOnly, takeover: takeover) { password = ""; dismiss() }
                            }
                        }
                    }.disabled(!ready).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(26).frame(width: 620, height: completed == nil ? 620 : 370)
        .task {
            manager.error = nil
            await manager.prepareRemotes()
            remote = manager.supportedRemotes.contains(model.selectedRemote) ? model.selectedRemote : manager.supportedRemotes.first ?? ""
        }
        .onChange(of: remote) { _ in selected = nil; parent = ""; exact = false; manager.clearDiscoveries() }
        .onChange(of: parent) { _ in selected = nil; manager.clearDiscoveries() }
        .interactiveDismissDisabled(manager.busy)
        .sheet(isPresented: $showFolderBrowser) {
            VaultFolderBrowser(manager: manager, remote: remote, initialPath: parent) { parent = $0 }
        }
        .sheet(isPresented: $showRecoveryWords) {
            if let completed, let location = manager.locations.first(where: { $0.id == completed }) {
                VaultRecoveryWordsSheet(manager: manager, location: location)
            }
        }
        .confirmationDialog(L10n.string("確認接管寫入？"), isPresented: $confirmTakeover, titleVisibility: .visible) {
            Button(L10n.string("另一台電腦已停止使用，接管寫入"), role: .destructive) { takeover = true }
            Button(L10n.string("取消"), role: .cancel) {}
        } message: { Text(L10n.string("請勿在另一台電腦仍解鎖或仍有未上傳修改時接管，以免互相覆寫。")) }
    }
}

private struct VaultRecoveryWordsSheet: View {
    @ObservedObject var manager: VaultManager
    let location: VaultLocation
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(L10n.string("44 詞復原金鑰")).font(.title2.bold()); Spacer(); Button(L10n.string("關閉")) { dismiss() } }
            Text(location.name).font(.headline)
            Text(L10n.string("這 44 個單詞可在官方 Cryptomator 復原密碼。持有人能解鎖保險箱，請離線安全保存，不要放在同一保險箱內。"))
                .foregroundStyle(.secondary)
            if let words = manager.recoveryWords(location.id) {
                Text(words).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .padding().background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                HStack {
                    Button(L10n.string("複製復原詞")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(words, forType: .string) }
                    Button(L10n.string("儲存復原檔…")) { manager.exportRecovery(location.id) }
                }
            } else { Text(L10n.string("請先用密碼解鎖保險箱，再匯出復原檔。")) }
            Text(L10n.string("復原詞只能解鎖，不能還原已刪除或遺失的檔案。"))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 560)
    }
}
