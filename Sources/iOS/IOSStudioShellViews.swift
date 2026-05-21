import SwiftUI

/// Thin per-screen body container.
///
/// History: this used to host the full iOS chrome — `IOSStudioShellCanopy`
/// rendering the "Vocello" wordmark + a memory-indicator accessory at the
/// top, and `IOSStudioRootDock` at the bottom via `safeAreaInset`. R0 of
/// the May 2026 UI audit moved both into `RootView`, so this type is now
/// just a shell around the per-tab body with the now-playing rail +
/// engine-lifecycle toast safe-area insets.
///
/// The cleanup pass that followed R2 also dropped the `Accessory` +
/// `BottomAccessory` generics, the canopy + dock structs, and the
/// `IOSAppTab` extension that powered the legacy dock. Anything you
/// want at the top of every Studio-style screen now lives at
/// `RootView` level; anything you want at the bottom uses the global
/// `safeAreaInset(edge: .bottom)` that hosts the new `TabDock`.
struct IOSStudioShellScreen<Content: View>: View {
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel

    @Binding var selectedTab: IOSAppTab

    let activeTab: IOSAppTab
    let tint: Color
    let screenContent: Content

    @ScaledMetric(relativeTo: .body) private var horizontalPadding = 16
    @ScaledMetric(relativeTo: .body) private var topPadding = 2

    init(
        selectedTab: Binding<IOSAppTab>,
        activeTab: IOSAppTab,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) {
        self._selectedTab = selectedTab
        self.activeTab = activeTab
        self.tint = tint
        self.screenContent = content()
    }

    var body: some View {
        screenContent
            .padding(.horizontal, horizontalPadding)
            .padding(.top, topPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if audioPlayer.isShowingNowPlayingRail {
                    IOSGlobalNowPlayingRail()
                        .padding(.horizontal, horizontalPadding)
                        .padding(.bottom, 6)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                IOSEngineLifecycleToast()
                    .padding(.bottom, 6)
            }
            .iosAppAnimation(IOSSelectionMotion.miniPlayerSlide, value: audioPlayer.isShowingNowPlayingRail)
            .toolbar(.hidden, for: .navigationBar)
    }
}

/// Per-screen page heading (Library, Settings, etc.).
/// Sits at the top of a screen body where the design specifies a
/// large 28-pt title in SF Pro Display.
struct IOSStudioWorkspaceHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title2.weight(.semibold))
            .foregroundStyle(IOSAppTheme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Card-style section wrapper used on Settings + Library surfaces.
/// Wraps a section's content in a glassy rounded surface tinted by
/// the per-tab accent.
struct IOSStudioSectionGroup<Content: View>: View {
    let title: String?
    let tint: Color
    let content: Content

    @ScaledMetric(relativeTo: .body) private var spacing = 10
    @ScaledMetric(relativeTo: .body) private var padding = 14
    @ScaledMetric(relativeTo: .body) private var cornerRadius = 24

    init(
        title: String? = nil,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if let title, !title.isEmpty {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(0.7)
                    .foregroundStyle(IOSAppTheme.textSecondary.opacity(0.92))
            }

            VStack(alignment: .leading, spacing: spacing) {
                content
            }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .iosSectionGlass(tint: tint, cornerRadius: cornerRadius)
        }
    }
}
