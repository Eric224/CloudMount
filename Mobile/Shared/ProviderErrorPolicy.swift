import CloudMountMobileCore
import CloudMountVaultCore
import FileProvider
import Foundation

enum ProviderErrorPolicy {
  static func issue(_ error: Error) -> MobileProviderIssue? {
    let ns = error as NSError
    if ns.domain == NSFileProviderErrorDomain {
      switch ns.code {
      case NSFileProviderError.serverUnreachable.rawValue: return .offline
      case NSFileProviderError.notAuthenticated.rawValue: return .credentials
      case NSFileProviderError.cannotSynchronize.rawValue: return .conflict
      case NSFileProviderError.insufficientQuota.rawValue: return .quota
      default: return nil  // Control flow: expired anchor/page, missing item, cancellation, etc.
      }
    }
    if ns.domain == NSCocoaErrorDomain {
      switch ns.code {
      case NSUserCancelledError, NSFileNoSuchFileError, NSFileReadNoSuchFileError, NSFileLockingError: return nil
      case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return .permission
      case NSFileWriteOutOfSpaceError: return .quota
      case NSFeatureUnsupportedError: return .unsupported
      default: return .uploadFailed
      }
    }
    switch error {
    case MobileError.busy: return nil
    case MobileError.locked, VaultCoreError.password: return .vaultLocked
    case MobileError.deviceLocked: return .deviceLocked
    case MobileError.credential: return .credentials
    case MobileError.conflict, VaultCoreError.conflict, VaultCoreError.exists: return .conflict
    case MobileError.quota: return .quota
    case MobileError.forbidden: return .permission
    case MobileError.unsupported, MobileError.vaultMemoryLimit, MobileError.unsafeWrites, VaultCoreError.unsupported: return .unsupported
    case MobileError.expiredPage, MobileError.missing, VaultCoreError.missing, is CancellationError: return nil
    case let url as URLError: return url.code == .cancelled ? nil : .offline
    case MobileError.network: return .offline
    default: return .uploadFailed
    }
  }
  static func error(_ error: Error, location: UUID) -> NSError {
    let ns = error as NSError
    // In particular, syncAnchorExpired must reach the OS unchanged so it rescans.
    // Treating it as serverUnreachable permanently throttles a healthy provider.
    if ns.domain == NSFileProviderErrorDomain || ns.domain == NSCocoaErrorDomain { return ns }
    if case MobileError.expiredPage = error { return NSFileProviderError(.pageExpired) as NSError }
    if error is CancellationError || (error as? URLError)?.code == .cancelled {
      return NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
    }
    let code: NSFileProviderError.Code
    switch error {
    case MobileError.locked, MobileError.credential, MobileError.deviceLocked,
      VaultCoreError.password:
      code = .notAuthenticated
    case MobileError.missing, VaultCoreError.missing: code = .noSuchItem
    case MobileError.conflict, VaultCoreError.conflict, VaultCoreError.exists:
      code = .cannotSynchronize
    case MobileError.quota: code = .insufficientQuota
    case MobileError.busy:
      return NSError(domain: NSCocoaErrorDomain, code: NSFileLockingError,
        userInfo: [NSLocalizedDescriptionKey: MobileMessage.describe(error)])
    case MobileError.forbidden:
      return NSError(
        domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
        userInfo: [NSLocalizedDescriptionKey: MobileMessage.describe(error)])
    case MobileError.unsupported, MobileError.vaultMemoryLimit, MobileError.unsafeWrites, VaultCoreError.unsupported:
      return NSError(
        domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError,
        userInfo: [NSLocalizedDescriptionKey: MobileMessage.describe(error)])
    default: code = .serverUnreachable
    }
    let reason: String
    switch error {
    case MobileError.credential: reason = "cloudCredentials"
    case MobileError.deviceLocked: reason = "deviceLocked"
    default: reason = "vaultLocked"
    }
    return NSError(
      domain: NSFileProviderErrorDomain, code: code.rawValue,
      userInfo: [
        NSLocalizedDescriptionKey: MobileMessage.describe(error),
        "CloudMountLocation": location.uuidString, "CloudMountReason": reason,
      ])
  }
}
