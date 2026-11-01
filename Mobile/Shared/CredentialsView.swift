import CloudMountMobileCore
import SwiftUI

struct CredentialsView: View {
  let connection: MobileConnection
  var completion: () async -> Void = {}
  var cancellation: (() -> Void)?
  @Environment(\.dismiss) private var dismiss
  @State private var username = ""
  @State private var password = ""
  @State private var token = ""
  @State private var busy = false
  @State private var error: String?
  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text(connection.name).font(.headline)
          Text(connection.endpoint.host ?? "").font(.caption).foregroundStyle(.secondary)
          Text(
            T(
              "更新雲端登入資料；不會更改保險庫密碼。", "更新云端登录信息；不会更改保险库密码。",
              "Update your cloud sign-in. Your vault password stays the same."))
        }
        if connection.drime == nil {
          TextField(
            connection.s3 == nil
              ? T("帳號", "账号", "Username") : T("存取金鑰 ID", "访问密钥 ID", "Access key ID"),
            text: $username
          ).textInputAutocapitalization(.never).autocorrectionDisabled()
        }
        SecureField(
          connection.drime != nil
            ? T("新的 Drime 存取權杖", "新的 Drime 访问令牌", "New Drime access token")
            : connection.s3 == nil
              ? T("新登入密碼", "新登录密码", "Cloud password") : T("秘密存取金鑰", "秘密访问密钥", "Secret access key"),
          text: $password
        ).textInputAutocapitalization(.never).autocorrectionDisabled()
        if connection.drime != nil {
          Link(
            T("管理 Drime 權杖", "管理 Drime 令牌", "Manage Drime tokens"),
            destination: URL(string: "https://app.drime.cloud/account-settings")!)
          Text(
            T(
              "請提供檔案與資料夾讀寫權限。移除本機連線不會撤銷其他裝置使用的權杖；可在 Drime 個別撤銷。",
              "请提供文件与文件夹读写权限。移除本机连接不会撤销其他设备使用的令牌；可在 Drime 单独撤销。",
              "Allow Files and Folders read/write access. Removing this device's connection does not revoke tokens used on other devices. Revoke individual tokens on Drime."
            )
          ).font(.caption)
        }
        if connection.s3 != nil {
          DisclosureGroup(T("臨時憑證（選填）", "临时凭证（选填）", "Session token (optional)")) {
            SecureField(T("臨時憑證", "临时凭证", "Session token"), text: $token)
          }
        }
        if let error { Text(error).foregroundStyle(.red) }
        Button(T("驗證並儲存", "验证并保存", "Verify and save")) {
          guard !busy else { return }
          busy = true
          error = nil
          Task {
            defer { busy = false }
            do {
              let service = try MobileEnvironment.service()
              try await service.updateCredentials(
                connectionID: connection.id, username: username, password: password,
                sessionToken: token.isEmpty ? nil : token)
              password = ""
              token = ""
              for location in try await service.configuration().locations
              where location.connectionID == connection.id && location.removedPath == nil {
                await MobileEnvironment.didUnlock(location.id)
              }
              await completion()
              dismiss()
            } catch { self.error = MobileMessage.describe(error) }
          }
        }.disabled(busy || password.isEmpty)
      }
      .navigationTitle(T("登入設定", "登录设置", "Sign-in settings"))
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
      .onAppear { username = connection.username }
    }.interactiveDismissDisabled(busy)
  }
}
