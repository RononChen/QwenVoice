import Foundation

/// App-owned UI language preference for the macOS target.
///
/// This setting is intentionally independent from speech-language selection.
/// It only chooses the localization bundle and SwiftUI locale used by Vocello's
/// interface.
enum AppDisplayLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case german = "de"
    case french = "fr"
    case russian = "ru"
    case portuguese = "pt"
    case spanish = "es"
    case italian = "it"

    static let preferenceKey = "vocello.interfaceLanguage.v1"

    var id: String { rawValue }

    /// Language names stay in their own language so the picker remains usable
    /// even after an accidental selection.
    var nativeDisplayName: String {
        switch self {
        case .system: ""
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .english: "English"
        case .japanese: "日本語"
        case .german: "Deutsch"
        case .french: "Français"
        case .russian: "Русский"
        case .portuguese: "Português"
        case .spanish: "Español"
        case .italian: "Italiano"
        }
    }

    static var localizationIdentifiers: [String] {
        allCases.compactMap { language in
            language == .system ? nil : language.rawValue
        }
    }

    static func selection(from storedValue: String?) -> AppDisplayLanguage {
        storedValue.flatMap(AppDisplayLanguage.init(rawValue:)) ?? .system
    }

    func resolvedLocalizationIdentifier(
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        guard self == .system else { return rawValue }

        return Bundle.preferredLocalizations(
            from: Self.localizationIdentifiers,
            forPreferences: preferredLanguages
        ).first ?? AppDisplayLanguage.english.rawValue
    }
}
