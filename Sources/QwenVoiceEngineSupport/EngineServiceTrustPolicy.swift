import Foundation

public enum EngineServiceTrustPolicy {
    public static let appBundleIdentifier = "com.qwenvoice.app"
    public static let teamIdentifierInfoKey = "QwenVoiceTeamIdentifier"

    public static func codeSigningRequirement(
        bundleIdentifier: String = QwenVoiceEngineServiceBundleIdentifier
    ) -> String {
        serviceRequirement(bundleIdentifier: bundleIdentifier)
    }

    public static func serviceRequirementForCurrentBundle(
        bundle: Bundle = .main,
        bundleIdentifier: String = QwenVoiceEngineServiceBundleIdentifier
    ) -> String {
        serviceRequirement(
            bundleIdentifier: bundleIdentifier,
            teamIdentifier: bundledTeamIdentifier(bundle: bundle)
        )
    }

    public static func serviceRequirement(
        bundleIdentifier: String = QwenVoiceEngineServiceBundleIdentifier,
        teamIdentifier: String? = nil
    ) -> String {
        requirement(
            forAllowedBundleIdentifiers: [bundleIdentifier],
            teamIdentifier: teamIdentifier
        )
    }

    public static func clientRequirement(teamIdentifier: String? = nil) -> String {
        return requirement(
            forAllowedBundleIdentifiers: [appBundleIdentifier],
            teamIdentifier: teamIdentifier
        )
    }

    public static func clientRequirementForCurrentBundle(bundle: Bundle = .main) -> String {
        clientRequirement(teamIdentifier: bundledTeamIdentifier(bundle: bundle))
    }

    public static func bundledTeamIdentifier(
        bundle: Bundle = .main,
        infoKey: String = teamIdentifierInfoKey
    ) -> String? {
        normalizedTeamIdentifier(bundle.object(forInfoDictionaryKey: infoKey) as? String)
    }

    private static func requirement(
        forAllowedBundleIdentifiers bundleIdentifiers: [String],
        teamIdentifier: String?
    ) -> String {
        let identifierClause = bundleIdentifiers
            .map { identifier in
                "identifier \"\(escape(identifier))\""
            }
            .joined(separator: " or ")

        let scopedIdentifierClause: String
        if bundleIdentifiers.count > 1 {
            scopedIdentifierClause = "(\(identifierClause))"
        } else {
            scopedIdentifierClause = identifierClause
        }

        guard let teamIdentifier = normalizedTeamIdentifier(teamIdentifier) else {
            return scopedIdentifierClause
        }

        return "\(scopedIdentifierClause) and certificate leaf[subject.OU] = \"\(escape(teamIdentifier))\""
    }

    private static func normalizedTeamIdentifier(_ teamIdentifier: String?) -> String? {
        guard let teamIdentifier = teamIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !teamIdentifier.isEmpty,
              !teamIdentifier.contains("$(") else {
            return nil
        }
        return teamIdentifier
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
    }
}
