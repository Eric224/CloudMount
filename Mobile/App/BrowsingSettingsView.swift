import CloudMountMobileCore
import SwiftUI

struct BrowsingSettingsView: View {
  @State private var policy = MobileBrowsingPolicy()
  @State private var busy = false
  @State private var status: String?
  var body: some View {
    Form {
      Section {
        Toggle(T("產生並快取圖片縮圖", "生成并缓存图片缩略图", "Generate and cache image thumbnails"), isOn: $policy.thumbnailsEnabled)
          .accessibilityIdentifier("cacheThumbnails")
        Stepper(value: $policy.maximumMB, in: 16...128, step: 16) {
          LabeledContent(T("縮圖快取上限", "缩略图缓存上限", "Thumbnail cache limit"), value: "\(policy.maximumMB) MB")
        }.accessibilityIdentifier("thumbnailLimit")
        Stepper(value: $policy.retentionDays, in: 1...30) {
          LabeledContent(T("閒置保留天數", "闲置保留天数", "Idle retention (days)"), value: String(policy.retentionDays))
        }.accessibilityIdentifier("thumbnailRetention")
        Text(T("僅處理正在瀏覽的圖片，不會掃描或下載整個雲端。首次產生縮圖仍可能讀取原圖；後續盡量重用小縮圖。", "仅处理正在浏览的图片，不会扫描或下载整个云端。首次生成缩略图仍可能读取原图；后续尽量重用小缩略图。", "Only requested images are processed. Your cloud is never scanned or downloaded in full. Creating a thumbnail may read the original once; later requests reuse the small preview."))
          .font(.caption).foregroundStyle(.secondary)
        Text(T("為保護行動裝置資源，縮圖最多 512 像素，僅處理 8 MB 以內的支援圖片。影片與過大圖片仍可正常開啟，但不在背景產生縮圖。", "为保护移动设备资源，缩略图最多 512 像素，仅处理 8 MB 以内的支持图片。视频与过大图片仍可正常打开，但不在后台生成缩略图。", "To protect device resources, previews are limited to 512 pixels and supported images up to 8 MB. Videos and larger images can still be opened, but do not receive background thumbnails."))
          .font(.caption).foregroundStyle(.secondary)
        Button(T("儲存設定", "保存设置", "Save settings")) {
          run {
            try await MobileEnvironment.service().updateBrowsingPolicy(policy)
            status = T("設定已儲存。", "设置已保存。", "Settings saved.")
          }
        }.accessibilityIdentifier("saveBrowsingSettings")
      } header: { Text(T("本機預覽快取", "本机预览缓存", "Local preview cache")) }
      Section {
        Text(T("目錄與檔案資訊會短暫快取約 1 分鐘，減少重複查詢；其他裝置的變更可能稍晚顯示。S3 會按頁讀取清單，不會先等待完整目錄。", "目录和文件信息会短暂缓存约 1 分钟，减少重复查询；其他设备的更改可能稍晚显示。S3 会分页读取列表，不会先等待完整目录。", "Directory and file metadata are cached for about one minute to reduce repeat requests. Changes from another device may appear after a short delay. S3 listings are fetched page by page."))
        Text(T("保險庫縮圖以加密形式儲存，上鎖後 CloudMount 不再提供內容。系統或其他 App 已顯示的預覽可能另有暫存，無法保證完全清除。", "保险库缩略图以加密形式保存，上锁后 CloudMount 不再提供内容。系统或其他 App 已显示的预览可能另有缓存，无法保证完全清除。", "Vault previews are stored encrypted. CloudMount stops providing them when the vault is locked. Previews already displayed by the system or other apps may be cached separately and cannot be guaranteed to be erased."))
      }.font(.footnote).foregroundStyle(.secondary)
      Section {
        Button(T("清除縮圖快取", "清除缩略图缓存", "Clear thumbnail cache")) {
          run {
            try await MobileEnvironment.service().clearThumbnailCache()
            status = T("CloudMount 縮圖快取已清除。", "CloudMount 缩略图缓存已清除。", "CloudMount thumbnail cache cleared.")
          }
        }.accessibilityIdentifier("clearThumbnailCache")
        Text(T("只清除 CloudMount 的預覽快取，不會刪除雲端檔案、待上傳修改，或「檔案」App 管理的副本。", "只清除 CloudMount 的预览缓存，不会删除云端文件、待上传修改或“文件”App 管理的副本。", "This removes only CloudMount previews. It does not delete cloud files, pending edits, or copies managed by Files."))
          .font(.caption).foregroundStyle(.secondary)
      }
      if let status { Text(status).font(.footnote).accessibilityIdentifier("browsingSettingsStatus") }
    }
    .disabled(busy)
    .navigationTitle(T("瀏覽與快取", "浏览与缓存", "Browsing and cache"))
    .task {
      do { policy = try MobileEnvironment.service().browsingPolicy() }
      catch { status = MobileMessage.describe(error) }
    }
  }
  private func run(_ work: @escaping @MainActor () async throws -> Void) {
    guard !busy else { return }
    busy = true; status = nil
    Task { @MainActor in
      defer { busy = false }
      do { try await work() } catch { status = MobileMessage.describe(error) }
    }
  }
}
