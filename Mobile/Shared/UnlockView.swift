import CloudMountMobileCore
import SwiftUI

struct UnlockView: View {
  let location: MobileLocation
  var completion: () async -> Void = {}
  var cancellation: (() -> Void)?
  @Environment(\.dismiss) private var dismiss
  @State private var password = ""
  @State private var remember = false
  @State private var busy = false
  @State private var error: String?
  @State private var remembered = false
  var body: some View {
    NavigationStack {
      Form {
        Section {
          Label(location.name, systemImage: "lock.fill").font(.title2)
          Text(
            T(
              "解鎖一次，就能在「檔案」中開啟及編輯。", "解锁一次，就能在“文件”中打开及编辑。",
              "Unlock once to open and edit your files in Files."))
        }
        if !remembered {
          SecureField(T("保險庫密碼", "保险库密码", "Vault password"), text: $password).textContentType(
            .password
          ).accessibilityIdentifier("unlockPassword")
          Toggle(T("在這台裝置記住密碼", "在这台设备记住密码", "Remember on this device"), isOn: $remember)
        }
        if let error { Text(error).foregroundStyle(.red) }
        Button(remembered ? T("解鎖", "解锁", "Unlock") : T("解鎖保險庫", "解锁保险库", "Unlock vault")) {
          guard !busy else { return }
          busy = true
          error = nil
          Task {
            defer { busy = false }
            do {
              let service = try MobileEnvironment.service()
              try await service.unlock(
                location.id, password: remembered ? nil : password, remember: remember)
              password = ""
              if location.suspended == true { try await MobileEnvironment.resume(location) }
              await MobileEnvironment.didUnlock(location.id)
              await completion()
              dismiss()
            } catch { self.error = MobileMessage.describe(error) }
          }
        }.disabled(busy || (!remembered && password.isEmpty)).accessibilityIdentifier(
          "unlockConfirm")
        if remembered { Button(T("改用密碼", "改用密码", "Use password instead")) { remembered = false } }
      }
      .navigationTitle(T("解鎖", "解锁", "Unlock"))
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(T("取消", "取消", "Cancel")) {
            if let cancellation { cancellation() } else { dismiss() }
          }.disabled(busy)
        }
      }
      .overlay {
        if busy {
          ProgressView().padding(24).background(
            .regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
      }
      .task {
        remembered =
          (try? MobileEnvironment.service().canUnlockWithoutPassword(location.id)) == true
      }
    }
    .interactiveDismissDisabled(busy)
  }
}
