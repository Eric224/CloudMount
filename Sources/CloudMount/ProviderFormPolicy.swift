import Foundation

struct ProviderFormPolicy {
    let provider: RcloneProvider
    let values: [String: String]
    let editing: Bool
    let webdavAuthentication: String
    let sftpAuthentication: String

    init(provider: RcloneProvider, values: [String: String], editing: Bool = false,
         webdavAuthentication: String = "password", sftpAuthentication: String = "password") {
        self.provider = provider; self.values = values; self.editing = editing
        self.webdavAuthentication = webdavAuthentication; self.sftpAuthentication = sftpAuthentication
    }

    static func matches(_ filter: String, provider: String) -> Bool {
        if filter.isEmpty { return true }
        if filter.hasPrefix("!") {
            return !filter.dropFirst().split(separator: ",").contains(Substring(provider))
        }
        return filter.split(separator: ",").contains(Substring(provider))
    }
    var effectiveProvider: String {
        values["provider"].flatMap { $0.isEmpty ? nil : $0 } ?? (provider.prefix == "s3" ? "Other" : provider.options.first(where: { $0.name == "provider" })?.defaultValue ?? "")
    }
    var eligible: [RcloneProviderOption] {
        provider.options.filter {
            !$0.hidden && $0.type.lowercased() != "configmap" &&
            (Self.matches($0.providerFilter, provider: effectiveProvider) ||
             provider.prefix == "s3" && ["region", "endpoint"].contains($0.name))
        }
    }
    private var preferred: [String] {
        switch provider.prefix {
        case "webdav": return ["url"] + (webdavAuthentication == "token" ? ["bearer_token"] : webdavAuthentication == "none" ? [] : ["user", "pass"])
        case "sftp": return ["host", "user"] + (sftpAuthentication == "key" ? ["key_file", "key_file_pass"] : sftpAuthentication == "agent" ? ["key_use_agent"] : ["pass"])
        case "ftp": return ["host", "user", "pass", "explicit_tls", "tls"]
        case "smb": return ["host", "user", "pass"]
        case "drime": return ["access_token"]
        case "internxt": return ["email", "pass"]
        case "storj", "tardigrade": return ["provider"] + (effectiveProvider == "new" ? ["satellite_address", "api_key", "passphrase"] : ["access_grant"])
        case "s3": return ["provider", "env_auth"] + (values["env_auth"] == "true" ? [] : ["access_key_id", "secret_access_key"]) + ["region", "endpoint", "force_path_style"]
        case "drive", "onedrive", "dropbox", "pcloud", "box", "googlephotos": return []
        default:
            let names = ["provider", "env_auth", "host", "url", "auth", "email", "user", "username", "account", "pass", "password", "access_token", "token", "key", "access_key_id", "secret_access_key", "endpoint", "remote", "upstreams"]
            return Array(names.filter { name in eligible.contains { $0.name == name && !$0.advanced } }.prefix(6))
        }
    }
    var basic: [RcloneProviderOption] {
        let mustFill = eligible.filter { $0.required && ($0.defaultValue ?? "").isEmpty }
        let preferredOptions = preferred.compactMap { name in eligible.first { $0.name == name } }
        var seen: Set<String> = []
        return (preferredOptions + mustFill).filter { seen.insert($0.name).inserted }
    }
    var optional: [RcloneProviderOption] {
        let basics = Set(basic.map(\.name))
        return eligible.filter { !basics.contains($0.name) && !$0.advanced }
    }
    var advanced: [RcloneProviderOption] {
        let basics = Set(basic.map(\.name))
        return eligible.filter { !basics.contains($0.name) && $0.advanced }
    }
    var missing: [RcloneProviderOption] {
        basic.filter { option in
            let required = option.required || (provider.prefix == "drime" && option.name == "access_token") || (option.name == "provider" && (option.defaultValue ?? "").isEmpty && !option.examples.isEmpty)
            if editing && option.isSecret { return false }
            let value = option.name == "provider" && provider.prefix == "s3" ? effectiveProvider : values[option.name] ?? option.defaultValue ?? ""
            return required && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    var validationError: String? {
        if let option = missing.first {
            return String(format: L10n.string("請填寫：%@"), L10n.optionLabel(providerPrefix: provider.prefix, optionName: option.name))
        }
        if ["webdav", "http"].contains(provider.prefix), let url = values["url"], !url.isEmpty {
            guard let parts = URLComponents(string: url), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
                  parts.host?.isEmpty == false, parts.user == nil, parts.password == nil else {
                return L10n.string("請輸入完整的 http:// 或 https:// 伺服器網址；帳號與密碼請填在各自欄位。")
            }
        }
        if provider.prefix == "s3" {
            let endpoint = values["endpoint"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if effectiveProvider == "Other" || effectiveProvider == "Minio", endpoint.isEmpty {
                return L10n.string("請填寫 S3 服務端點網址。")
            }
            if !endpoint.isEmpty {
                guard let parts = URLComponents(string: endpoint), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
                      parts.host?.isEmpty == false, parts.user == nil, parts.password == nil,
                      parts.query == nil, parts.fragment == nil, parts.port.map({ 1...65535 ~= $0 }) ?? true else {
                    return L10n.string("請輸入完整的 S3 端點網址，例如 https://s3.example.com:9000。")
                }
            }
        }
        if let port = values["port"], !port.isEmpty, !(Int(port).map { 1...65535 ~= $0 } ?? false) {
            return L10n.string("連接埠必須是 1 到 65535 的數字。")
        }
        if provider.prefix == "ftp", values["tls"] == "true", values["explicit_tls"] == "true" {
            return L10n.string("FTP 的兩種 TLS 加密方式只能選擇一種。")
        }
        for option in eligible where option.exclusive {
            guard let value = values[option.name], !value.isEmpty else { continue }
            if !option.examples.isEmpty && !option.examples.contains(where: { $0.value == value }) && value != option.defaultValue {
                return String(format: L10n.string("請重新選擇：%@"), L10n.optionLabel(providerPrefix: provider.prefix, optionName: option.name))
            }
        }
        return nil
    }
    var submittedValues: [String: String] {
        let allowed = Set(eligible.map(\.name))
        return values.filter { item in
            guard allowed.contains(item.key), !Self.isRedacted(item.value) else { return false }
            return !item.value.isEmpty || (editing && provider.options.first(where: { $0.name == item.key })?.isSecret == false)
        }
    }
    static func isRedacted(_ value: String) -> Bool {
        let upper = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return upper == "XXX" || upper == "***" || upper == "REDACTED" || upper.contains("*** REDACTED ***")
    }
}
