import CloudMountMobileCore
import FileProvider
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

@main
struct CloudMountMobileApp: App {
  var body: some Scene { WindowGroup { HomeView().environment(\.locale, MobileText.locale) } }
}

@MainActor final class MobileModel: ObservableObject {
  @Published var config = MobileConfiguration()
  @Published var unlocked: Set<UUID> = []
  @Published var error: String?
  @Published var pendingCounts: [UUID: Int] = [:]
  @Published var drimeStatus: [UUID: DrimeMaintenanceStatus] = [:]
  @Published var providerHealth: [UUID: MobileProviderHealth] = [:]
  @Published var readOnlyConnections: Set<UUID> = []
  @Published var pendingWriteCheckCleanup: Set<UUID> = []
  @Published var busy = false
  @Published var recovery: String?
  var service: MobileService { get throws { try MobileEnvironment.service() } }
  func refresh() async {
    do {
      config = try await service.configuration()
      readOnlyConnections = Set(
        try config.connections.filter { try service.connectionIsReadOnly($0.id) }.map(\.id))
      pendingWriteCheckCleanup = Set(
        try config.connections.filter { try service.pendingS3WriteCheckCleanup($0.id) }.map(\.id))
      providerHealth = try Dictionary(
        uniqueKeysWithValues: config.locations.compactMap { value in
          try service.providerHealth(value.id).map { (value.id, $0) }
        })
      pendingCounts = Dictionary(
        uniqueKeysWithValues: try config.locations.map {
          ($0.id, try service.repository.pending($0.id).count)
        })
      drimeStatus = try Dictionary(
        uniqueKeysWithValues: config.connections.filter { $0.drime != nil }.map {
          (
            $0.id,
            try DrimeStore.maintenanceStatus(repository: service.repository, connectionID: $0.id)
          )
        })
      unlocked = Set(
        try config.locations.filter { value in
          guard value.isVault else { return false }
          return try service.isUnlocked(value.id)
        }.map(\.id))
    } catch { self.error = MobileMessage.describe(error) }
  }
  func run(_ work: @escaping () async throws -> Void) {
    guard !busy else { return }
    busy = true
    Task {
      defer { busy = false }
      do {
        try await work()
      } catch { self.error = MobileMessage.describe(error) }
      await refresh()
    }
  }
}
struct HomeView: View {
  @StateObject var model = MobileModel()
  @State private var showAbout = false
  @State private var addRemote = false
  @State private var vaultMode: VaultForm.Mode?
  @State private var unlock: MobileLocation?
  @State private var deleting: MobileLocation?
  @State private var editingConnection: MobileConnection?
  @State private var removingConnection: MobileConnection?
  @State private var fileBrowser = false
  @State private var preview: URL?
  @Environment(\.scenePhase) private var scenePhase
  var body: some View {
    NavigationStack {
      List {
        Section {
          Label(
            T("在「檔案」中使用你的雲端", "在“文件”中使用你的云端", "Your cloud, inside Files"),
            systemImage: "externaldrive.connected.to.line.below"
          ).font(.headline)
          Text(
            T(
              "連接空間後，到「檔案 → 瀏覽 → 位置」開啟 CloudMount。", "连接空间后，到“文件 → 浏览 → 位置”打开 CloudMount。",
              "After connecting, open Files → Browse → Locations and enable CloudMount.")
          ).foregroundStyle(.secondary)
          Button(T("瀏覽檔案", "浏览文件", "Browse files"), systemImage: "folder") { fileBrowser = true }
            .accessibilityIdentifier("openFiles")
        }
        Section(T("雲端空間", "云端空间", "Cloud storage")) {
          ForEach(model.config.locations.filter { !$0.isVault && $0.removedPath == nil }) {
            location in
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Label(location.name, systemImage: "externaldrive")
                Spacer()
                Button(T("登入設定", "登录设置", "Sign-in settings")) {
                  editingConnection = model.config.connections.first {
                    $0.id == location.connectionID
                  }
                }.font(.caption)
                Button(role: .destructive) {
                  removingConnection = model.config.connections.first {
                    $0.id == location.connectionID
                  }
                } label: {
                  Image(systemName: "trash")
                }
                .accessibilityLabel(
                  T("移除 \(location.name)", "移除 \(location.name)", "Remove \(location.name)")
                )
                .accessibilityIdentifier("removeConnection-\(location.connectionID)")
              }.buttonStyle(.borderless)
              if model.readOnlyConnections.contains(location.connectionID) {
                Text(
                  T(
                    "唯讀：此服務尚未通過安全寫入檢查。可瀏覽與下載；通過檢查後才能編輯或建立保險庫。",
                    "只读：此服务尚未通过安全写入检查。可浏览与下载；通过检查后才能编辑或创建保险库。",
                    "Read-only: safe writes have not been verified. You can browse and download. Editing and vault creation require a successful check."
                  )
                )
                .font(.caption).foregroundStyle(.orange)
                Text(
                  T(
                    "檢查會建立並移除小型測試檔。", "检查会创建并移除小型测试文件。",
                    "The check creates and removes small test files.")
                ).font(.caption).foregroundStyle(.secondary)
                if model.pendingWriteCheckCleanup.contains(location.connectionID) {
                  Text(
                    T(
                      "有一個 .cloudmount-write-check 測試檔尚未移除。修正刪除權限後重新檢查即可清理。",
                      "有一个 .cloudmount-write-check 测试文件尚未移除。修正删除权限后重新检查即可清理。",
                      "A .cloudmount-write-check test file could not be removed. Restore delete permission and recheck to clean it up."
                    )
                  ).font(.caption).foregroundStyle(.orange)
                }
                Button(T("重新檢查寫入支援", "重新检查写入支持", "Recheck write support")) {
                  model.run {
                    try await MobileEnvironment.recheckWriteSupport(location.connectionID)
                  }
                }.font(.caption).buttonStyle(.borderless)
              }
              if location.suspended == true {
                Label(
                  T("已卸載，設定已保留", "已卸载，设置已保留", "Disconnected; settings saved"),
                  systemImage: "pause.circle"
                ).font(.caption).foregroundStyle(.secondary)
                Button(T("連接至「檔案」", "连接到“文件”", "Connect to Files")) {
                  model.run { try await MobileEnvironment.resume(location) }
                }
                .accessibilityIdentifier("resumeLocation-\(location.id)")
              } else {
                Button(T("卸載", "卸载", "Disconnect")) {
                  model.run { try await MobileEnvironment.suspend(location) }
                }
                .font(.caption).buttonStyle(.borderless).accessibilityIdentifier(
                  "suspendLocation-\(location.id)")
                ConnectionHealthNotice(
                  location: location, health: model.providerHealth[location.id], model: model)
              }
              if let count = model.pendingCounts[location.id], count > 0 {
                HStack {
                  Text(
                    T(
                      "有 \(count) 個檔案等待上傳", "有 \(count) 个文件等待上传", "\(count) files waiting to upload"
                    )
                  ).font(.caption).foregroundStyle(.orange)
                  Button(T("重試上傳", "重试上传", "Retry uploads")) {
                    model.run {
                      try await MobileEnvironment.retryUploads(location)
                    }
                  }.font(.caption).buttonStyle(.borderless)
                }
              }
              if let status = model.drimeStatus[location.connectionID],
                status.retainedPreviousVersions + status.pendingMultipartSessions > 0
              {
                let count = status.retainedPreviousVersions + status.pendingMultipartSessions
                Text(
                  T(
                    "有 \(count) 個保留的暫存項目或舊版本待清理。",
                    "有 \(count) 个保留的临时项目或旧版本待清理。",
                    "\(count) retained staging items or previous versions await cleanup."
                  )
                ).font(.caption).foregroundStyle(.secondary)
                Button(T("重試清理", "重试清理", "Retry cleanup")) {
                  model.run { try await model.service.retryDrimeMaintenance(location.connectionID) }
                }.font(.caption).buttonStyle(.borderless)
              }
            }
          }
          Button(T("新增雲端空間", "添加云端空间", "Connect cloud storage"), systemImage: "plus") {
            addRemote = true
          }.accessibilityIdentifier("addRemote")
          Text(T("卸載只會暫時移除本裝置「檔案」中的位置，會保留設定與雲端檔案。", "卸载只会暂时移除本设备“文件”中的位置，会保留设置与云端文件。", "Disconnect temporarily removes this device's Files location. Settings and cloud files are kept.")).font(.caption).foregroundStyle(.secondary)
        }
        Section {
          ForEach(model.config.locations.filter { $0.isVault && $0.removedPath == nil }) {
            location in
            VStack(alignment: .leading, spacing: 10) {
              Label(
                location.name,
                systemImage: model.unlocked.contains(location.id) ? "lock.open.fill" : "lock.fill"
              ).font(.headline)
              Text(
                model.unlocked.contains(location.id)
                  ? T("已解鎖 · 可在檔案 App 使用", "已解锁 · 可在文件 App 使用", "Unlocked · Available in Files")
                  : T("已上鎖", "已上锁", "Locked")
              ).font(.caption).foregroundStyle(.secondary)
              if location.suspended == true {
                Text(
                  T(
                    "已從「檔案」卸載；再次解鎖即可連接。", "已从“文件”卸载；再次解锁即可连接。",
                    "Disconnected from Files. Unlock to reconnect.")
                ).font(.caption).foregroundStyle(.secondary)
              }
              if location.suspended != true, let health = model.providerHealth[location.id],
                health.issue.isWarning
              {
                ConnectionHealthNotice(location: location, health: health, model: model)
              }
              if let count = model.pendingCounts[location.id], count > 0 {
                Text(
                  T("有 \(count) 個檔案等待上傳", "有 \(count) 个文件等待上传", "\(count) files waiting to upload")
                ).font(.caption).foregroundStyle(.orange)
              }
              HStack {
                if model.unlocked.contains(location.id) {
                  Button(T("卸載", "卸载", "Disconnect")) {
                    model.run { try await MobileEnvironment.suspend(location) }
                  }
                  .accessibilityIdentifier("suspendLocation-\(location.id)")
                  Button(T("上鎖", "上锁", "Lock")) {
                    model.run { try await MobileEnvironment.lock(location) }
                  }
                  Button(T("復原金鑰", "恢复密钥", "Recovery key")) {
                    model.run { model.recovery = try await model.service.recovery(location.id) }
                  }
                } else {
                  if location.suspended != true {
                    Button(T("卸載", "卸载", "Disconnect")) {
                      model.run { try await MobileEnvironment.suspend(location) }
                    }
                    .accessibilityIdentifier("suspendLocation-\(location.id)")
                  }
                  Button(
                    location.suspended == true
                      ? T("連接並解鎖", "连接并解锁", "Connect and unlock") : T("解鎖", "解锁", "Unlock")
                  ) { unlock = location }
                  Button(T("刪除", "删除", "Delete"), role: .destructive) { deleting = location }
                    .disabled(
                      model.readOnlyConnections.contains(location.connectionID)
                        || location.suspended == true)
                }
                if (model.pendingCounts[location.id] ?? 0) > 0 {
                  Button(T("重試上傳", "重试上传", "Retry uploads")) {
                    model.run {
                      try await MobileEnvironment.retryUploads(location)
                    }
                  }
                }
              }.buttonStyle(.bordered)
            }.padding(.vertical, 6)
          }
          Button(T("建立保險庫", "创建保险库", "Create vault"), systemImage: "lock.rectangle.stack") {
            vaultMode = .create
          }.accessibilityIdentifier("createVault")
          Button(T("加入現有保險庫", "添加现有保险库", "Add existing vault"), systemImage: "lock.rectangle.stack")
          { vaultMode = .existing }.accessibilityIdentifier("importVault")
        } header: {
          Text(T("加密保險庫", "加密保险库", "Encrypted vaults"))
        } footer: {
          Text(
            T(
              "密碼輸入一次即可持續使用。上鎖前會確認上傳並清除可撤回的本機快取；已匯出到其他 App 的副本不受影響。",
              "密码输入一次即可持续使用。上锁前会确认上传并清除可撤回的本机缓存；已导出到其他 App 的副本不受影响。",
              "Enter your password once per unlock session. Locking checks uploads and evicts cached files. Copies exported to other apps remain outside the vault."
            ))
        }
        let removed = model.config.locations.filter { $0.removedPath != nil }
        if !removed.isEmpty {
          Section(T("已刪除的保險庫", "已删除的保险库", "Deleted vaults")) {
            ForEach(removed) { location in
              HStack {
                Text(location.name)
                Spacer()
                Button(T("復原", "恢复", "Restore")) {
                  model.run {
                    try await model.service.restoreVault(location.id)
                    try await MobileEnvironment.publish(location)
                  }
                }
              }
            }
          }
        }
      }
      .navigationTitle("CloudMount")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            showAbout = true
          } label: {
            Image(systemName: "info.circle")
          }
          .accessibilityLabel(T("關於 CloudMount", "关于 CloudMount", "About CloudMount"))
          .accessibilityIdentifier("openAbout")
        }
      }
      .sheet(isPresented: $showAbout) { AboutView().environment(\.locale, MobileText.locale) }
      .disabled(model.busy)
      .overlay {
        if model.busy {
          ProgressView(T("正在處理…", "正在处理…", "Working…")).padding(24).background(
            .regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
      }
      .refreshable { await model.refresh() }
      .task { await model.refresh() }
      .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await model.refresh() } }
      }
      .fileImporter(isPresented: $fileBrowser, allowedContentTypes: [.item]) { result in
        do {
          let url = try result.get()
          guard url.startAccessingSecurityScopedResource() else { throw MobileError.credential }
          preview = url
        } catch { model.error = MobileMessage.describe(error) }
      }
      .quickLookPreview($preview)
      .onChange(of: preview) { old, new in
        if old != new { old?.stopAccessingSecurityScopedResource() }
      }
      .sheet(item: $editingConnection) { connection in
        CredentialsView(connection: connection, completion: { await model.refresh() })
      }
      .sheet(isPresented: $addRemote) { RemoteForm(model: model) }
      .sheet(item: $vaultMode) { VaultForm(model: model, mode: $0) }
      .sheet(item: $unlock) { UnlockView(location: $0, completion: { await model.refresh() }) }
      .sheet(
        isPresented: Binding(
          get: { model.recovery != nil },
          set: { if !$0 { Task { @MainActor in model.recovery = nil } } })
      ) {
        NavigationStack {
          ScrollView {
            VStack(alignment: .leading, spacing: 20) {
              Text(T("44 詞復原金鑰", "44 词恢复密钥", "44-word recovery key")).font(.title2.bold())
              Text(
                T(
                  "請離線保存。任何持有這組詞的人都能解密保險庫，請勿傳給他人。", "请离线保存。任何持有这组词的人都能解密保险库，请勿传给他人。",
                  "Keep this offline. Anyone with these words can decrypt your vault. Do not share them."
                ))
              Text(model.recovery ?? "").font(.system(.body, design: .monospaced)).textSelection(
                .enabled)
            }.padding()
          }.toolbar { Button(T("完成", "完成", "Done")) { model.recovery = nil } }
        }
      }
      .alert(
        T("無法完成操作", "无法完成操作", "Could not complete"),
        isPresented: Binding(
          get: { model.error != nil }, set: { if !$0 { Task { @MainActor in model.error = nil } } })
      ) {
        Button(T("確定", "确定", "OK"), role: .cancel) { model.error = nil }
      } message: {
        Text(model.error ?? "")
      }
      .confirmationDialog(
        T("移除此裝置的雲端空間？", "移除此设备的云端空间？", "Remove cloud storage from this device?"),
        isPresented: Binding(
          get: { removingConnection != nil }, set: { if !$0 { removingConnection = nil } }),
        titleVisibility: .visible
      ) {
        Button(T("移除連線", "移除连接", "Remove connection"), role: .destructive) {
          guard let connection = removingConnection else { return }
          removingConnection = nil
          model.run { try await MobileEnvironment.removeConnection(connection) }
        }
      } message: {
        Text(
          T(
            "會移除此裝置的連線、登入資料與相關保險庫入口。雲端檔案與保險庫保留，其他裝置不受影響。有待上傳檔案時會先停止移除。",
            "会移除此设备的连接、登录信息与相关保险库入口。云端文件与保险库保留，其他设备不受影响。有待上传文件时会先停止移除。",
            "Removes this device's connection, credentials and related vault locations. Cloud files and vaults stay intact. Other devices are unaffected. Pending uploads must finish first."
          ))
      }
      .confirmationDialog(
        T("刪除保險庫？", "删除保险库？", "Delete vault?"),
        isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
        titleVisibility: .visible
      ) {
        Button(T("移到可復原的刪除區", "移到可恢复的删除区", "Move to recoverable deleted area"), role: .destructive)
        {
          guard let location = deleting else { return }
          deleting = nil
          model.run {
            try await NSFileProviderManager.remove(MobileEnvironment.domain(location))
            do { try await model.service.trashVault(location.id) } catch {
              try? await MobileEnvironment.publish(location)
              throw error
            }
          }
        }
      } message: {
        Text(
          T(
            "雲端的整個保險庫會移到同層刪除資料夾，可從本 App 復原；不會清除其他檔案。", "云端的整个保险库会移到同层删除文件夹，可从本 App 恢复；不会清除其他文件。",
            "The entire encrypted vault will move to a recoverable folder beside its current location. Other files are unaffected."
          ))
      }
    }
  }
}
