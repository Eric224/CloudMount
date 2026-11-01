import Foundation

/// Read the installed bundle's release data. Build scripts populate every platform
/// from Release.json so the visible information and signed manifests stay aligned.
public enum AppInformation {
  public static var version: String { value("CFBundleShortVersionString") }
  public static var build: String { value("CFBundleVersion") }
  public static var developer: String { value("CloudMountDeveloper") }
  public static var email: String { value("CloudMountEmail") }
  public static var displayVersion: String { "\(version) (\(build))" }
  public static var emailURL: URL? { URL(string: "mailto:" + email) }
  private static func value(_ key: String) -> String {
    Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "—"
  }
}
