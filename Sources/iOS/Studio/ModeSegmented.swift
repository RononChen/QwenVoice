import SwiftUI
import QwenVoiceCore

/// Animated 3-way pill that switches between Studio modes
/// (Custom / Design / Clone).
///
/// Mirrors `design_references/Vocello iOS/chrome.jsx` `ModeSegmented` +
/// `app.css` `.vc-mode-segmented` exactly:
///
/// - Rail (the wrapping capsule): neutral `rgba(255,255,255,0.04)` fill
///   with a `0.5pt` `rgba(255,255,255,0.08)` stroke. Height 44pt, 4pt
///   internal padding.
/// - Segment label: 15pt SF Pro semibold. Inactive `fg-2`, active
///   `fg-1`.
/// - Moving pill (the active-segment background): mode-tinted at low
///   percent — `tint @ 22%` fill, `tint @ 36%` stroke, plus a subtle
///   inset white highlight per the CSS box-shadow.
///
/// The earlier implementation used `iosSelectorPillGlass(tint:)` which
/// piled a full Liquid-Glass surface tinted by the mode color on top
/// of the rail; that read as a loud halo and didn't match the
/// reference screenshots. Per the May 2026 UI audit (R0 batch) the
/// rail is now neutral and only the moving pill carries the mode hue.
///
/// Reads + writes `AppModel.studioMode`.
struct ModeSegmented: View {
    @Bindable var appModel: AppModel

    @Namespace private var selectionPillNamespace

    private let railFill: Color = .white.opacity(0.04)
    private let railStroke: Color = .white.opacity(0.08)

    var body: some View {
        HStack(spacing: 4) {
            ForEach(IOSGenerationSection.allCases) { section in
                Button {
                    select(section)
                } label: {
                    Text(section.compactTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                        .foregroundStyle(
                            section == appModel.studioMode
                                ? Theme.Text.primary
                                : Theme.Text.secondary
                        )
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 36)
                        .padding(.horizontal, 4)
                        .background {
                            if section == appModel.studioMode {
                                ModeSegmentedPill(tint: section.primaryActionTint)
                                    .matchedGeometryEffect(
                                        id: "selectionPill",
                                        in: selectionPillNamespace
                                    )
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("studioMode_\(section.rawValue)")
                .accessibilityAddTraits(section == appModel.studioMode ? .isSelected : [])
            }
        }
        .iosAppAnimation(Theme.Motion.modePillSlide, value: appModel.studioMode)
        .padding(4)
        .background {
            Capsule(style: .continuous)
                .fill(railFill)
        }
        .overlay {
            Capsule(style: .continuous)
                .stroke(railStroke, lineWidth: 0.5)
        }
        .frame(height: 44)
        .sensoryFeedback(.selection, trigger: appModel.studioMode)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studioModeSelector")
    }

    private func select(_ section: IOSGenerationSection) {
        guard section != appModel.studioMode else { return }
        withAnimation(Theme.Motion.modePillSlide) {
            appModel.studioMode = section
        }
    }
}

/// The moving pill. Mode-tinted at low percent so it reads as
/// hue-tinted glass, not a saturated highlight.
///
/// Per `app.css` `.vc-mode-pill`:
///   background: color-mix(in oklch, {tint} 22%, transparent)
///   border:     color-mix(in oklch, {tint} 36%, transparent)
///   box-shadow: 0 1px 2px rgba(0,0,0,0.15),
///               inset 0 1px 0 rgba(255,255,255,0.10)
private struct ModeSegmentedPill: View {
    let tint: Color

    var body: some View {
        let shape = Capsule(style: .continuous)
        shape
            .fill(tint.opacity(0.22))
            .overlay {
                shape.stroke(tint.opacity(0.36), lineWidth: 0.5)
            }
            .overlay(alignment: .top) {
                shape
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                    .mask(
                        LinearGradient(
                            colors: [.white, .clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
            }
            .shadow(color: .black.opacity(0.15), radius: 1, x: 0, y: 1)
    }
}
