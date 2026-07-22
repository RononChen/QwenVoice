import Foundation

/// Runtime lookup for user-facing strings that flow through view-model or
/// reusable-view `String` properties instead of SwiftUI's `LocalizedStringKey`
/// overloads. Source strings remain the English fallback.
enum AppLocalization {
    /// Captured once for the life of the process. Settings writes the next
    /// launch preference, which avoids partially changing an open window tree.
    static let requestedLanguage = AppDisplayLanguage.selection(
        from: AppDefaults.store.string(forKey: AppDisplayLanguage.preferenceKey)
    )

    static let localizationIdentifier = requestedLanguage.resolvedLocalizationIdentifier()

    static var locale: Locale {
        Locale(identifier: localizationIdentifier)
    }

    static func string(_ key: String) -> String {
        localizationBundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(
            format: string(key),
            locale: locale,
            arguments: arguments
        )
    }

    static func activity(_ label: String) -> String {
        let localized = string(label)
        guard localized == label,
              label.hasPrefix("Generating "),
              label.hasSuffix("…") else {
            return localized
        }

        let modeStart = label.index(label.startIndex, offsetBy: "Generating ".count)
        let modeEnd = label.index(before: label.endIndex)
        let mode = String(label[modeStart..<modeEnd]).localizedForDisplay
        return format("Generating %@…", mode)
    }

    private static var localizationBundle: Bundle {
        let candidates = localizationIdentifier == AppDisplayLanguage.english.rawValue
            ? [localizationIdentifier]
            : [localizationIdentifier, AppDisplayLanguage.english.rawValue]
        for identifier in candidates {
            if let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle
            }
        }
        return .main
    }
}

extension String {
    var localizedForDisplay: String {
        AppLocalization.string(self)
    }

    var localizedActivityForDisplay: String {
        AppLocalization.activity(self)
    }
}
