import CloudMountLocalization
import SwiftUI

struct AboutView: View {
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text("CloudMount").font(.title2.bold())
          LabeledContent(T("版本", "版本", "Version"), value: AppInformation.displayVersion)
            .accessibilityIdentifier("appVersion")
          LabeledContent(T("開發", "开发", "Developer"), value: AppInformation.developer)
          LabeledContent("Email") {
            if let url = AppInformation.emailURL {
              Link(AppInformation.email, destination: url)
            } else {
              Text(AppInformation.email)
            }
          }
        }
        Section {
          NavigationLink {
            BrowsingSettingsView()
          } label: {
            Label(T("瀏覽與快取", "浏览与缓存", "Browsing and cache"), systemImage: "photo.on.rectangle")
          }.accessibilityIdentifier("openBrowsingSettings")
          NavigationLink {
            PrivacyPolicyView()
          } label: {
            Label(
              T("隱私權政策", "隐私政策", "Privacy Policy"),
              systemImage: "hand.raised")
          }
          .accessibilityIdentifier("openPrivacyPolicy")
        }
        .textSelection(.enabled)
      }
      .navigationTitle(T("關於 CloudMount", "关于 CloudMount", "About CloudMount"))
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(T("完成", "完成", "Done")) { dismiss() }
        }
      }
    }
  }
}

private struct PrivacyPolicyView: View {
  var body: some View {
    Form {
      Section {
        Text(
          T(
            "CloudMount 連接你自行設定的遠端儲存服務，不經營雲端儲存空間或 CloudMount 開發者帳號服務。",
            "CloudMount 连接你自行配置的远程存储服务，不经营云存储或 CloudMount 开发者账户服务。",
            "CloudMount connects to the remote storage services you configure. We do not operate cloud storage or a CloudMount account service."
          ))
      }
      Section(T("資訊留在你的裝置", "信息保存在你的设备", "Information on your device")) {
        Text(
          T(
            "連線設定與憑證會保存在你的裝置。CloudMount 不會將檔案、保險箱密碼、復原金鑰或連線憑證傳送給開發者。",
            "连接设置和凭据保存在你的设备。CloudMount 不会将文件、保险箱密码、恢复密钥或连接凭据发送给开发者。",
            "Connection settings and credentials are stored on your device. CloudMount does not send your files, vault passwords, recovery phrases, or connection credentials to the developer."
          ))
      }
      Section(T("你選擇的儲存服務", "你选择的存储服务", "Storage services you choose")) {
        Text(
          T(
            "瀏覽、編輯或上傳時，App 會將所需請求與檔案資料傳送到你選擇的服務。該服務依自己的隱私政策處理資料。",
            "浏览、编辑或上传时，App 会将所需请求和文件数据发送到你选择的服务。该服务根据自己的隐私政策处理数据。",
            "When you browse, edit, or upload files, the app sends the necessary requests and file data to the service you choose. That service handles the data under its own privacy policy."
          ))
      }
      Section(T("診斷與追蹤", "诊断与跟踪", "Diagnostics and tracking")) {
        Text(
          T(
            "CloudMount 不含廣告追蹤器或開發者分析服務。診斷資料保存在本機，除非你選擇提供給支援人員。Apple 可能依裝置設定收集診斷資料。",
            "CloudMount 不含广告跟踪器或开发者分析服务。诊断信息保存在本地，除非你选择提供给支持人员。Apple 可能根据设备设置收集诊断信息。",
            "CloudMount has no advertising tracker or developer analytics service. Diagnostics stay on your device unless you choose to share them with support. Apple may collect diagnostics according to your device settings."
          ))
      }
      Section(T("檔案與加密保險箱", "文件与加密保险箱", "Files and encrypted vaults")) {
        Text(
          T(
            "保險箱檔案會在裝置上以 Cryptomator 格式加密後再上傳。匯出到其他 App 的副本由該 App 處理。移除連線不會刪除遠端檔案。",
            "保险箱文件会在设备上以 Cryptomator 格式加密后再上传。导出到其他 App 的副本由该 App 处理。移除连接不会删除远程文件。",
            "Vault files are encrypted on your device in the Cryptomator format before upload. Copies exported to other apps are handled by those apps. Removing a connection does not delete remote files."
          ))
      }
      Section(T("聯絡方式", "联系方式", "Contact")) {
        if let url = AppInformation.emailURL {
          Link(AppInformation.email, destination: url)
        } else {
          Text(AppInformation.email)
        }
      }
    }
    .navigationTitle(T("隱私權政策", "隐私政策", "Privacy Policy"))
  }
}
