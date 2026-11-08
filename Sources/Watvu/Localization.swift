import Foundation

/// Localized string lookup. Prefers the SwiftPM resource bundle (Bundle.module)
/// and falls back to the main bundle so both `swift run` and the packaged .app work.
func L(_ key: String) -> String {
    if let path = Bundle.module.path(forResource: key, ofType: "strings", inDirectory: nil, forLocalization: currentLanguage()),
       let dict = NSDictionary(contentsOfFile: path) as? [String: String],
       let value = dict[key] {
        return value
    }
    if let path = Bundle.main.path(forResource: key, ofType: "strings", inDirectory: nil, forLocalization: currentLanguage()),
       let dict = NSDictionary(contentsOfFile: path) as? [String: String],
       let value = dict[key] {
        return value
    }
    return NSLocalizedString(key, bundle: .main, comment: "")
}

private func currentLanguage() -> String {
    UserDefaults.standard.string(forKey: "appLanguage") ?? Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
}

extension Bundle {
    static func setLanguage(_ language: String) {
        UserDefaults.standard.set([language], forKey: "AppleLanguages")
        UserDefaults.standard.synchronize()
    }
}
