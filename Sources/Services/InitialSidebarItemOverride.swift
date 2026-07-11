import Foundation

/// Runtime-debug-only selector for a deterministic initial macOS app surface.
///
/// Computer Use diagnostics use this to avoid inheriting the last persisted
/// sidebar selection. Production launches ignore the environment value unless
/// `DebugMode` is active.
enum InitialSidebarItemOverride: String, Equatable {
    static let environmentKey = "QWENVOICE_INITIAL_SIDEBAR_ITEM"

    case settings
    case history
    case custom

    static func resolve(
        environment: [String: String],
        debugModeEnabled: Bool
    ) -> Self? {
        guard debugModeEnabled,
              let rawValue = environment[environmentKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
              !rawValue.isEmpty else {
            return nil
        }
        return Self(rawValue: rawValue)
    }
}
