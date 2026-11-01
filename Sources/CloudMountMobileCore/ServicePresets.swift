import Foundation

/// Public connection recipes only. No tokens, passwords or OAuth registrations.
/// These select the existing native transports and the shared vault lifecycle.
public enum StorageServicePreset: String, CaseIterable, Identifiable, Sendable {
  case webdav, pcloud, koofr, nextcloud, owncloud, synology, qnap
  case drime, s3, amazon, minio, r2, backblaze, wasabi, spaces
  case sftp, ftps, ftp
  public var id: String { rawValue }
  public var name: String {
    switch self {
    case .webdav: return "WebDAV / NAS"
    case .pcloud: return "pCloud"
    case .koofr: return "Koofr"
    case .nextcloud: return "Nextcloud"
    case .owncloud: return "ownCloud"
    case .synology: return "Synology NAS"
    case .qnap: return "QNAP NAS"
    case .drime: return "Drime"
    case .s3: return "S3 / MinIO / R2"
    case .amazon: return "Amazon S3"
    case .minio: return "MinIO"
    case .r2: return "Cloudflare R2"
    case .backblaze: return "Backblaze B2"
    case .wasabi: return "Wasabi"
    case .spaces: return "DigitalOcean Spaces"
    case .sftp: return "SFTP"
    case .ftps: return "FTPS"
    case .ftp: return "FTP"
    }
  }
  public var transport: String {
    switch self {
    case .drime: return "Drime"
    case .sftp: return "SFTP"
    case .ftps: return "FTPS"
    case .ftp: return "FTP"
    case .s3, .amazon, .minio, .r2, .backblaze, .wasabi, .spaces: return "S3"
    default: return "WebDAV"
    }
  }
  public var s3Preset: String {
    switch self {
    case .minio: return "MinIO"
    case .r2: return "R2"
    case .backblaze: return "B2"
    case .wasabi: return "Wasabi"
    case .spaces: return "Spaces"
    default: return "AWS"
    }
  }
  public var defaultAddress: String {
    switch self {
    case .pcloud: return "https://webdav.pcloud.com/"
    case .koofr: return "https://app.koofr.net/dav/Koofr/"
    default: return ""
    }
  }
  public var help: String {
    switch self {
    case .pcloud:
      return MobileText.text(
        "透過 WebDAV 連線。選擇帳號資料所在區域，再輸入 pCloud 電郵與密碼。", "通过 WebDAV 连接。选择账号数据所在区域，再输入 pCloud 邮箱与密码。",
        "Connect using WebDAV. Choose your account's data region, then enter your pCloud email and password."
      )
    case .koofr:
      return MobileText.text(
        "透過 WebDAV 連線。使用 Koofr 電郵及在 Koofr 設定建立的應用程式密碼。",
        "通过 WebDAV 连接。使用 Koofr 邮箱及在 Koofr 设置中创建的应用专用密码。",
        "Connect using WebDAV. Use your Koofr email and an app password generated in Koofr settings."
      )
    case .nextcloud, .owncloud:
      return MobileText.text(
        "透過 WebDAV 連線。可填網站網址，或貼上服務設定內完整的 WebDAV 網址；建議使用應用程式密碼。",
        "通过 WebDAV 连接。可填写网站地址，或粘贴服务设置中的完整 WebDAV 地址；建议使用应用专用密码。",
        "Connect using WebDAV. Enter your server address or paste the full WebDAV URL from its settings. An app password is recommended."
      )
    case .synology, .qnap:
      return MobileText.text(
        "請先在 NAS 啟用 HTTPS WebDAV，再填入可讀寫的共用資料夾網址；不是 NAS 的管理頁面網址。",
        "请先在 NAS 启用 HTTPS WebDAV，再填写可读写的共享文件夹地址；不是 NAS 管理页面的地址。",
        "Enable HTTPS WebDAV on your NAS, then enter a writable shared-folder URL, rather than the NAS administration page."
      )
    case .backblaze, .wasabi, .spaces:
      return MobileText.text(
        "透過 S3 相容介面連線。使用儲存桶的區域與 S3 金鑰。連線時會檢查安全寫入支援；不支援時保留唯讀存取。",
        "通过 S3 兼容接口连接。使用存储桶的区域及 S3 密钥。连接时会检查安全写入支持；不支持时保留只读访问。",
        "Connect using the S3-compatible API with your bucket region and S3 keys. Safe-write support is checked when connecting; otherwise access stays read-only."
      )
    default: return ""
    }
  }
  public var documentationURL: URL? {
    let value: String
    switch self {
    case .pcloud: value = "https://help.pcloud.com/article/webdav"
    case .koofr:
      value =
        "https://koofr.eu/help/koofr_with_webdav/how-do-i-connect-a-service-to-koofr-through-webdav/"
    case .nextcloud:
      value = "https://docs.nextcloud.com/server/latest/user_manual/en/files/access_webdav.html"
    case .owncloud: value = "https://owncloud.dev/apis/http/webdav/"
    case .backblaze:
      value = "https://www.backblaze.com/docs/en/cloud-storage-call-the-s3-compatible-api"
    case .wasabi: value = "https://docs.wasabi.com/docs/service-urls-for-wasabis-storage-regions"
    case .spaces: value = "https://docs.digitalocean.com/products/spaces/reference/aws-sdks/"
    default: return nil
    }
    return URL(string: value)
  }
  public func webDAVURL(address: String, username: String) throws -> URL {
    var parts = try Self.httpsComponents(address)
    if self == .nextcloud, !parts.path.contains("/remote.php/") {
      guard !username.isEmpty, username.utf8.count <= 255 else { throw MobileError.invalidAddress }
      parts.percentEncodedPath =
        parts.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        .split(separator: "/").map(String.init).map { "/" + $0 }.joined()
        + "/remote.php/dav/files/" + S3Signature.encode(username) + "/"
    } else if self == .owncloud, !parts.path.contains("/remote.php/") {
      parts.percentEncodedPath =
        parts.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        .split(separator: "/").map(String.init).map { "/" + $0 }.joined() + "/remote.php/webdav/"
    }
    guard let url = parts.url else { throw MobileError.invalidAddress }
    return url
  }
  public static func s3Connection(preset: String, address: String, region: String, account: String)
    throws -> (endpoint: URL, region: String)
  {
    let region = region.trimmingCharacters(in: .whitespacesAndNewlines)
    func label(_ value: String) -> Bool {
      !value.isEmpty && value.utf8.count <= 63 && value.first != "-" && value.last != "-"
        && value.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
    }
    let endpoint: String
    let signingRegion: String
    switch preset {
    case "R2":
      guard account.count == 32, account.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
        throw MobileError.invalidAddress
      }
      endpoint = "https://\(account).r2.cloudflarestorage.com"
      signingRegion = "auto"
    case "MinIO":
      endpoint = address
      signingRegion = region.isEmpty ? "us-east-1" : region
    case "B2", "Wasabi", "Spaces", "AWS":
      guard label(region) else { throw MobileError.invalidAddress }
      switch preset {
      case "B2": endpoint = "https://s3.\(region).backblazeb2.com"
      case "Wasabi": endpoint = "https://s3.\(region).wasabisys.com"
      case "Spaces": endpoint = "https://\(region).digitaloceanspaces.com"
      default: endpoint = "https://s3.\(region).amazonaws.com"
      }
      signingRegion = preset == "Spaces" ? "us-east-1" : region
    default: throw MobileError.invalidAddress
    }
    guard let url = try httpsComponents(endpoint).url else { throw MobileError.invalidAddress }
    return (url, signingRegion)
  }
  private static func httpsComponents(_ address: String) throws -> URLComponents {
    guard let c = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
      c.scheme?.lowercased() == "https", let host = c.host, !host.isEmpty,
      c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
      !c.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    else { throw MobileError.invalidAddress }
    return c
  }
}
