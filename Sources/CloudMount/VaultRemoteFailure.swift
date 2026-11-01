import Foundation

enum VaultRemoteFailure {
    // Only classify known error categories; RC/CLI output can contain passwords,
    // URLs and decrypted names and must never be copied into UI or log files.
    static func message(_ result: CommandResult, selectingFolder: Bool = false) -> String {
        if result.cancelled { return L10n.string("操作已取消。") }
        if result.timedOut { return L10n.string("等待雲端回應逾時，請檢查網路後重試。") }
        let text = result.output.lowercased()
        func status(_ value: Int) -> Bool {
            let pattern = "(?:http(?:/[^ ]+)?[ :]+|status(?: code)?[ :=]+|\\b)" + String(value) + "[ :]+(?:unauthorized|forbidden|not found|method not allowed|conflict|locked|insufficient storage)\\b"
            return text.range(of: pattern, options: .regularExpression) != nil
        }
        if status(401) { return L10n.string("雲端拒絕登入，請檢查此遠端的帳號、密碼或存取權杖。") }
        if status(403) || text.contains("permission denied") || text.contains("access denied") {
            return L10n.string(selectingFolder
                ? "無法在此位置建立資料夾。NAS 的最上層可能只列出共用資料夾，請按「選擇資料夾…」，進入 home 或其他可寫入的共用資料夾後再建立保險箱。"
                : "此位置不允許這項操作。請選擇可讀寫的資料夾，或檢查 NAS／雲端的存取權限。")
        }
        if status(404) { return L10n.string("找不到指定的雲端位置。請重新選擇資料夾後再試。") }
        if status(405) || status(409) {
            return L10n.string("此位置不接受建立或寫入。NAS 請先進入可寫入的共用資料夾；不要直接在共用資料夾清單建立保險箱。")
        }
        if status(423) { return L10n.string("雲端檔案或資料夾目前被鎖定，請稍後再試。") }
        if status(507) || text.contains("quota exceeded") || text.contains("no space left") {
            return L10n.string("雲端可用空間或配額不足，請清出空間後再試。")
        }
        if text.contains("x509:") || text.contains("certificate verify failed") {
            return L10n.string("無法驗證伺服器憑證，請檢查 NAS 的 HTTPS 憑證與遠端連線網址。")
        }
        return L10n.string("無法完成遠端保險箱操作，請確認網路、存放位置與讀寫權限。")
    }
}
