import SwiftUI
import QwenVoiceCore

/// Bottom glass dock from `design_references/Vocello iOS/chrome.jsx`
/// (`TabDock`). Custom view rather than `TabView` because the native
/// TabView doesn't ship the mode-tinted accent rail behavior the design
/// uses on Studio.
///
/// Selection lives on `AppModel.tab`. The Studio tab takes the
/// currently-selected mode color; the other tabs use a fixed neutral
/// accent.
struct TabDock: View {
    @Environment(AppModel.self) private var appModel

    @ScaledMetric(relativeTo: .body) private var horizontalPadding: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var topPadding: CGFloat = 8
    @ScaledMetric(relativeTo: .body) private var bottomPadding: CGFloat = 10
    @ScaledMetric(relativeTo: .body) private var railPadding: CGFloat = 8
    @ScaledMetric(relativeTo: .body) private var railRadius: CGFloat = 30

    private var dockTint: Color {
        switch appModel.tab {
        case .studio:
            return Theme.Brand.modeColor(appModel.studioMode.mode)
        case .voices, .history:
            return Theme.Brand.silver
        case .settings:
            return Theme.Brand.silver
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(IOSAppTab.allCases) { tab in
                    TabDockButton(
                        tab: tab,
                        isSelected: appModel.tab == tab,
                        action: { select(tab) }
                    )
                }
            }
            .padding(railPadding)
            .frame(maxWidth: .infinity)
            .themeGlassSurface(
                in: RoundedRectangle(cornerRadius: railRadius, style: .continuous),
                tint: dockTint,
                fill: Theme.Surface.glassFloating.opacity(0.68),
                strokeOpacity: 0.12,
                interactive: true
            )
            .sensoryFeedback(.selection, trigger: appModel.tab)
            .padding(.horizontal, horizontalPadding)
            .padding(.top, topPadding)
            .padding(.bottom, bottomPadding)
        }
        .background(
            LinearGradient(
                colors: [
                    Theme.Surface.canvasBottom.opacity(0),
                    Theme.Surface.canvasBottom.opacity(0.88),
                    Theme.Surface.canvasBottom
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    private func select(_ tab: IOSAppTab) {
        guard appModel.tab != tab else { return }
        withAnimation(Theme.Motion.stateChange) {
            appModel.tab = tab
        }
    }
}

// MARK: - Single dock button

private struct TabDockButton: View {
    let tab: IOSAppTab
    let isSelected: Bool
    let action: () -> Void

    @ScaledMetric(relativeTo: .footnote) private var verticalPadding: CGFloat = 10
    @ScaledMetric(relativeTo: .footnote) private var horizontalPadding: CGFloat = 12

    @Environment(AppModel.self) private var appModel

    private var accentTint: Color {
        switch tab {
        case .studio: return Theme.Brand.modeColor(appModel.studioMode.mode)
        case .voices, .history: return Theme.Brand.silver
        case .settings: return Theme.Brand.silver
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                Text(tab.title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Theme.Text.primary : Theme.Text.secondary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background {
                if isSelected {
                    TabDockSelectionBackground(tint: accentTint)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("rootTab_\(tab.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Selected pill background

private struct TabDockSelectionBackground: View {
    let tint: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

        if reduceTransparency {
            shape
                .fill(Theme.glassTint(nil))
                .overlay { shape.stroke(tint.opacity(0.42), lineWidth: 1) }
        } else {
            shape
                .fill(Theme.glassTint(nil))
                .glassEffect(
                    .regular
                        .tint(Theme.glassTint(tint, intensity: 0.9))
                        .interactive(),
                    in: shape
                )
                .overlay { shape.stroke(tint.opacity(0.42), lineWidth: 1) }
        }
    }
}

// MARK: - IOSAppTab presentation helpers

private extension IOSAppTab {
    var title: String {
        switch self {
        case .studio: return "Studio"
        case .voices: return "Voices"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .studio: return "waveform.badge.mic"
        case .voices: return "person.wave.2.fill"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

// `IOSGenerationSection.mode` already exists in `IOSRootNavigationModels.swift`;
// no extension needed here.
