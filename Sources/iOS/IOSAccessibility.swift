import SwiftUI
import UIKit

private struct IOSReduceMotionEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

private struct IOSReduceTransparencyEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var iosReduceMotionEnabled: Bool {
        get { self[IOSReduceMotionEnabledKey.self] }
        set { self[IOSReduceMotionEnabledKey.self] = newValue }
    }

    var iosReduceTransparencyEnabled: Bool {
        get { self[IOSReduceTransparencyEnabledKey.self] }
        set { self[IOSReduceTransparencyEnabledKey.self] = newValue }
    }
}

// iOS counterpart to the macOS `appAnimation` helper at
// Sources/Views/Components/AppTheme.swift. Honors Reduce Motion via the
// SwiftUI environment so animations are skipped when the user has the
// accessibility setting enabled. AGENTS.md requires Reduce Motion to be
// honored across the app.

extension View {
    func iosAppAnimation<Value: Equatable>(_ animation: Animation?, value: Value) -> some View {
        modifier(IOSAccessibleAnimationModifier(animation: animation, value: value))
    }

    /// Apply `accessibilityIdentifier` only when an id is provided. Lets a view
    /// take an optional id without the caller branching.
    @ViewBuilder
    func iosAccessibilityIdentifier(_ id: String?) -> some View {
        if let id {
            accessibilityIdentifier(id)
        } else {
            self
        }
    }

    /// Attach a screen-presence accessibility marker as a hidden 1pt LEAF element.
    ///
    /// UI tests wait on screen ids (e.g. `screen_generateStudio`, `screen_customVoice`)
    /// to know a surface is up. The previous approach —
    /// `.accessibilityElement(children: .contain).accessibilityIdentifier("screen_…")` on
    /// the whole screen container — propagated that identifier onto descendant elements,
    /// shadowing their own stable ids (`textInput_*`, `studioChip_*`) and forcing tests into
    /// brittle label/hierarchy fallbacks. A dedicated leaf marker is queryable by
    /// `waitForExistence` without touching the descendants, so child ids stay addressable.
    func screenPresenceMarker(_ identifier: String) -> some View {
        background(alignment: .topLeading) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityIdentifier(identifier)
        }
    }
}

private struct IOSAccessibleAnimationModifier<Value: Equatable>: ViewModifier {
    let animation: Animation?
    let value: Value
    @Environment(\.iosReduceMotionEnabled) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

@MainActor
enum IOSAccessibleAnimation {
    static func perform<R>(_ animation: Animation?, _ block: () -> R) -> R {
        let shouldReduceMotion = UIAccessibility.isReduceMotionEnabled || IOSAppDefaults.reduceMotionEnabled
        let resolved = shouldReduceMotion ? nil : animation
        return withAnimation(resolved, block)
    }
}
