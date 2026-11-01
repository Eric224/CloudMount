import Foundation

public enum MobileProviderIssue: String, Codable, Sendable {
  case ready, offline, credentials, deviceLocked, vaultLocked, conflict, quota, permission,
    unsupported, uploadFailed
  public var message: String {
    switch self {
    case .ready: return MobileText.text("連線正常", "连接正常", "Connection is working")
    case .offline:
      return MobileText.text(
        "暫時無法連線。請檢查網路後重新檢查。", "暂时无法连接。请检查网络后重新检查。",
        "Cannot connect right now. Check the network, then check again.")
    case .credentials:
      return MobileText.text(
        "登入已失效。請更新此空間的登入設定。", "登录已失效。请更新此空间的登录设置。",
        "Your sign-in is no longer valid. Update this storage connection's sign-in settings.")
    case .deviceLocked: return MobileError.deviceLocked.localizedDescription
    case .vaultLocked:
      return MobileText.text(
        "保險庫已上鎖。請在 CloudMount 解鎖後再開啟。", "保险库已上锁。请在 CloudMount 解锁后再打开。",
        "The vault is locked. Unlock it in CloudMount before opening it.")
    case .conflict: return MobileError.conflict.localizedDescription
    case .quota: return MobileError.quota.localizedDescription
    case .permission: return MobileError.forbidden.localizedDescription
    case .unsupported: return MobileError.unsupported.localizedDescription
    case .uploadFailed:
      return MobileText.text(
        "有操作未完成。原有檔案與待上傳修改已保留，請重試或查看登入設定。", "有操作未完成。原有文件与待上传修改已保留，请重试或查看登录设置。",
        "An operation did not finish. Existing files and pending edits are preserved. Retry or check the sign-in settings."
      )
    }
  }
  public var isWarning: Bool { ![.ready, .vaultLocked, .deviceLocked].contains(self) }
}
public struct MobileProviderHealth: Codable, Sendable {
  public var eventID: UUID = UUID()
  public var issue: MobileProviderIssue
  public var itemID: String?
  public var checkedAt: Date = Date()
}
extension MobileService {
  public func providerHealth(_ id: UUID) throws -> MobileProviderHealth? {
    try repository.read("provider-health-\(id).json", default: Optional<MobileProviderHealth>.none)
  }
  public func recordProviderFailure(
    _ issue: MobileProviderIssue, location id: UUID, itemID: String? = nil
  ) async throws {
    let lease = try await repository.lease("health-\(id)")
    defer { withExtendedLifetime(lease) {} }
    try repository.write(
      MobileProviderHealth(issue: issue, itemID: itemID), name: "provider-health-\(id).json")
  }
  /// Called only after a real authenticated remote read or acknowledged mutation.
  /// A successful listing must never clear an outstanding write conflict/quota error.
  public func recordProviderSuccess(location id: UUID, mutation: Bool, itemID: String? = nil)
    async throws -> MobileProviderHealth
  {
    let lease = try await repository.lease("health-\(id)")
    defer { withExtendedLifetime(lease) {} }
    if let old = try providerHealth(id) {
      if old.issue == .ready { return old }
      if [.conflict, .quota, .permission, .unsupported, .uploadFailed].contains(old.issue) {
        guard mutation, try repository.pending(id).isEmpty,
          old.issue != .conflict || (itemID != nil && old.itemID == itemID)
        else { return old }
      }
    }
    let current = MobileProviderHealth(issue: .ready, itemID: nil)
    try repository.write(current, name: "provider-health-\(id).json")
    return current
  }
  /// Synchronization metadata does not require opening a remote or exposing names/contents.
  public func providerSyncGeneration(_ id: UUID) async throws -> Int64 {
    let lease = try await repository.lease(id.uuidString)
    defer { withExtendedLifetime(lease) {} }
    guard
      try repository.configuration().locations.contains(where: {
        $0.id == id && $0.removedPath == nil && $0.suspended != true
      })
    else { throw MobileError.missing }
    return try repository.catalog(id).generation
  }
}
