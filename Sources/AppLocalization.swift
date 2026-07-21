import Foundation

/// Runtime lookup for user-facing strings that flow through view-model or
/// reusable-view `String` properties instead of SwiftUI's `LocalizedStringKey`
/// overloads. Source strings remain the English fallback.
enum AppLocalization {
    static func string(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(
            format: string(key),
            locale: Locale.current,
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
}

extension String {
    var localizedForDisplay: String {
        AppLocalization.string(self)
    }

    var localizedActivityForDisplay: String {
        AppLocalization.activity(self)
    }
}
