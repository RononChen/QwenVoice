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

/// Active-tab background pill.
///
/// R2 (2026-05-21): rewritten to match `app.css` `.vc-tab-btn-pill` +
/// the per-tab tint formula in `chrome.jsx`:
///
///   background:  color-mix(tint 12 %, rgba(255,255,255,0.02))
///   border:      0.5pt color-mix(tint 38 %, transparent)
///   inset hi:    rgba(255,255,255,0.08) from top
///   shadow:      0 2 6 / rgba(0,0,0,0.25)
///
/// The earlier version stacked a full Liquid-Glass tinted surface on
/// top of a neutral glass fill and crowned it with a `tint @ 0.42`
/// stroke — vivid enough that even the silver-tinted Voices /
/// Settings tabs read as cool blue badges. The new recipe pulls the
/// pill back to a quiet hue-tinted glass.
private struct TabDockSelectionBackground: View {
    let tint: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

        // Background: 12 % tint over a near-transparent white film so
        // the hue reads but the surface stays glassy on the dock.
        let baseFill = shape
            .fill(Color.white.opacity(0.02))
            .overlay {
                shape.fill(tint.opacity(0.12))
            }

        // Stroke: 38 % tint outline. Half-point hairline.
        let stroke = shape
            .stroke(tint.opacity(0.38), lineWidth: 0.5)

        // Inset white highlight from the top edge, masked by a
        // top-down gradient so it reads as a 1-pixel light source.
        let insetHighlight = shape
            .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            .mask(
                LinearGradient(
                    colors: [.white, .clear],
                    startPoint: .top,
                    endPoint: .center
                )
            )

        if reduceTransparency {
            baseFill
                .overlay { stroke }
                .overlay { insetHighlight }
        } else {
            baseFill
                .glassEffect(.regular.interactive(), in: shape)
                .overlay { stroke }
                .overlay { insetHighlight }
                .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 2)
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
        // R2 (2026-05-21): SF Symbols closest to the design glyphs in
        // `design_references/Vocello iOS/icons.jsx`:
        //   IconStudio   = 5 rounded bars rising to a peak  → "waveform"
        //                  (was "waveform.badge.mic" which carries a mic
        //                  badge and reads as recording, not composing)
        //   IconVoices   = two stylized speaker silhouettes → "person.2.fill"
        //                  (was "person.wave.2.fill" which adds a sound wave
        //                  the design doesn't carry)
        //   IconHistory  = clock with rewind hint           → "clock.arrow.circlepath"
        //   IconSettings = 6-tooth gear with inner circle   → "gearshape"
        switch self {
        case .studio: return "waveform"
        case .voices: return "person.2.fill"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

// `IOSGenerationSection.mode` already exists in `IOSRootNavigationModels.swift`;
// no extension needed here.
