import SwiftUI
import QwenVoiceCore

/// Top-level iOS root view. Replaces the legacy `QVoiceiOSRootView`
/// switch-on-tab tree. Reads everything from the injected `AppModel`
/// and owns the global sheet plumbing:
///
/// - Onboarding `fullScreenCover` gated on `AppModel.isOnboardingPresented`.
/// - Player sheet `sheet(item:)` keyed on `AppModel.playerSheetItem`.
/// - Tab routing via `AppModel.tab`.
/// - Custom `TabDock` at the bottom (no native `TabView`; the design
///   uses a mode-tinted glass dock that doesn't fit `Tab` API).
///
/// Each tab still delegates to its current screen container for Phase
/// 2. Phases 3–5 will progressively replace those bodies with the new
/// screens (StudioScreen, VoicesScreen, HistoryScreen, SettingsScreen).
struct RootView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        // R0 (2026-05-21): RootView now owns the entire app chrome the way
        // `design_references/Vocello iOS/ios-frame.jsx` does in the React
        // prototype:
        //
        //   ZStack:
        //     canvas color           ← `Theme.Surface.canvasBottom`
        //     mode backdrop wash     ← radial gradient, Studio only
        //     activeScreen           ← per-tab body, transparent
        //   safeAreaInset(.bottom):
        //     TabDock                ← single source of truth for the dock
        //
        // The legacy `IOSStudioShellScreen` no longer paints a canopy or its
        // own dock; it just hosts the per-screen body and the engine /
        // now-playing toast safe-area insets.
        ZStack {
            Theme.Surface.canvasBottom
                .ignoresSafeArea()

            if appModel.tab == .studio {
                IOSModeBackdrop(
                    tint: appModel.studioMode.primaryActionTint,
                    intensity: .warm
                )
                .ignoresSafeArea()
                .transition(.opacity)
            }

            activeScreen
        }
        .iosAppAnimation(Theme.Motion.easeOut, value: appModel.tab)
        .iosAppAnimation(Theme.Motion.modePillSlide, value: appModel.studioMode)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TabDock()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(Theme.Brand.gold)
        .overlay {
            if IOSPreviewRuntime.isEnabled {
                IOSPreviewCaptureBridge(
                    selectedTab: appModel.tab,
                    selectedGenerationSection: appModel.studioMode
                )
                .allowsHitTesting(false)
            }
        }
        .environment(\.presentIOSPlayerSheet) { item in
            appModel.playerSheetItem = item
        }
        .fullScreenCover(isPresented: $appModel.isOnboardingPresented) {
            IOSOnboardingFlow(isPresented: $appModel.isOnboardingPresented)
        }
        .sheet(item: $appModel.playerSheetItem) { item in
            IOSPlayerSheet(
                item: item,
                onDismiss: { appModel.playerSheetItem = nil }
            )
            .presentationBackground(Theme.Surface.canvas)
        }
    }

    // MARK: - Tab routing

    @ViewBuilder
    private var activeScreen: some View {
        @Bindable var appModel = appModel

        switch appModel.tab {
        case .studio:
            NavigationStack {
                StudioScreen()
            }
            .toolbar(.hidden, for: .navigationBar)

        case .voices:
            NavigationStack {
                VoicesScreen()
            }
            .toolbar(.hidden, for: .navigationBar)

        case .history:
            NavigationStack {
                HistoryScreen()
            }
            .toolbar(.hidden, for: .navigationBar)

        case .settings:
            NavigationStack {
                SettingsScreen()
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}
