import Foundation
import CloudMountVaultCore

extension VaultCoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .password: return L10n.string("密碼不正確，或保險箱描述檔已損壞。")
        case .conflict: return L10n.string("遠端內容已變更，已停止取代檔案。請重新整理並確認其他電腦已鎖定保險箱。")
        case .malformed, .unsupported: return L10n.string("保險箱資料損壞或格式不支援，未修改任何遠端檔案。")
        default: return L10n.string("無法完成遠端保險箱操作，請確認網路、存放位置與讀寫權限。")
        }
    }
}
