import Foundation

/// The first system language controls the app. Unsupported languages use English,
/// even when Chinese appears later in the user's language preference list.
public enum AppLanguage: String, CaseIterable, Sendable {
  case english = "en"
  case traditionalChinese = "zh-Hant"
  case simplifiedChinese = "zh-Hans"
  public static var current: Self { resolve(Locale.preferredLanguages) }
  public static func resolve(_ preferred: [String]) -> Self {
    guard let first = preferred.first else { return .english }
    let parts = first.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-")
    guard parts.first == "zh" else { return .english }
    if parts.contains("hant") { return .traditionalChinese }
    if parts.contains("hans") { return .simplifiedChinese }
    return parts.contains("cn") || parts.contains("sg") ? .simplifiedChinese : .traditionalChinese
  }
  public var locale: Locale { Locale(identifier: rawValue) }
  public func choose(_ traditional: String, _ simplified: String, _ english: String) -> String {
    switch self {
    case .traditionalChinese: return traditional
    case .simplifiedChinese: return simplified
    case .english: return english
    }
  }
  public func localized(_ key: String, bundle: Bundle = .main, table: String = "Localizable")
    -> String?
  {
    guard let folder = bundle.path(forResource: rawValue, ofType: "lproj"),
      let localized = Bundle(path: folder)
    else { return nil }
    let marker = "__CLOUDMOUNT_UNTRANSLATED__"
    let value = localized.localizedString(forKey: key, value: marker, table: table)
    return value == marker ? nil : value
  }
}
