import SwiftUI
import QwenVoiceCore

/// Unified Studio surface from design_references/Vocello iOS/studio.jsx.
/// Lays out (top → bottom): composer pad, setup-chip row, dock area with
/// idle / generating / complete states. The composer + meta + counter
/// match the design exactly; the dock area carries the Generate CTA,
/// the generating waveform, or the inline player depending on
/// `genState`.
///
/// Per-mode views provide the setup-chip row content via the
/// `setupChips` view builder and own the actual generation logic
/// through the closures. The canvas is stateless from a generation
/// point of view; it just renders the current `genState`.
struct IOSStudioCanvas<SetupChips: View>: View {
    let mode: GenerationMode
    @Binding var script: String
    let placeholder: String
    let modeMetaLabel: String
    let charLimit: Int
    let tint: Color
    let genState: IOSStudioGenState
    let canGenerate: Bool
    let modelInstalled: Bool
    let modelDisplayName: String
    let setupChips: SetupChips
    let onGenerate: () -> Void
    let onCancel: () -> Void
    let onInstallModel: () -> Void
    let onPlayerDismiss: () -> Void
    let onPlayerExpand: (() -> Void)?

    init(
        mode: GenerationMode,
        script: Binding<String>,
        placeholder: String,
        modeMetaLabel: String,
        charLimit: Int = 800,
        tint: Color,
        genState: IOSStudioGenState,
        canGenerate: Bool,
        modelInstalled: Bool,
        modelDisplayName: String,
        @ViewBuilder setupChips: () -> SetupChips,
        onGenerate: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onInstallModel: @escaping () -> Void,
        onPlayerDismiss: @escaping () -> Void,
        onPlayerExpand: (() -> Void)? = nil
    ) {
        self.mode = mode
        self._script = script
        self.placeholder = placeholder
        self.modeMetaLabel = modeMetaLabel
        self.charLimit = charLimit
        self.tint = tint
        self.genState = genState
        self.canGenerate = canGenerate
        self.modelInstalled = modelInstalled
        self.modelDisplayName = modelDisplayName
        self.setupChips = setupChips()
        self.onGenerate = onGenerate
        self.onCancel = onCancel
        self.onInstallModel = onInstallModel
        self.onPlayerDismiss = onPlayerDismiss
        self.onPlayerExpand = onPlayerExpand
    }

    @FocusState private var isScriptFocused: Bool

    var body: some View {
        ZStack {
            IOSModeBackdrop(tint: tint, intensity: .warm)

            VStack(alignment: .leading, spacing: 14) {
                composerPad
                setupRow
                dockArea
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .iosAppAnimation(IOSDesignMotion.stateChange, value: genState)
    }

    // MARK: - Composer pad

    private var composerPad: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if script.isEmpty {
                    Text(placeholder)
                        .font(.system(.body))
                        .foregroundStyle(IOSAppTheme.textTertiary)
                        .padding(.top, 12)
                        .padding(.horizontal, 14)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $script)
                    .focused($isScriptFocused)
                    .font(.system(.body))
                    .foregroundStyle(IOSAppTheme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(minHeight: 132)
                    .accessibilityIdentifier("textInput_textEditor")
            }
            .background {
                RoundedRectangle(cornerRadius: IOSCornerRadius.card, style: .continuous)
                    .fill(IOSAppTheme.glassSurfaceFillMuted.opacity(0.62))
            }
            .overlay {
                RoundedRectangle(cornerRadius: IOSCornerRadius.card, style: .continuous)
                    .stroke(
                        isScriptFocused ? tint.opacity(0.34) : Color.white.opacity(0.10),
                        lineWidth: isScriptFocused ? 1.0 : 0.8
                    )
            }
            .onChange(of: script) { _, newValue in
                let cap = charLimit + 200
                if newValue.count > cap {
                    script = String(newValue.prefix(cap))
                }
            }

            HStack {
                Text(modeMetaLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(IOSAppTheme.textTertiary)
                Spacer()
                Text("\(script.count) / \(charLimit)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(script.count > charLimit ? Color.orange : IOSAppTheme.textSecondary)
                    .accessibilityIdentifier("textInput_lengthCount")
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Setup row

    private var setupRow: some View {
        HStack(alignment: .top, spacing: 10) {
            setupChips
        }
    }

    // MARK: - Dock area

    @ViewBuilder
    private var dockArea: some View {
        switch genState {
        case .idle where !modelInstalled:
            installCTA
        case .idle:
            generateCTA
        case .generating:
            generatingBar
        case .complete(let item):
            IOSStudioInlinePlayerCard(
                item: item,
                tint: tint,
                onDismiss: onPlayerDismiss,
                onExpand: onPlayerExpand
            )
        }
    }

    private var installCTA: some View {
        Button(action: onInstallModel) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text("Install \(modelDisplayName)")
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(IOSAppTheme.accentForeground)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background {
                Capsule(style: .continuous)
                    .fill(LinearGradient(colors: [tint, tint.opacity(0.78)], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay {
                Capsule(style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 0.8)
            }
            .shadow(color: tint.opacity(0.30), radius: 14, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("textInput_installModelButton")
    }

    private var generateCTA: some View {
        IOSPrimaryCTAButton(
            title: "Generate",
            symbol: "sparkles",
            tint: tint,
            isEnabled: canGenerate,
            action: {
                IOSHaptics.impact(.medium)
                onGenerate()
            }
        )
        .accessibilityIdentifier("textInput_generateButton")
    }

    private var generatingBar: some View {
        HStack(spacing: 10) {
            IOSWaveformBars(
                seed: 42,
                barCount: 28,
                tint: tint,
                progress: 1.0,
                isAnimating: true
            )
            .frame(height: 32)

            VStack(alignment: .trailing, spacing: 2) {
                Text("Generating")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IOSAppTheme.textPrimary)
                Text(generatingSubline)
                    .font(.system(size: 11))
                    .foregroundStyle(IOSAppTheme.textSecondary)
            }

            Button {
                onCancel()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IOSAppTheme.textPrimary)
                    .frame(width: 36, height: 36)
                    .background {
                        Circle().fill(IOSAppTheme.glassSurfaceFillMuted.opacity(0.7))
                    }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("textInput_cancelButton")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: IOSCornerRadius.card, style: .continuous)
                .fill(IOSAppTheme.glassSurfaceFillMuted.opacity(0.55))
        }
        .overlay {
            RoundedRectangle(cornerRadius: IOSCornerRadius.card, style: .continuous)
                .stroke(tint.opacity(0.28), lineWidth: 0.9)
        }
    }

    private var generatingSubline: String {
        switch mode {
        case .custom: return "Rendering audio…"
        case .design: return "Designing voice…"
        case .clone: return "Cloning voice…"
        }
    }
}

// MARK: - Generation state

enum IOSStudioGenState: Equatable {
    case idle
    case generating
    case complete(IOSStudioInlinePlayerItem)
}

struct IOSStudioInlinePlayerItem: Equatable {
    let audioURL: URL
    let voiceName: String
    let modeLabel: String
    let mode: GenerationMode
    let transcript: String
    let waveformSeed: Int

    static func == (lhs: IOSStudioInlinePlayerItem, rhs: IOSStudioInlinePlayerItem) -> Bool {
        lhs.audioURL == rhs.audioURL
    }
}
