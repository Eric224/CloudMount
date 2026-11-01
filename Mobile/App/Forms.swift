import CloudMountMobileCore
import CloudMountVaultCore
import SwiftUI

struct RemoteForm: View {
  @ObservedObject var model: MobileModel
  @Environment(\.dismiss) private var dismiss
  @State private var servicePreset: StorageServicePreset = .webdav
  private var kind: String { servicePreset.transport }
  @State private var pcloudRegion = "US"
  @State private var connectionTask: Task<Void, Never>?
  @State private var preset = "AWS"
  @State private var bucket = ""
  @State private var s3Prefix = ""
  @State private var s3URLStyle: S3URLStyle = .path
  @State private var region = "us-east-1"
  @State private var account = ""
  @State private var access = ""
  @State private var secret = ""
  @State private var token = ""
  @State private var name = ""
  @State private var address = ""
  @State private var username = ""
  @State private var password = ""
  @State private var busy = false
  @State private var error: String?
  @State private var serverPort = ""
  @State private var serverFolder = ""
  @State private var implicitTLS = false
  @State private var plaintextAccepted = false
  @State private var verification: SSHHostVerification?
  @State private var hostKeyFingerprint: String?
  @State private var drimeWorkspace = ""
  @State private var drimeRoot = ""
  var body: some View {
    NavigationStack {
      Form {
        Picker(T("雲端服務", "云端服务", "Cloud service"), selection: $servicePreset) {
          ForEach(StorageServicePreset.allCases) { item in Text(item.name).tag(item) }
        }.accessibilityIdentifier("remoteType")
        if !servicePreset.help.isEmpty {
          Text(servicePreset.help).font(.caption).foregroundStyle(.secondary)
        }
        if let documentation = servicePreset.documentationURL {
          Link(
            T("查看服務的設定說明", "查看服务的设置说明", "Service setup instructions"), destination: documentation
          )
          .font(.caption)
        }
        TextField(T("顯示名稱（選填）", "显示名称（选填）", "Display name (optional)"), text: $name)
          .accessibilityIdentifier("remoteName")
        if kind == "WebDAV" {
          davFields
        } else if kind == "Drime" {
          drimeFields
        } else if kind == "S3" {
          s3Fields
        } else {
          fileServerFields
        }
        if let error { Text(error).foregroundStyle(.red) }
        Button(T("連接並加入「檔案」", "连接并添加到“文件”", "Connect and add to Files")) {
          connect()
        }.disabled(
          busy
            || (kind == "Drime"
              ? token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              : kind == "WebDAV"
                ? (address.isEmpty
                  || ([.pcloud, .koofr, .nextcloud, .owncloud].contains(servicePreset)
                    && (username.isEmpty || password.isEmpty)))
                : kind == "S3"
                  ? (bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || access.isEmpty || secret.isEmpty
                    || (preset == "MinIO" && address.isEmpty)
                    || (preset == "R2" && account.isEmpty)
                    || (["AWS", "B2", "Wasabi", "Spaces"].contains(preset) && region.isEmpty))
                  : (address.isEmpty || username.isEmpty || (kind == "FTP" && !plaintextAccepted)))
        )
        .accessibilityIdentifier("connectConfirm")
      }
      .disabled(busy)
      .navigationTitle(T("新增空間", "添加空间", "Connect storage"))
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(T("取消", "取消", "Cancel")) {
            connectionTask?.cancel()
            dismiss()
          }
        }
      }
      .overlay {
        if busy {
          ProgressView(T("正在驗證連線…", "正在验证连接…", "Checking connection…")).padding(24).background(
            .regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
      }
    }.interactiveDismissDisabled(busy)
      .onDisappear { connectionTask?.cancel() }
      .onChange(of: servicePreset) { _, selected in
        // Account secrets and old server context never follow a brand change.
        password = ""
        secret = ""
        token = ""
        access = ""
        username = ""
        account = ""
        bucket = ""
        s3Prefix = ""; s3URLStyle = .path
        name = ""
        error = nil
        serverPort = ""
        serverFolder = ""
        implicitTLS = false
        plaintextAccepted = false
        hostKeyFingerprint = nil
        drimeWorkspace = ""
        drimeRoot = ""
        preset = selected.s3Preset
        address = selected.defaultAddress
        pcloudRegion = "US"
        region = [.backblaze, .spaces].contains(selected) ? "" : "us-east-1"
      }
      .onChange(of: pcloudRegion) { _, value in
        guard servicePreset == .pcloud else { return }
        address = value == "EU" ? "https://ewebdav.pcloud.com/" : "https://webdav.pcloud.com/"
      }
      .onChange(of: preset) { old, value in
        guard old != value else { return }
        access = ""
        secret = ""
        token = ""
        account = ""
        bucket = ""
        s3Prefix = ""; s3URLStyle = .path
        if servicePreset == .s3 {
          address = ""
          region = "us-east-1"
        }
      }
      .onChange(of: address) { _, _ in hostKeyFingerprint = nil }
      .onChange(of: serverPort) { _, _ in hostKeyFingerprint = nil }
      .onChange(of: kind) { _, _ in hostKeyFingerprint = nil }
      .alert(
        T("確認 SFTP 伺服器", "确认 SFTP 服务器", "Verify SFTP server"),
        isPresented: Binding(get: { verification != nil }, set: { if !$0 { verification = nil } })
      ) {
        if verification?.changed == false {
          Button(T("指紋正確，連線", "指纹正确，连接", "Fingerprint matches, connect")) {
            hostKeyFingerprint = verification?.fingerprint
            verification = nil
            connect()
          }
        }
        Button(T("取消", "取消", "Cancel"), role: .cancel) { verification = nil }
      } message: {
        Text(
          (verification?.errorDescription ?? "") + "\n\n" + (verification?.host ?? "") + "\n"
            + (verification?.fingerprint ?? "") + "\n\n"
            + T(
              "可向伺服器管理員核對這組指紋。", "可向服务器管理员核对此指纹。",
              "Compare this fingerprint with your server administrator's record."))
      }
  }
  private func connect() {
    guard !busy else { return }
    busy = true
    error = nil
    connectionTask = Task {
      defer {
        busy = false
        connectionTask = nil
      }
      do {
        let location: MobileLocation
        if kind == "WebDAV" {
          let url = try servicePreset.webDAVURL(address: address, username: username)
          location = try await model.service.addWebDAV(
            name: name.isEmpty
              ? (servicePreset == .webdav ? (url.host ?? "WebDAV") : servicePreset.name) : name,
            endpoint: url, username: username,
            password: password)
        } else if kind == "Drime" {
          let workspace = drimeWorkspace.isEmpty ? 0 : Int64(drimeWorkspace)
          let root = drimeRoot.isEmpty ? nil : Int64(drimeRoot)
          guard let workspace, workspace >= 0, drimeRoot.isEmpty || (root ?? 0) > 0 else {
            throw MobileError.invalidAddress
          }
          location = try await model.service.addDrime(
            name: name.isEmpty ? "Drime" : name, token: token,
            settings: DrimeSettings(workspaceID: workspace, rootFolderID: root))
        } else if kind == "S3" {
          let resolved = try StorageServicePreset.s3Connection(
            preset: preset, address: address, region: region, account: account)
          location = try await model.service.addS3(
            name: name.isEmpty ? bucket : name, endpoint: resolved.endpoint,
            settings: S3Settings(bucket: bucket.trimmingCharacters(in: .whitespacesAndNewlines), region: resolved.region,
              prefix: s3Prefix.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/"))), urlStyle: s3URLStyle),
            credentials: S3Credentials(
              accessKey: access, secretKey: secret, sessionToken: token.isEmpty ? nil : token))
        } else {
          guard let serverKind = FileServerKind(rawValue: kind.lowercased()) else {
            throw MobileError.invalidAddress
          }
          let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
          guard
            var parts = URLComponents(
              string: value.contains("://") ? value : "\(serverKind.rawValue)://\(value)"),
            parts.scheme == serverKind.rawValue
          else { throw MobileError.invalidAddress }
          if !serverPort.isEmpty {
            guard let port = Int(serverPort), (1...65535).contains(port) else {
              throw MobileError.invalidAddress
            }
            parts.port = port
          }
          if !serverFolder.isEmpty {
            parts.path = serverFolder.hasPrefix("/") ? serverFolder : "/" + serverFolder
          }
          guard let url = parts.url else { throw MobileError.invalidAddress }
          location = try await model.service.addFileServer(
            name: name.isEmpty ? (url.host ?? kind) : name, endpoint: url,
            username: username, password: password,
            settings: FileServerSettings(
              kind: serverKind, implicitTLS: implicitTLS, hostKeyFingerprint: hostKeyFingerprint))
        }
        try await MobileEnvironment.publish(location)
        password = ""
        secret = ""
        token = ""
        await model.refresh()
        dismiss()
      } catch let value as SSHHostVerification { verification = value } catch is CancellationError {
      } catch let value as URLError where value.code == .cancelled {} catch {
        self.error = MobileMessage.describe(error)
      }
    }
  }
  private var drimeFields: some View {
    Group {
      Section {
        SecureField(T("Drime 存取權杖", "Drime 访问令牌", "Drime access token"), text: $token)
          .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier(
            "drimeToken")
        Link(
          T("開啟 Drime 建立權杖", "打开 Drime 创建令牌", "Create a token on Drime"),
          destination: URL(string: "https://app.drime.cloud/account-settings")!)
      } footer: {
        Text(
          T(
            "在 Drime「設定 → 開發者」建立個人存取權杖，授予檔案與資料夾讀寫權限，再貼到這裡。這不是網站登入密碼。權杖僅儲存在本裝置的鑰匙圈；不需要 Mac 開機。",
            "在 Drime“设置 → 开发者”创建个人访问令牌，授予文件与文件夹读写权限，再粘贴到这里。这不是网站登录密码。令牌仅保存在本设备的钥匙串；不需要 Mac 开机。",
            "In Drime Settings → Developers, create a personal access token with Files and Folders read/write access, then paste it here. This is not your website password. The token stays in this device's Keychain. Your Mac can be off."
          ))
      }
      DisclosureGroup(T("進階設定（通常不用）", "高级设置（通常不用）", "Advanced (usually unnecessary)")) {
        TextField(
          T("工作區 ID（留空使用個人空間）", "工作区 ID（留空使用个人空间）", "Workspace ID (blank for personal storage)"),
          text: $drimeWorkspace
        ).keyboardType(.numberPad).accessibilityIdentifier("drimeWorkspace")
        TextField(
          T("起始資料夾 ID（選填）", "起始文件夹 ID（选填）", "Starting folder ID (optional)"), text: $drimeRoot
        ).keyboardType(.numberPad)
        Text(
          T(
            "一般情況不用填寫。可在連線後，於建立或加入保險庫時選擇資料夾。", "通常无需填写。连接后，可在创建或添加保险库时选择文件夹。",
            "Usually leave these blank. Choose a folder when creating or adding a vault after connecting."
          )
        ).font(.caption)
      }
    }
  }
  private var fileServerFields: some View {
    Group {
      Section {
        TextField(
          T("伺服器，例如 nas.example.com", "服务器，例如 nas.example.com", "Server, e.g. nas.example.com"),
          text: $address
        )
        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
        .accessibilityIdentifier("fileServerHost")
        TextField(T("帳號", "账号", "Username"), text: $username).textInputAutocapitalization(.never)
          .autocorrectionDisabled().accessibilityIdentifier("fileServerUsername")
        SecureField(T("密碼", "密码", "Password"), text: $password).accessibilityIdentifier(
          "fileServerPassword")
      } footer: {
        Text(
          kind == "SFTP"
            ? T(
              "第一次連線需確認伺服器指紋。未指定資料夾時，使用帳號的家目錄。", "首次连接需确认服务器指纹。未指定文件夹时，使用账号的主目录。",
              "Confirm the server fingerprint on first connection. Your home folder is used by default."
            )
            : kind == "FTPS"
              ? T(
                "帳號、密碼與資料傳輸都使用 TLS 加密。", "账号、密码与数据传输均使用 TLS 加密。",
                "TLS protects your credentials and file transfers.")
              : T(
                "FTP 不加密帳號、密碼或傳輸內容。", "FTP 不加密账号、密码或传输内容。",
                "FTP sends credentials and files without transport encryption."))
      }
      if kind == "FTP" {
        Toggle(T("我了解，仍使用 FTP", "我了解，仍使用 FTP", "I understand; use FTP"), isOn: $plaintextAccepted)
          .accessibilityIdentifier("ftpAcknowledgement")
      }
      DisclosureGroup(T("進階設定（通常不用）", "高级设置（通常不用）", "Advanced (usually unnecessary)")) {
        TextField(
          T("連接埠（留空使用預設）", "端口（留空使用默认值）", "Port (leave blank for default)"), text: $serverPort
        ).keyboardType(.numberPad)
        TextField(T("起始資料夾（選填）", "起始文件夹（选填）", "Starting folder (optional)"), text: $serverFolder)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
        if kind == "FTPS" {
          Toggle(
            T("隱式 TLS（通常關閉）", "隐式 TLS（通常关闭）", "Implicit TLS (usually off)"), isOn: $implicitTLS)
        }
      }
    }
  }
  private var davFields: some View {
    Group {
      Section {
        if servicePreset == .pcloud {
          Picker(T("帳號資料區域", "账号数据区域", "Account data region"), selection: $pcloudRegion) {
            Text(T("美國", "美国", "United States")).tag("US")
            Text(T("歐洲", "欧洲", "Europe")).tag("EU")
          }.accessibilityIdentifier("pcloudRegion")
        } else if servicePreset != .koofr {
          TextField(
            servicePreset == .nextcloud || servicePreset == .owncloud
              ? "https://cloud.example.com/" : "https://nas.example.com:5006/home/", text: $address
          )
          .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
          .accessibilityIdentifier("remoteURL")
        }
      } header: {
        Text(T("WebDAV 網址", "WebDAV 地址", "WebDAV address"))
      } footer: {
        Text(
          T(
            "使用可讀寫的 HTTPS 資料夾網址，例如 home 或共用資料夾。NAS 最上層可能不能建立檔案。",
            "使用可读写的 HTTPS 文件夹地址，例如 home 或共享文件夹。NAS 最上层可能不能创建文件。",
            "Use a writable HTTPS folder URL, such as home or a shared folder. NAS roots may be read-only."
          ))
      }
      Section {
        TextField(T("帳號", "账号", "Username"), text: $username).textContentType(.username)
          .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier(
            "remoteUsername")
        SecureField(T("密碼／應用程式密碼", "密码／应用专用密码", "Password / app password"), text: $password)
          .textContentType(.password).accessibilityIdentifier("remotePassword")
      }
    }
  }
  private var s3Fields: some View {
    Group {
      if servicePreset == .s3 {
        Picker(T("服務", "服务", "Service"), selection: $preset) {
          Text("Amazon S3").tag("AWS")
          Text(T("MinIO／S3 相容服務", "MinIO／S3 兼容服务", "MinIO / S3-compatible")).tag("MinIO")
          Text("Cloudflare R2").tag("R2")
        }.accessibilityIdentifier("s3Preset")
      }
      if preset == "MinIO" {
        TextField(T("HTTPS 伺服器網址", "HTTPS 服务器地址", "HTTPS server address"), text: $address)
          .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
          .accessibilityIdentifier("s3Endpoint")
      }
      if preset == "R2" {
        TextField(
          T("Cloudflare 帳戶 ID", "Cloudflare 账户 ID", "Cloudflare account ID"), text: $account
        ).textInputAutocapitalization(.never).autocorrectionDisabled()
          .accessibilityIdentifier("s3Account")
      }
      TextField(T("儲存桶名稱（必填）", "存储桶名称（必填）", "Bucket name (required)"), text: $bucket).textInputAutocapitalization(
        .never
      ).autocorrectionDisabled().accessibilityIdentifier("s3Bucket")
      if ["AWS", "B2", "Wasabi", "Spaces"].contains(preset) {
        TextField(T("儲存桶所在區域", "存储桶所在区域", "Bucket region"), text: $region)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
          .accessibilityIdentifier("s3Region")
      }
      TextField(T("存取金鑰 ID", "访问密钥 ID", "Access key ID"), text: $access)
        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier(
          "s3AccessKey")
      SecureField(T("秘密存取金鑰", "秘密访问密钥", "Secret access key"), text: $secret)
        .accessibilityIdentifier("s3SecretKey")
      Text(
        T(
          "請使用具有此儲存桶讀寫權限的 S3 金鑰，不是網站登入密碼。", "请使用具有此存储桶读写权限的 S3 密钥，不是网站登录密码。",
          "Use S3 keys with read/write access to this bucket, rather than your website login password."
        )
      ).font(.caption).foregroundStyle(.secondary)
      Text(
        T(
          "會在此儲存桶建立並移除小型測試檔，確認安全讀寫；無法確認時以唯讀方式連線。", "会在此存储桶创建并移除小型测试文件，确认安全读写；无法确认时以只读方式连接。",
          "Small test files are created and removed in this bucket to verify safe writes. If verification fails, the connection stays read-only."
        )
      ).font(.caption).foregroundStyle(.secondary)
      DisclosureGroup(T("進階設定（通常不用）", "高级设置（通常不用）", "Advanced (usually unnecessary)")) {
        TextField(T("路徑前綴（選填）", "路径前缀（选填）", "Path prefix (optional)"), text: $s3Prefix)
          .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("s3Prefix")
        Text(T("留空使用整個儲存桶，例如 photos/旅行。", "留空使用整个存储桶，例如 photos/旅行。", "Leave blank for the whole bucket, for example photos/travel."))
          .font(.caption).foregroundStyle(.secondary)
        Picker(T("URL 風格", "URL 风格", "URL style"), selection: $s3URLStyle) {
          Text(T("路徑式（通常使用）", "路径式（通常使用）", "Path (recommended)")).tag(S3URLStyle.path)
          Text(T("網域式", "域名式", "Virtual hosted")).tag(S3URLStyle.virtualHosted)
        }.accessibilityIdentifier("s3URLStyle")
        Text(s3URLStyle == .path ? "https://endpoint/bucket/key" : "https://bucket.endpoint/key")
          .font(.caption).foregroundStyle(.secondary)
        if preset == "MinIO" {
          TextField(
            T("區域（預設 us-east-1）", "区域（默认 us-east-1）", "Region (default us-east-1)"), text: $region
          ).textInputAutocapitalization(.never)
        }
        SecureField(T("臨時工作階段憑證（選填）", "临时会话凭证（选填）", "Session token (optional)"), text: $token)
      }
    }
  }

}
struct VaultForm: View {
  enum Mode: String, Identifiable {
    case create, existing
    var id: String { rawValue }
  }
  @ObservedObject var model: MobileModel
  let mode: Mode
  @Environment(\.dismiss) private var dismiss
  @State private var connection: UUID?
  @State private var parent = ""
  @State private var name = ""
  @State private var path = ""
  @State private var password = ""
  @State private var confirmation = ""
  @State private var remember = false
  @State private var busy = false
  @State private var error: String?
  @State private var folders = false
  @State private var discoveries:
    [(path: String, descriptor: CloudMountVaultCore.VaultDescriptor)] = []
  private var availableConnections: [MobileConnection] {
    model.config.connections.filter {
      mode == .existing || !model.readOnlyConnections.contains($0.id)
    }
  }
  var body: some View {
    NavigationStack {
      Form {
        if availableConnections.isEmpty {
          Text(
            T(
              "請先新增雲端空間，再建立或加入保險庫。", "请先添加云端空间，再创建或添加保险库。",
              "Connect cloud storage before creating or adding a vault."))
          if !model.config.connections.isEmpty {
            Text(
              T(
                "目前空間為唯讀，請先在首頁重新檢查寫入支援。", "当前空间为只读，请先在首页重新检查写入支持。",
                "Your storage is read-only. Recheck write support on the home screen first."))
          }
        } else {
          Section {
            Picker(T("雲端空間", "云端空间", "Cloud storage"), selection: $connection) {
              ForEach(availableConnections) { Text($0.name).tag(Optional($0.id)) }
            }
            Button {
              folders = true
            } label: {
              LabeledContent(
                T("存放資料夾", "存放文件夹", "Storage folder"),
                value: parent.isEmpty ? T("目前空間的最上層", "当前空间的最上层", "Storage root") : parent)
            }
          }
          if mode == .create {
            TextField(T("保險庫名稱（支援中文）", "保险库名称（支持中文）", "Vault name (any language)"), text: $name)
              .accessibilityIdentifier("vaultName")
          } else {
            Button(T("搜尋這個資料夾的保險庫", "搜索此文件夹的保险库", "Find vaults in this folder")) {
              guard let connection else { return }
              busy = true
              error = nil
              Task {
                defer { busy = false }
                do {
                  discoveries = try await model.service.discover(
                    connectionID: connection, parent: parent)
                } catch { self.error = MobileMessage.describe(error) }
              }
            }
            ForEach(discoveries, id: \.path) { found in
              Button {
                path = found.path
              } label: {
                HStack {
                  Text(found.path)
                  Spacer()
                  if path == found.path { Image(systemName: "checkmark") }
                }
              }
            }
            DisclosureGroup(T("手動指定保險庫路徑", "手动指定保险库路径", "Enter vault path manually")) {
              TextField(
                T("相對路徑，例如：私人/保險庫", "相对路径，例如：私人/保险库", "Relative path, e.g. Private/Vault"),
                text: $path
              ).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
          }
          Section {
            SecureField(T("保險庫密碼", "保险库密码", "Vault password"), text: $password).textContentType(
              mode == .create ? .newPassword : .password
            ).accessibilityIdentifier("vaultPassword")
            if mode == .create {
              SecureField(T("再次輸入密碼", "再次输入密码", "Confirm password"), text: $confirmation)
                .textContentType(.newPassword).accessibilityIdentifier("vaultPasswordConfirm")
              Text(
                T(
                  "至少 10 個字元。Mac、iPhone、iPad 都使用同一個密碼。", "至少 10 个字符。Mac、iPhone、iPad 都使用同一个密码。",
                  "At least 10 characters. Use the same password on Mac, iPhone, and iPad.")
              ).font(.caption)
            }
            Toggle(T("在這台裝置記住密碼", "在这台设备记住密码", "Remember on this device"), isOn: $remember)
          }
          if let error { Text(error).foregroundStyle(.red) }
          Button(
            mode == .create
              ? T("建立並解鎖", "创建并解锁", "Create and unlock") : T("加入並解鎖", "添加并解锁", "Add and unlock")
          ) { submit() }
          .disabled(
            busy || connection == nil || password.isEmpty
              || (mode == .create
                && (name.isEmpty || password.count < 10 || password != confirmation))
              || (mode == .existing && path.isEmpty)
          )
          .accessibilityIdentifier("vaultConfirm")
        }
      }
      .navigationTitle(
        mode == .create
          ? T("建立保險庫", "创建保险库", "Create vault") : T("加入現有保險庫", "添加现有保险库", "Add existing vault")
      )
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(T("取消", "取消", "Cancel")) { dismiss() }.disabled(busy)
        }
      }
      .overlay {
        if busy {
          ProgressView(T("正在處理…", "正在处理…", "Working…")).padding(24).background(
            .regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
      }
      .onAppear { connection = availableConnections.first?.id }
      .sheet(isPresented: $folders) {
        if let connection { FolderPicker(model: model, connection: connection, parent: $parent) }
      }
    }.interactiveDismissDisabled(busy)
  }
  private func submit() {
    guard let connection, !busy else { return }
    busy = true
    error = nil
    Task {
      defer { busy = false }
      do {
        let location: MobileLocation
        if mode == .create {
          let result = try await model.service.createVault(
            connectionID: connection, parent: parent, name: name, password: password,
            remember: remember)
          location = result.0
          model.recovery = result.1
        } else {
          location = try await model.service.importVault(
            connectionID: connection, path: path, password: password, remember: remember)
        }
        try await MobileEnvironment.publish(location)
        password = ""
        confirmation = ""
        await model.refresh()
        dismiss()
      } catch { self.error = MobileMessage.describe(error) }
    }
  }
}
struct FolderPicker: View {
  @ObservedObject var model: MobileModel
  let connection: UUID
  @Binding var parent: String
  @Environment(\.dismiss) private var dismiss
  @State private var path = ""
  @State private var entries: [CipherItem] = []
  @State private var error: String?
  @State private var loading = false
  var body: some View {
    NavigationStack {
      List {
        Text(path.isEmpty ? "/" : path).font(.caption).foregroundStyle(.secondary)
        if !path.isEmpty {
          Button(T("上一層", "上一级", "Up one folder")) {
            path = path.split(separator: "/").dropLast().joined(separator: "/")
            load()
          }
        }
        ForEach(entries, id: \.name) { folder in
          Button {
            path = (try? MobilePath.join(path, folder.name)) ?? path
            load()
          } label: {
            Label(folder.name, systemImage: "folder")
          }
        }
        if let error { Text(error).foregroundStyle(.red) }
      }.navigationTitle(T("選擇資料夾", "选择文件夹", "Choose folder"))
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button(T("取消", "取消", "Cancel")) { dismiss() }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button(T("使用此資料夾", "使用此文件夹", "Use this folder")) {
              parent = path
              dismiss()
            }.disabled(loading || error != nil)
          }
        }
        .overlay { if loading { ProgressView() } }
        .onAppear {
          path = parent
          load()
        }
    }
  }
  private func load() {
    loading = true
    error = nil
    Task {
      defer { loading = false }
      do {
        entries = try await model.service.remoteFolders(connectionID: connection, parent: path)
      } catch { self.error = MobileMessage.describe(error) }
    }
  }
}
