import Foundation

/// Queue names and raw service errors stay in memory; only summaries reach UI.
struct VaultUploadReport: Equatable {
    enum Phase: Equatable { case uploaded, waiting, uploading, retrying, openChanges, storageFull, failed }
    let phase: Phase
    let queued: Int
    let uploading: Int
    let retrying: Int
    let retryAfter: Int
    let finderSettingsOnly: Bool
    let replacementCleanupFailed: Bool
    let checkedAt: Date

    var title: String {
        let key = switch phase {
        case .uploaded: "已上傳至雲端"
        case .waiting: "等待上傳…"
        case .uploading: "正在加密上傳…"
        case .retrying: "上傳失敗，等待重試"
        case .openChanges: "尚有本機修改，請儲存並關閉檔案"
        case .storageFull: "本機快取空間不足"
        case .failed: "上傳未完成，請檢查網路"
        }
        return L10n.string(key)
    }
    var warning: Bool { retrying > 0 || [.retrying, .storageFull, .failed].contains(phase) }
    var explanation: String {
        if replacementCleanupFailed {
            return L10n.string("雲端覆寫後的清理失敗，仍在重試。本機修改已保留，尚不能確認安全結束。")
        }
        let key = switch phase {
        case .uploaded: "目前沒有待上傳修改。結束 app 時仍會再次檢查並安全鎖定。"
        case .waiting: "檔案已排入佇列，等待開始傳送；不是正在進行加密運算。"
        case .uploading: "正在將檔案加密並傳送至雲端。請等待完成後鎖定。"
        case .retrying, .failed: "傳送未完成，本機修改仍保留。請檢查網路、雲端容量與服務權限。"
        case .openChanges: "檔案可能仍由其他程式開啟或寫入；請先儲存並關閉。"
        case .storageFull: "請釋放本機磁碟空間；不要手動刪除保險箱快取。"
        }
        return L10n.string(key)
    }

    static func make(state: VaultUploadState, queue: [String: Any], dirty: Int, lastError: String?, now: Date = Date()) throws -> Self {
        guard dirty >= 0, let items = queue["queue"] as? [[String: Any]] else { throw VaultFailure.invalid }
        var retrying = 0, retryAfter = 0, active = 0
        var finderOnly = !items.isEmpty
        for item in items {
            guard let name = item["name"] as? String, let tries = item["tries"] as? Int, tries >= 0,
                  let uploading = item["uploading"] as? Bool,
                  let expiry = item["expiry"] as? Double, expiry.isFinite else { throw VaultFailure.invalid }
            if uploading { active += 1 }
            else if tries > 0 {
                retrying += 1
                let seconds = Int(min(86_400, max(0, expiry.rounded(.up))))
                retryAfter = retrying == 1 ? seconds : min(retryAfter, seconds)
            }
            finderOnly = finderOnly && [".DS_Store", ".localized"].contains((name as NSString).lastPathComponent)
        }
        let phase: Phase
        if state.outOfSpace { phase = .storageFull }
        else if state.uploading > 0 || active > 0 { phase = .uploading }
        else if retrying > 0 { phase = .retrying }
        else if state.errors > 0 { phase = .failed }
        else if state.queued > 0 || !items.isEmpty { phase = .waiting }
        else if dirty > 0 { phase = .openChanges }
        else { phase = .uploaded }
        // core/stats errors are cumulative. Never let an old error keep an
        // otherwise clean queue in an error state after it has recovered.
        return Self(phase: phase, queued: max(0, max(state.queued, items.count - active) - retrying), uploading: max(state.uploading, active),
            retrying: retrying, retryAfter: retryAfter,
            finderSettingsOnly: finderOnly && state.queued + state.uploading <= items.count && dirty <= items.count,
            replacementCleanupFailed: (retrying > 0 || state.errors > 0) && (lastError?.contains("failed to delete existing object") == true), checkedAt: now)
    }
}
