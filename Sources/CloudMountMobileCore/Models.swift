import CloudMountVaultCore
import CloudMountLocalization
import Foundation

public enum MobileError: Error, LocalizedError {
  case forbidden, locked, busy, invalidAddress, invalidName, unsupported, missing, conflict
  case network(Int)
  case credential, incomplete, quota, deviceLocked, vaultMemoryLimit, unsafeWrites, expiredPage
  public var errorDescription: String? {
    switch self {
    case .expiredPage:
      return MobileText.text("清單已更新，請重新整理。", "列表已更新，请刷新。", "The list changed. Refresh and try again.")
    case .vaultMemoryLimit:
      return MobileText.text("這個保險庫需要的解鎖記憶體超過行動版限制。請先在 Mac 使用；保險庫不會被變更。", "此保险库的解锁内存需求超过移动版限制。请先在 Mac 使用；保险库不会被更改。", "This vault requires more unlock memory than the mobile limit. Use it on your Mac; the vault is not changed.")
    case .unsafeWrites:
      return MobileText.text("未能確認此服務支援安全寫入，已保留唯讀存取。請在首頁重新檢查寫入支援。", "未能确认此服务支持安全写入，已保留只读访问。请在首页重新检查写入支持。", "Safe writes could not be verified for this service. Read-only access is available. Recheck write support on the home screen.")
    case .forbidden:
      return MobileText.text(
        "沒有存取這個資料夾的權限，請選擇有讀寫權限的位置。", "没有访问此文件夹的权限，请选择有读写权限的位置。",
        "You do not have permission to access this folder. Choose a location with read/write access."
      )
    case .locked: return MobileText.text("請先解鎖保險庫。", "请先解锁保险库。", "Unlock the vault first.")
    case .busy:
      return MobileText.text(
        "還有檔案正在處理或等待上傳，請稍後再試。", "还有文件正在处理或等待上传，请稍后再试。",
        "Files are still being processed or waiting to upload. Try again later.")
    case .invalidAddress:
      return MobileText.text(
        "請檢查伺服器網址與連線設定。", "请检查服务器地址与连接设置。",
        "Check the server address and connection settings.")
    case .invalidName:
      return MobileText.text(
        "請輸入名稱，且不能包含 /、. 或 .. 路徑。", "请输入名称，且不能包含 /、. 或 .. 路径。",
        "Enter a name without slashes or relative path components.")
    case .unsupported:
      return MobileText.text(
        "目前無法處理這種檔案或操作。", "目前无法处理这种文件或操作。", "This file type or operation is not supported yet.")
    case .missing:
      return MobileText.text(
        "找不到檔案，請重新整理。", "找不到文件，请刷新。", "The item was not found. Refresh and try again.")
    case .conflict:
      return MobileText.text(
        "檔案已在別處變更。已保留本機修改，請先處理衝突。", "文件已在别处更改。已保留本机修改，请先处理冲突。",
        "The file changed elsewhere. Your local edit is preserved; resolve the conflict first.")
    case .network(let status):
      return MobileText.text(
        "連線未完成（\(status)），請檢查網路與伺服器。", "连接未完成（\(status)），请检查网络与服务器。",
        "The request failed (\(status)). Check your network and server.")
    case .credential:
      return MobileText.text(
        "雲端登入資料無效或已失效，請在登入設定更新。", "云端登录信息无效或已失效，请在登录设置更新。", "Your cloud credentials are invalid or expired. Update the sign-in settings.")
    case .deviceLocked:
      return MobileText.text("請先解鎖這台裝置，再回到「檔案」繼續。雲端登入資料不需要重新輸入。", "请先解锁此设备，再回到“文件”继续。无需重新输入云端登录信息。", "Unlock this device, then return to Files. You do not need to enter your cloud credentials again.")
    case .incomplete:
      return MobileText.text(
        "資料不完整，已停止操作以保護檔案。", "数据不完整，已停止操作以保护文件。",
        "The data is incomplete. The operation stopped to protect your files.")
    case .quota:
      return MobileText.text("本機或雲端空間不足。", "本机或云端空间不足。", "The device or cloud storage is full.")
    }
  }
}

public enum MobileText {
  public static var locale: Locale { AppLanguage.current.locale }
  public static func text(_ traditional: String, _ simplified: String, _ english: String) -> String
  {
    AppLanguage.current.choose(traditional,simplified,english)
  }
}

public enum MobilePath {
  public static func checked(_ path: String) throws -> String {
    guard !path.hasPrefix("/"), !path.contains("\\"),
      !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { throw MobileError.invalidName }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard path.isEmpty || !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
      components.count <= 128
    else { throw MobileError.invalidName }
    return path
  }
  public static func name(_ text: String) throws -> String {
    let value = try checked(text)
    guard !value.isEmpty, !value.contains("/"), value.utf8.count <= 255 else {
      throw MobileError.invalidName
    }
    return value
  }
  public static func join(_ parent: String, _ name: String) throws -> String {
    let child = try self.name(name)
    return try checked(parent.isEmpty ? child : parent + "/" + child)
  }
}

public struct MobileConnection: Codable, Identifiable, Sendable {
  public var id: UUID
  public var name: String
  public var endpoint: URL
  public var username: String
  public var s3: S3Settings?
  public var fileServer: FileServerSettings?
  public var drime: DrimeSettings?
  public var readOnly: Bool?
  public init(
    id: UUID = UUID(), name: String, endpoint: URL, username: String, s3: S3Settings? = nil,
    fileServer: FileServerSettings? = nil, drime: DrimeSettings? = nil, readOnly: Bool? = nil
  ) {
    self.id = id
    self.name = name
    self.endpoint = endpoint
    self.username = username
    self.s3 = s3
    self.fileServer = fileServer
    self.drime = drime
    self.readOnly = readOnly
  }
}
/// Non-secret account context. Tokens are stored separately in the device Keychain.
public struct DrimeSettings: Codable, Sendable {
  public var workspaceID: Int64
  public var rootFolderID: Int64?
  public var accountID: Int64?
  public init(workspaceID: Int64 = 0, rootFolderID: Int64? = nil, accountID: Int64? = nil) {
    self.workspaceID = workspaceID
    self.rootFolderID = rootFolderID
    self.accountID = accountID
  }
}
public struct MobileLocation: Codable, Identifiable, Sendable {
  public var id: UUID
  public var connectionID: UUID
  public var name: String
  public var path: String
  public var suspended: Bool?
  public var descriptor: VaultDescriptor?
  public var removedPath: String?
  public var isVault: Bool { descriptor != nil }
  public init(
    id: UUID = UUID(), connectionID: UUID, name: String, path: String = "",
    descriptor: VaultDescriptor? = nil
  ) {
    self.id = id
    self.connectionID = connectionID
    self.name = name
    self.path = path
    self.descriptor = descriptor
  }
}
public struct MobileConfiguration: Codable, Sendable {
  public var connections: [MobileConnection] = []
  public var locations: [MobileLocation] = []
  public init() {}
}
public struct MobileNode: Codable, Identifiable, Sendable, Equatable {
  public var id: String
  public var parent: String
  public var path: String
  public var name: String
  public var directory: Bool
  public var size: Int64
  public var modified: Date
  public var version: String
  /// Last verified metadata read. It is not part of a content revision and
  /// refreshing it must never create endless File Provider change events.
  public var observedAt: Date? = nil
  public static func == (a: Self, b: Self) -> Bool {
    a.id == b.id && a.parent == b.parent && a.path == b.path && a.name == b.name &&
      a.directory == b.directory && a.size == b.size && a.modified == b.modified && a.version == b.version
  }
  public init(
    id: String, parent: String, path: String, name: String, directory: Bool, size: Int64,
    modified: Date, version: String
  ) {
    self.id = id
    self.parent = parent
    self.path = path
    self.name = name
    self.directory = directory
    self.size = size
    self.modified = modified
    self.version = version
  }
}
public struct MobileCatalog: Codable, Sendable {
  public var nodes: [String: MobileNode] = [:]
  public var generation: Int64 = 0
  public var changes: [MobileChange] = []
  public var requests: [String: String] = [:]
  public init() {}
  public mutating func record(_ item: MobileNode) {
    if let old = nodes[item.id], old == item, Array(old.path.utf8) == Array(item.path.utf8),
      Array(old.name.utf8) == Array(item.name.utf8)
    {
      nodes[item.id] = item
      return
    }
    nodes[item.id] = item
    generation += 1
    changes.append(MobileChange(generation: generation, id: item.id, deleted: false))
    trimHistory()
  }
  public mutating func remove(_ id: String) {
    guard nodes.removeValue(forKey: id) != nil else { return }
    generation += 1
    changes.append(MobileChange(generation: generation, id: id, deleted: true))
    trimHistory()
  }
  private mutating func trimHistory() {
    if changes.count > 10_000 { changes.removeFirst(changes.count - 10_000) }
  }
}
public struct MobileChange: Codable, Sendable {
  public var generation: Int64
  public var id: String
  public var deleted: Bool
}
public struct MobilePendingWrite: Codable, Identifiable, Sendable {
  public var id: String
  public var location: UUID
  public var path: String
  public var nodeID: String
  public var expectedVersion: String?
  public var requireNew: Bool
  public var digest: String
  public var created: Date
}

public enum MobileMessage {
  public static func describe(_ error: Error) -> String {
    if let error = error as? VaultCoreError {
      switch error {
      case .password:
        return MobileText.text(
          "密碼不正確，請再試一次。", "密码不正确，请重试。", "The vault password is incorrect. Try again.")
      case .exists, .conflict: return MobileError.conflict.localizedDescription
      case .missing: return MobileError.missing.localizedDescription
      case .busy: return MobileError.busy.localizedDescription
      case .unsafePath: return MobileError.invalidName.localizedDescription
      default: return MobileError.incomplete.localizedDescription
      }
    }
    if let error = error as? URLError {
      return MobileText.text(
        "連線未完成，請檢查網路、HTTPS 憑證與伺服器是否可用。（\(error.code.rawValue)）",
        "连接未完成，请检查网络、HTTPS 证书与服务器是否可用。（\(error.code.rawValue)）",
        "Connection failed. Check the network, HTTPS certificate, and server availability. (\(error.code.rawValue))"
      )
    }
    if let error = error as? MobileError { return error.localizedDescription }
    if let error = error as? SSHHostVerification { return error.localizedDescription }
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain {
      switch ns.code {
      case NSFileWriteOutOfSpaceError: return MobileError.quota.localizedDescription
      case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
        return MobileText.text("無法存取本機資料，請解鎖裝置並確認檔案權限。", "无法访问本机数据，请解锁设备并确认文件权限。", "Cannot access local data. Unlock the device and check file permissions.")
      default: break
      }
    }
    return MobileText.text("無法完成操作，請檢查連線、登入設定與可用空間後重試。（錯誤 \(ns.code)）", "无法完成操作，请检查连接、登录设置与可用空间后重试。（错误 \(ns.code)）", "Could not complete the operation. Check the connection, sign-in settings and available space, then retry. (Error \(ns.code))")
  }
}

public enum S3URLStyle: String, Codable, Sendable, CaseIterable {
  case path, virtualHosted
}
public struct S3Settings: Codable, Sendable {
  public var bucket: String
  public var region: String
  public var prefix: String
  public var urlStyle: S3URLStyle
  public init(bucket: String, region: String, prefix: String = "", urlStyle: S3URLStyle = .path) {
    self.bucket = bucket
    self.region = region
    self.prefix = prefix
    self.urlStyle = urlStyle
  }
  enum CodingKeys: String, CodingKey { case bucket, region, prefix, urlStyle }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    bucket = try c.decode(String.self, forKey: .bucket)
    region = try c.decode(String.self, forKey: .region)
    // Existing installations always used path-style and the entire bucket.
    prefix = try c.decodeIfPresent(String.self, forKey: .prefix) ?? ""
    urlStyle = try c.decodeIfPresent(S3URLStyle.self, forKey: .urlStyle) ?? .path
  }
}
public struct S3Credentials: Codable, Sendable {
  public var accessKey: String
  public var secretKey: String
  public var sessionToken: String?
  public init(accessKey: String, secretKey: String, sessionToken: String? = nil) {
    self.accessKey = accessKey
    self.secretKey = secretKey
    self.sessionToken = sessionToken
  }
}
