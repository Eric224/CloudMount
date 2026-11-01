import SwiftUI

struct VaultFolderBrowser: View {
    @ObservedObject var manager: VaultManager
    let remote: String
    let select: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path: String
    @State private var folders: [String] = []
    @State private var loading = true
    @State private var error: String?
    @State private var reload = 0

    init(manager: VaultManager, remote: String, initialPath: String, select: @escaping (String) -> Void) {
        self.manager = manager; self.remote = remote; self.select = select
        _path = State(initialValue: initialPath.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string(manager.remoteTypes[remote] == "s3" ? "選擇儲存桶或資料夾" : "選擇存放資料夾")).font(.title2.bold())
            Text(remote).font(.headline)
            HStack {
                Button(L10n.string("上一層")) { path = (path as NSString).deletingLastPathComponent }
                    .disabled(path.isEmpty || path == "/" || loading)
                Button(L10n.string("重新整理")) { reload += 1 }.disabled(loading)
                Text(path.isEmpty ? L10n.string("雲端根目錄") : path).textSelection(.enabled).lineLimit(3)
            }
            if loading { ProgressView(L10n.string("正在讀取資料夾…")) }
            List(folders, id: \.self) { name in
                Button { path = path.isEmpty ? name : path + (path.hasSuffix("/") ? "" : "/") + name } label: {
                    HStack { Label(name, systemImage: "folder"); Spacer(); Image(systemName: "chevron.right") }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }.disabled(loading)
            if let error { Text(error).foregroundStyle(.orange).font(.callout).textSelection(.enabled) }
            else if !loading && folders.isEmpty { Text(L10n.string("沒有子資料夾，可以選擇目前位置。")).foregroundStyle(.secondary) }
            if manager.remoteTypes[remote] == "webdav" {
                Text(L10n.string("NAS 請先進入有寫入權限的共用資料夾，再按「使用此資料夾」。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(L10n.string("取消")) { dismiss() }
                Spacer()
                Button(L10n.string("使用此資料夾")) { select(path); dismiss() }
                    .disabled(loading || error != nil || (manager.remoteTypes[remote] == "s3" && path.isEmpty))
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 540, height: 460)
        .task(id: "\(reload):\(path)") {
            loading = true; error = nil; folders = []
            do {
                let values = try await manager.folders(remote: remote, path: path)
                try Task.checkCancellation()
                folders = values; loading = false
            } catch {
                guard !Task.isCancelled else { return }
                self.error = L10n.error(error); loading = false
            }
        }
    }
}
