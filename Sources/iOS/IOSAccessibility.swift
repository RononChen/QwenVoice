import SwiftUI
import UIKit

// iOS counterpart to the macOS `appAnimation` helper at
// Sources/Views/Components/AppTheme.swift. Honors Reduce Motion via the
// SwiftUI environment so animations are skipped when the user has the
// accessibility setting enabled. AGENTS.md requires Reduce Motion to be
// honored across the app.

extension View {
    func iosAppAnimation<Value: Equatable>(_ animation: Animation?, value: Value) -> some View {
        modifier(IOSAccessibleAnimationModifier(animation: animation, value: value))
    }
}

private struct IOSAccessibleAnimationModifier<Value: Equatable>: ViewModifier {
    let animation: Animation?
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

@MainActor
enum IOSAccessibleAnimation {
    static func perform<R>(_ animation: Animation?, _ block: () -> R) -> R {
        let resolved = UIAccessibility.isReduceMotionEnabled ? nil : animation
        return withAnimation(resolved, block)
    }
}
