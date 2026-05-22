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
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @AppStorage(IOSAppDefaults.reduceMotionEnabledKey) private var appReduceMotion = false
    @AppStorage(IOSAppDefaults.reduceTransparencyEnabledKey) private var appReduceTransparency = false

    var body: some View {
        @Bindable var appModel = appModel

        // R0 (2026-05-21): RootView now owns the entire app chrome the way
        // `design_references/Vocello iOS/ios-frame.jsx` does in the React
        // prototype:
        //
        //   ZStack:
        //     tab backdrop wash      ← radial gradient, active tab tint
        //     activeScreen           ← per-tab body, transparent
        //   safeAreaInset(.bottom):
        //     TabDock                ← single source of truth for the dock
        //
        // The legacy `IOSStudioShellScreen` no longer paints a canopy or its
        // own dock; it just hosts the per-screen body and the engine /
        // now-playing toast safe-area insets.
        ZStack {
            IOSModeBackdrop(
                tint: activeBackdropTint,
                intensity: .warm
            )
            .ignoresSafeArea()

            activeScreen
        }
        .iosAppAnimation(Theme.Motion.easeOut, value: appModel.tab)
        .iosAppAnimation(Theme.Motion.modePillSlide, value: appModel.studioMode)
        .environment(\.iosReduceMotionEnabled, effectiveReduceMotion)
        .environment(\.iosReduceTransparencyEnabled, effectiveReduceTransparency)
        // The dock is the only persistent bottom chrome. Playback is
        // presented inline in Studio or through IOSPlayerSheet.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            IOSEngineLifecycleToast()
                .padding(.bottom, 6)
        }
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
        .iosFocusModalBackdrop(
            isActive: isFocusBackdropActive,
            allowsBlur: !effectiveReduceTransparency
        )
        .overlay {
            bottomPanelOverlay
            deleteModelSheetOverlay
        }
        .iosAppAnimation(Theme.Motion.easeOut, value: isFocusBackdropActive)
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
            .presentationDetents([.fraction(0.88)])
            .presentationDragIndicator(.hidden)
            .presentationCornerRadius(28)
            .presentationBackground(Color(red: 13 / 255, green: 14 / 255, blue: 18 / 255).opacity(0.96))
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

    private var activeBackdropTint: Color {
        appModel.tab.dockAccent(studioMode: appModel.studioMode.mode)
    }

    @ViewBuilder
    private var deleteModelSheetOverlay: some View {
        if let item = appModel.deleteModelSheetItem {
            GeometryReader { proxy in
                ZStack(alignment: .bottom) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            dismissDeleteModelSheet()
                        }

                    IOSDeleteModelSheet(
                        modelName: item.modelName,
                        sizeLabel: item.sizeLabel,
                        presentation: .edgeToEdge(bottomSafeAreaInset: proxy.safeAreaInsets.bottom),
                        onConfirm: {
                            item.onConfirm()
                            dismissDeleteModelSheet()
                        },
                        onCancel: {
                            dismissDeleteModelSheet()
                        }
                    )
                    .frame(maxWidth: .infinity)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .ignoresSafeArea()
            }
            .zIndex(20)
        }
    }

    @ViewBuilder
    private var bottomPanelOverlay: some View {
        if let item = appModel.bottomPanelItem {
            GeometryReader { proxy in
                ZStack(alignment: .bottom) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            dismissBottomPanel()
                        }

                    item.content(proxy.safeAreaInsets.bottom, dismissBottomPanel)
                        .frame(maxWidth: .infinity)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .ignoresSafeArea()
            }
            .zIndex(19)
        }
    }

    private var isFocusBackdropActive: Bool {
        appModel.isFocusBackdropPresented
            || appModel.bottomPanelItem != nil
            || appModel.deleteModelSheetItem != nil
    }

    private func dismissDeleteModelSheet() {
        appModel.deleteModelSheetItem = nil
        appModel.isFocusBackdropPresented = false
    }

    private func dismissBottomPanel() {
        appModel.dismissBottomPanel()
    }

    private var effectiveReduceMotion: Bool {
        systemReduceMotion || appReduceMotion
    }

    private var effectiveReduceTransparency: Bool {
        systemReduceTransparency || appReduceTransparency
    }
}

private extension View {
    func iosFocusModalBackdrop(isActive: Bool, allowsBlur: Bool) -> some View {
        blur(radius: isActive && allowsBlur ? 2.4 : 0)
            .overlay {
                if isActive {
                    Color.black
                        .opacity(allowsBlur ? 0.10 : 0.34)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
    }
}
