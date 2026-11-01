import AppKit
import SwiftUI

struct MountDriverCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var support: MacFuseSupport
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L10n.string("掛載元件"), systemImage: "externaldrive.badge.checkmark").font(.title3.bold())
                Spacer()
                if support.checking { ProgressView().controlSize(.small) }
                Text(support.installationLabel).font(.caption).foregroundStyle(.secondary)
                Button(L10n.string(support.installation.usable ? "掛載設定" : "安裝 macFUSE")) { support.showSetup = true }
            }
            Text(support.description(for: model.method)).font(.subheadline)
            Text(L10n.string("這項設定同時用於一般遠端與加密保險箱，只會影響之後的新掛載。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18))
        .task { await support.refresh(helperPath: model.helperPath) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await support.refresh(helperPath: model.helperPath) }
        }
        .sheet(isPresented: $support.showSetup) { MountDriverSetup(model: model, support: support) }
    }
}

private struct MountDriverSetup: View {
    @ObservedObject var model: AppModel
    @ObservedObject var support: MacFuseSupport
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(L10n.string("掛載設定")).font(.title2.bold())
                Spacer()
                Button(L10n.string("關閉")) { support.showSetup = false }.disabled(support.preparingInstaller)
            }
            Picker(L10n.string("掛載方式"), selection: $model.method) {
                ForEach(MountMethod.preferences) { Text($0.label).tag($0) }
            }
            Text(support.description(for: model.method)).foregroundStyle(.secondary)
            Divider()
            HStack {
                Label(support.installationLabel, systemImage: support.installation.usable ? "checkmark.circle.fill" : "arrow.down.circle")
                Spacer()
                Button(L10n.string("重新檢查")) { Task { await support.confirmInstallation(helperPath: model.helperPath) } }
                    .disabled(support.checking || support.preparingInstaller)
            }
            Text(L10n.string("macFUSE FSKit 可在 macOS 26 以上使用，無須啟用核心擴充。安裝後若尚未就緒，按「設定 FSKit」，依系統畫面啟用檔案系統擴充。"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if support.installation.usable && support.installation.fsKitEnabled != true {
                Button(L10n.string("設定 FSKit")) { if model.canChangeRclone { support.setupFSKit(helperPath: model.helperPath) } }
                    .disabled(support.preparingInstaller || support.installerBlocked || !model.canChangeRclone)
            }
            Text(L10n.string("按下安裝後，CloudMount 會下載並驗證官方穩定版，再開啟 macOS 安裝程式。系統要求的管理員密碼與授權由 macOS 處理。"))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            if support.preparingInstaller {
                HStack { ProgressView().controlSize(.small); Text(support.installerMessage) }
            } else if !support.installerMessage.isEmpty {
                Text(support.installerMessage).foregroundStyle(.secondary)
            }
            if let error = support.installerError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if !model.canChangeRclone {
                Text(L10n.string("更新掛載元件前，請先卸載遠端、鎖定保險箱並等待目前工作結束。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Link(L10n.string("官方網站"), destination: MacFuseInstaller.website)
                Link(L10n.string("系統授權說明"), destination: MacFuseInstaller.instructions)
                Spacer()
                Button(L10n.string("使用 NFS")) { model.method = .nfs; support.showSetup = false }
                    .disabled(support.preparingInstaller)
                Button(L10n.string("下載並開啟安裝程式")) { if model.canChangeRclone { support.openInstaller() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(support.preparingInstaller || support.installerBlocked || !model.canChangeRclone || (support.installation.usable && support.installation.version != MacFuseInstaller.version))
            }
            Text(L10n.string("安裝完成後按「重新檢查」。CloudMount 不會自動重新掛載正在使用的空間。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(28).frame(width: 700)
        .interactiveDismissDisabled(support.preparingInstaller)
    }
}
