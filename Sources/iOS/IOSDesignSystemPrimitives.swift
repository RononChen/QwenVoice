import SwiftUI
import UIKit
import QwenVoiceCore

// Primitives introduced by the May 2026 Vocello iOS redesign reference.
// Lives alongside `IOSShellPrimitives.swift`; that file holds the
// older chrome (cards, badges, status strips). This one holds the new
// shared building blocks used by the unified Studio, the Player sheet, the
// Voices tab, and the bottom-sheet family.
//
// Token sources:
// - design_references/Vocello iOS/tokens.css (--radius-*, --space-*, --ease-out)
// - design_references/Vocello Design System/colors_and_type.css (colors,
//   shadows, surface ramp, stroke values)

// MARK: - Corner radii

enum IOSCornerRadius {
    static let chip: CGFloat = 8
    static let input: CGFloat = 10
    static let card: CGFloat = 16
    static let stage: CGFloat = 22
    static let sheetGrabber: CGFloat = 3
    // Pill / capsule shape uses Capsule(); 999 in design = continuous capsule.
}

// MARK: - Motion timing

enum IOSDesignMotion {
    /// 220ms ease-out (cubic-bezier 0.22, 1, 0.36, 1). Default sheet + state
    /// transition timing per `tokens.css` --dur-default / --ease-out.
    static let sheetReveal = Animation.timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.22)
    /// 360ms ease-out for bottom-sheet slide-up.
    static let sheetSlideUp = Animation.timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.36)
    /// 420ms ease-out for full-screen Player sheet slide-up.
    static let playerSheetSlideUp = Animation.timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.42)
    /// 320ms for mode-segmented pill slide.
    static let modePillSlide = Animation.timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.32)
    /// 150ms ease-out for state changes (chip selection, focus).
    static let stateChange = Animation.easeOut(duration: 0.15)
}

// MARK: - Mode backdrop

/// Warm mode-tinted wash behind the Studio + Player sheet. Anchored to
/// the top of the container; fades to clear by mid-screen. Mirrors
/// `.vc-mode-backdrop` (`design_references/Vocello iOS/app.css:36-48`),
/// including the CSS `mix-blend-mode: plus-lighter` semantics via
/// `.blendMode(.plusLighter)`.
struct IOSModeBackdrop: View {
    let tint: Color
    let intensity: Intensity

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    enum Intensity {
        case whisper
        case warm
        case loud

        /// Top-edge opacity for the tint stop in the linear gradient.
        /// Calibrated against the reference image: at 0.45 (warm) the
        /// gold tint reads as a subtle warm wash at the top quarter,
        /// fading to dark grey by mid-screen — matches the design's
        /// intensity-warm behavior against the `#161823` canvas base.
        var topOpacity: Double {
            switch self {
            case .whisper: return 0.25
            case .warm:    return 0.45
            case .loud:    return 0.70
            }
        }
    }

    init(tint: Color, intensity: Intensity = .warm) {
        self.tint = tint
        self.intensity = intensity
    }

    var body: some View {
        if reduceTransparency {
            // Flat fallback — design system requires opaque alternatives.
            IOSBrandTheme.canvasTop
                .ignoresSafeArea()
        } else {
            GeometryReader { proxy in
                let radius = max(proxy.size.width * 0.72, proxy.size.height * 0.52)

                ZStack {
                    IOSBrandTheme.canvasTop
                    RadialGradient(
                        stops: [
                            .init(color: tint.opacity(intensity.topOpacity), location: 0.0),
                            .init(color: tint.opacity(intensity.topOpacity * 0.42), location: 0.34),
                            .init(color: .clear, location: 0.62)
                        ],
                        center: UnitPoint(x: 0.5, y: 0.0),
                        startRadius: 0,
                        endRadius: radius
                    )
                    .scaleEffect(x: 1.55, y: 0.92, anchor: .top)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
                }
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - Waveform bars

enum IOSStableVisualHash {
    static func int(_ value: String) -> Int {
        Int(truncatingIfNeeded: fnv1a64(value))
    }

    static func normalized(_ value: String) -> Double {
        Double(fnv1a64(value) % 10_000) / 10_000.0
    }

    private static func fnv1a64(_ value: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return hash
    }
}

/// Static or playback-driven waveform bars. Deterministic heights from a
/// seed so repeated renders match. Used by mini-waveform thumbnails
/// (History rows), the inline player in Studio, and the full Player sheet.
///
/// Per `design_references/Vocello iOS/chrome.jsx` MiniWaveform / PlayerWaveform.
struct IOSWaveformBars: View {
    let seed: Int
    let barCount: Int
    let tint: Color
    let progress: Double
    let isAnimating: Bool
    let unplayedColor: Color?

    init(
        seed: Int,
        barCount: Int = 24,
        tint: Color,
        progress: Double = 1.0,
        isAnimating: Bool = false,
        unplayedColor: Color? = nil
    ) {
        self.seed = seed
        self.barCount = barCount
        self.tint = tint
        self.progress = progress
        self.isAnimating = isAnimating
        self.unplayedColor = unplayedColor
    }

    var body: some View {
        if isAnimating {
            TimelineView(.animation) { context in
                bars(phase: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            bars(phase: 0)
        }
    }

    private func bars(phase: TimeInterval) -> some View {
        GeometryReader { geo in
            let spacing: CGFloat = max(1, geo.size.width * 0.012)
            let totalSpacing = spacing * CGFloat(barCount - 1)
            let barWidth = (geo.size.width - totalSpacing) / CGFloat(barCount)
            let progressIndex = Int((Double(barCount) * progress).rounded())

            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    let height = barHeight(at: i, container: geo.size.height, phase: phase)
                    let isPast = i < progressIndex
                    Capsule(style: .continuous)
                        .fill(isPast ? tint : (unplayedColor ?? tint.opacity(0.35)))
                        .frame(width: barWidth, height: height)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
    }

    private func barHeight(at index: Int, container: CGFloat, phase: TimeInterval) -> CGFloat {
        // Deterministic pseudo-random in [0.18, 1.0] from seed + index.
        var x = UInt64(bitPattern: Int64(seed &* 1_000_003 &+ index &* 2_654_435_761))
        x ^= x &>> 33
        x &*= 0xff51_afd7_ed55_8ccd
        x ^= x &>> 33
        x &*= 0xc4ce_b9fe_1a85_ec53
        x ^= x &>> 33
        let normalized = Double(x & 0xffff_ffff) / Double(UInt32.max)
        let base = 0.18 + normalized * 0.82
        var amplitude = base
        if isAnimating {
            let waveA = sin((phase * 2.2 + Double(index) * 0.70))
            let waveB = sin((phase * 1.35 + Double(index) * 1.40))
            amplitude = max(0.06, min(1.0, base * (1 + waveA * 0.18 + waveB * 0.10)))
        }
        return max(2, container * CGFloat(amplitude))
    }
}

// MARK: - Voice avatar

/// Circular gradient avatar for built-in or saved voices. Hue derived from
/// the voice id so the same voice renders the same gradient everywhere.
///
/// Per `design_references/Vocello iOS/chrome.jsx` VoiceAvatar.
struct IOSVoiceAvatar: View {
    let seed: String
    let initials: String
    let diameter: CGFloat

    init(seed: String, initials: String, diameter: CGFloat = 44) {
        self.seed = seed
        let parts = initials.split(separator: " ")
        if parts.count >= 2 {
            self.initials = parts.prefix(2).map { String($0.prefix(1)) }.joined().uppercased()
        } else {
            self.initials = String(initials.prefix(1)).uppercased()
        }
        self.diameter = diameter
    }

    var body: some View {
        let hue = hueForSeed(seed)
        let topColor = Color(hue: hue, saturation: 0.45, brightness: 0.78)
        let bottomColor = Color(hue: hue, saturation: 0.55, brightness: 0.52)

        return ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [topColor, bottomColor],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Circle()
                .stroke(Color.white.opacity(0.10), lineWidth: 0.75)
            Text(initials)
                .font(.system(size: diameter * 0.36, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 13 / 255, green: 14 / 255, blue: 18 / 255).opacity(0.85))
        }
        .frame(width: diameter, height: diameter)
    }

    private func hueForSeed(_ seed: String) -> Double {
        IOSStableVisualHash.normalized(seed)
    }
}

// MARK: - Mode dot

/// 6×6 colored dot used in History row meta + filter chips.
struct IOSModeDot: View {
    let tint: Color
    let diameter: CGFloat

    init(tint: Color, diameter: CGFloat = 6) {
        self.tint = tint
        self.diameter = diameter
    }

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: diameter, height: diameter)
    }
}

// MARK: - Bottom sheet

enum IOSBottomSheetChrome {
    static let background = Color(red: 20 / 255, green: 22 / 255, blue: 30 / 255).opacity(0.92)
    static let cornerRadius: CGFloat = 22
}

/// Reusable bottom sheet container. Drag-to-dismiss via a grabber. Uses the
/// system `.presentationDetents` when presented as a sheet, but the visual
/// chrome (glass surface, grabber, title) is provided here so the look is
/// consistent across pickers.
///
/// Caller wraps in `.sheet(isPresented:)` modifier; this view supplies the
/// content. For drag-to-dismiss the system sheet already handles it.
struct IOSBottomSheet<Content: View>: View {
    let title: String
    let tint: Color
    let onDismiss: (() -> Void)?
    let content: Content

    @Environment(\.dismiss) private var dismiss

    init(
        title: String,
        tint: Color = IOSBrandTheme.accent,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.tint = tint
        self.onDismiss = onDismiss
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            grabber
                .padding(.top, 8)

            header
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 10)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            IOSBottomSheetChrome.background
                .ignoresSafeArea()
        }
        // R3 G.0 (2026-05-21): the per-sheet `IOSModeBackdrop` was a
        // whisper-intensity radial wash that added a hue to every
        // bottom sheet. Design's `.vc-sheet { background: rgba(20,22,
        // 30,0.92) + blur 32 }` is flat translucent dark with no
        // tint — the sheets read cleaner that way and the dock above
        // already carries the mode hue.
    }

    private var grabber: some View {
        // 36 × 5 pt per app.css `.vc-sheet-grabber`.
        Capsule(style: .continuous)
            .fill(IOSAppTheme.textTertiary.opacity(0.45))
            .frame(width: 36, height: 5)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.44)
                .foregroundStyle(IOSAppTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                onDismiss?()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IOSAppTheme.textSecondary)
                    .frame(width: 32, height: 32)
                    .background {
                        Circle()
                            .fill(IOSAppTheme.glassSurfaceFillMuted.opacity(0.6))
                    }
            }
            .accessibilityLabel("Close")
        }
    }
}

// MARK: - Setup chip

/// Two-line setup chip used in Studio. Top line is a tiny eyebrow label
/// (e.g. "Voice"); bottom line is the current value (e.g. "Aiden").
/// Tapping the chip routes to a sheet.
///
/// Per `design_references/Vocello iOS/studio.jsx` setup-chip pattern.
struct IOSStudioSetupChip: View {
    let eyebrow: String
    let value: String
    let leadingSymbol: String?
    let leadingAvatar: AnyView?
    let tint: Color
    let isPlaceholder: Bool
    let action: () -> Void

    init(
        eyebrow: String,
        value: String,
        leadingSymbol: String? = nil,
        leadingAvatar: AnyView? = nil,
        tint: Color = IOSBrandTheme.accent,
        isPlaceholder: Bool = false,
        action: @escaping () -> Void
    ) {
        self.eyebrow = eyebrow
        self.value = value
        self.leadingSymbol = leadingSymbol
        self.leadingAvatar = leadingAvatar
        self.tint = tint
        self.isPlaceholder = isPlaceholder
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                if let leadingAvatar {
                    leadingAvatar
                        .frame(width: 32, height: 32)
                } else if let leadingSymbol {
                    ZStack {
                        Circle()
                            .fill(tint.opacity(0.22))
                            .frame(width: 32, height: 32)
                        Image(systemName: leadingSymbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(eyebrow.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(IOSAppTheme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(value)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isPlaceholder ? IOSAppTheme.textTertiary : IOSAppTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(IOSAppTheme.textTertiary)
                    .padding(.leading, 2)
            }
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.05))
            }
            .overlay {
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Filter chip row

/// Horizontal row of selectable filter chips. Used by Voices, History, and
/// Settings to filter content.
struct IOSFilterChipRow<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selection: Option
    let tint: Color
    let label: (Option) -> String
    let leading: ((Option) -> AnyView)?
    let accessibilityIdentifier: ((Option) -> String)?

    init(
        options: [Option],
        selection: Binding<Option>,
        tint: Color,
        label: @escaping (Option) -> String,
        leading: ((Option) -> AnyView)? = nil,
        accessibilityIdentifier: ((Option) -> String)? = nil
    ) {
        self.options = options
        self._selection = selection
        self.tint = tint
        self.label = label
        self.leading = leading
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options) { option in
                chip(for: option)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private func chip(for option: Option) -> some View {
        let isSelected = option == selection

        return Button {
            withAnimation(IOSDesignMotion.stateChange) {
                selection = option
            }
            IOSHaptics.selection()
        } label: {
            HStack(spacing: 6) {
                if let leading {
                    leading(option)
                }
                Text(label(option))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(isSelected ? IOSAppTheme.textPrimary : IOSAppTheme.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .padding(.horizontal, 12)
            .background {
                Capsule(style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.10) : Color.white.opacity(0.03))
            }
            .overlay {
                Capsule(style: .continuous)
                    .stroke(isSelected ? Color.white.opacity(0.18) : Color.white.opacity(0.10), lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier?(option) ?? "")
    }
}

// MARK: - Search field

/// Compact search field used in Voices + History tabs. Wraps a UIKit-aware
/// SwiftUI TextField with a leading magnifier glass and trailing clear
/// button.
struct IOSSearchField: View {
    @Binding var text: String
    let placeholder: String

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(IOSAppTheme.textTertiary)

            TextField(placeholder, text: $text)
                .focused($isFocused)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .foregroundStyle(IOSAppTheme.textPrimary)
                .font(.system(size: 15))

            if !text.isEmpty {
                Button {
                    text = ""
                    IOSHaptics.selection()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(IOSAppTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
        }
        .iosAppAnimation(IOSDesignMotion.stateChange, value: isFocused)
    }
}

// MARK: - Primary CTA

/// Large gradient button used as the Studio Generate CTA. Tints to the
/// active mode's color; respects Reduce Transparency by falling back to a
/// flat fill.
struct IOSPrimaryCTAButton: View {
    let title: String
    let symbol: String?
    let tint: Color
    let isEnabled: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(
        title: String,
        symbol: String? = nil,
        tint: Color,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: {
            if isEnabled { action() }
        }) {
            HStack(alignment: .center, spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(IOSAppTheme.accentForeground)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background {
                if reduceTransparency || !isEnabled {
                    Capsule(style: .continuous)
                        .fill(isEnabled ? tint : IOSAppTheme.glassSurfaceFillMuted)
                } else {
                    // Matches studio.jsx Generate CTA:
                    //   linear-gradient(180deg, tint 0%,
                    //     color-mix(in oklch, tint 80%, black) 100%)
                    // SwiftUI's Color.mix(with:by:in:) (iOS 18+) gives the
                    // OKLCH darkening; .perceptual is the closest mixing
                    // space SwiftUI exposes.
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    tint,
                                    tint.mix(with: .black, by: 0.20, in: .perceptual)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
            }
            .overlay {
                // border: 0.5px solid rgba(255,255,255,0.18) per .vc-cta
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
            }
            .overlay(alignment: .top) {
                // inset 0 1px 0 rgba(255,255,255,0.25) — top-edge sheen
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.25), lineWidth: 0.6)
                    .mask(
                        LinearGradient(
                            colors: [.white, .clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
            }
            // box-shadow 0 6px 18px rgba(0,0,0,0.30) per .vc-cta
            // (SwiftUI radius ≈ CSS blur / 2 → 9)
            .shadow(color: .black.opacity(isEnabled ? 0.30 : 0), radius: 9, x: 0, y: 6)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1.0 : 0.55)
        .iosAppAnimation(IOSDesignMotion.stateChange, value: isEnabled)
    }
}
