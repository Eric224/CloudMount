import Foundation
import CloudMountLocalization

enum L10n {
    static var locale: Locale { AppLanguage.current.locale }
    static func string(_ key: String) -> String {
        localized(key) ?? AppLanguage.english.localized(key) ?? key
    }

    static func providerName(prefix: String, fallback: String) -> String {
        localized("provider.\(prefix)") ?? prefix.capitalized
    }

    static func providerDescription(prefix: String, fallback: String) -> String {
        if let translated = localized("providerHelp.\(prefix)") { return translated }
        return AppLanguage.current != .english ? string("按照下方欄位填寫連線資料；不需要的設定可以留空。") : fallback
    }

    static func optionLabel(providerPrefix: String, optionName: String) -> String {
        if let translated = localized("option.\(providerPrefix).\(optionName)") ?? localized("option.\(optionName)") { return translated }
        let identifier = optionName
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { word in
                switch word.lowercased() {
                case "url": return "URL"
                case "id": return "ID"
                case "ntlm": return "NTLM"
                case "oauth": return "OAuth"
                case "api": return "API"
                case "ip": return "IP"
                default: return word.capitalized
                }
            }
            .joined(separator: " ")
        return AppLanguage.current == .english ? identifier : String(format:string("服務專用設定（%@）"),optionName)
    }
    static func optionExample(provider: String, option: String, value: String, help: String) -> String {
        if let translated = localized("example.\(provider).\(option).\(value)") { return translated }
        if let translated = localized("example.\(value)") { return translated }
        // Values are protocol identifiers, not translatable free-form help.
        // Keep arbitrary backend English prose in the explicitly labeled reference section.
        return AppLanguage.current == .english && !help.isEmpty ? "\(value) — \(help)" : value
    }
    static func configurationError(_ source: String) -> String {
        if source.isEmpty { return "" }
        if let translated = localized(source) { return translated }
        return string("服務未接受這個設定。請確認選項與登入資料後重試。")
    }
    static func error(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return string("連線未完成，請檢查網路與伺服器憑證後重試。") }
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteOutOfSpaceError: return string("本機可用空間不足，請清出空間後重試。")
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return string("無法存取本機檔案，請檢查檔案與資料夾權限。")
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return string("找不到需要的本機檔案，請重新選擇或檢查安裝是否完整。")
            default: break
            }
        }
        if let message = (error as? LocalizedError)?.errorDescription { return string(message) }
        return String(format:string("操作未完成，請檢查連線、權限與可用空間後重試。（錯誤 %@）"),String(ns.code))
    }

    static func hasOptionHelp(providerPrefix: String, option: RcloneProviderOption) -> Bool {
        localized("optionHelp.\(providerPrefix).\(option.name)") != nil
    }

    static func optionHelp(providerPrefix: String, option: RcloneProviderOption) -> String {
        if let translated = localized("optionHelp.\(providerPrefix).\(option.name)") { return translated }
        if AppLanguage.current != .english {
            return option.required ? string("請填寫服務提供的連線資訊。") : string("可留空；未設定時會使用預設值。")
        }
        return option.help
    }

    private static func localized(_ key: String) -> String? {
        AppLanguage.current.localized(key)
    }
}
