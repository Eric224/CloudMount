import CloudMountMobileCore
import SwiftUI

struct ConnectionHealthNotice: View {
  let location: MobileLocation
  let health: MobileProviderHealth?
  @ObservedObject var model: MobileModel
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let health {
        Label(
          health.issue.message,
          systemImage: health.issue == .ready
            ? "checkmark.circle" : health.issue == .vaultLocked ? "lock" : "info.circle"
        )
        .font(.caption).foregroundStyle(health.issue.isWarning ? Color.orange : Color.secondary)
        .accessibilityIdentifier("connectionHealth-\(location.id)")
      }
      if !location.isVault || model.unlocked.contains(location.id) {
        Button(T("重新檢查連線", "重新检查连接", "Check connection again")) {
          model.run { try await MobileEnvironment.checkConnection(location) }
        }.font(.caption).buttonStyle(.borderless)
      }
    }
  }
}
