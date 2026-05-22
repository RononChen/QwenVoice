import SwiftUI
import UIKit
import QwenVoiceCore

@MainActor
private enum IOSSettingsSupportInfo {
    static var appVersionLabel: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}

@MainActor
private enum IOSSettingsFormatters {
    static let byteCount: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func fileSize(_ bytes: Int64) -> String {
        byteCount.string(fromByteCount: bytes)
    }
}

struct IOSSettingsContainerView: View {
    @Binding var selectedTab: IOSAppTab

    var body: some View {
        IOSSettingsView(selectedTab: $selectedTab)
            .toolbar(.hidden, for: .navigationBar)
    }
}

private struct IOSSettingsView: View {
    @EnvironmentObject private var modelManager: ModelManagerViewModel
    @EnvironmentObject private var modelInstaller: IOSModelInstallerViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @Binding var selectedTab: IOSAppTab
    @AppStorage("autoPlay") private var autoPlay = true

    private var previewSettingsState: IOSPreviewSettingsState? {
        IOSPreviewRuntime.current?.definition.settingsState
    }

    private var installedModelBytes: Int64 {
        TTSModel.all.reduce(0) { total, model in
            guard case let .installed(bytes) = effectiveStatus(for: model) else {
                return total
            }
            return total + Int64(bytes)
        }
    }

    private var storageSummaryText: String {
        installedModelBytes > 0
            ? "\(IOSSettingsFormatters.fileSize(installedModelBytes)) used"
            : "0 GB used"
    }

    var body: some View {
        IOSStudioShellScreen(
            selectedTab: $selectedTab,
            activeTab: .settings,
            tint: IOSAppTab.settings.dockAccent(studioMode: .custom)
        ) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    IOSSettingsReferenceSection(title: "Voice models") {
                        ForEach(TTSModel.all) { model in
                            IOSModelRow(
                                model: model,
                                status: effectiveStatus(for: model),
                                operationState: effectiveOperationState(for: model),
                                onInstall: { install(model) },
                                onCancel: { cancel(model) },
                                onDelete: { delete(model) }
                            )

                            if model.id != TTSModel.all.last?.id {
                                IOSSettingsReferenceDivider()
                            }
                        }
                    }

                    IOSSettingsReferenceSection(title: "Settings") {
                        IOSSettingsReferenceToggleRow(
                            symbol: "play.fill",
                            title: "Autoplay after generate",
                            isOn: $autoPlay,
                            tint: IOSBrandTheme.accent
                        )

                        IOSSettingsReferenceDivider()

                        IOSSettingsReferenceValueRow(
                            symbol: "bookmark",
                            title: "Saved outputs",
                            value: "On My iPhone",
                            showsChevron: true
                        )

                        IOSSettingsReferenceDivider()

                        IOSSettingsReferenceValueRow(
                            symbol: "arrow.down.to.line",
                            title: "Storage",
                            value: storageSummaryText,
                            showsChevron: true
                        )

                        IOSSettingsReferenceDivider()

                        IOSSettingsReferenceStaticToggleRow(
                            symbol: "sparkles",
                            title: "Reduce Motion",
                            isOn: reduceMotion
                        )

                        IOSSettingsReferenceDivider()

                        IOSSettingsReferenceStaticToggleRow(
                            symbol: "lock.fill",
                            title: "Reduce Transparency",
                            isOn: reduceTransparency
                        )
                    }

                    IOSSettingsBrandFooter()
                }
                // Extra bottom padding so the bottom-most section clears
                // the TabDock's gradient fade in RootView.
                .padding(.bottom, 90)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear
                    .frame(height: 118)
            }
        }
        .task {
            await modelManager.refresh()
        }
    }

    private func effectiveOperationState(for model: TTSModel) -> IOSModelInstallerViewModel.OperationState {
        if let previewState = previewSettingsState?.sample(for: model)?.operationState {
            return previewState
        }

        return IOSSimulatorPreviewPolicy.previewOperationState(
            for: model,
            status: effectiveStatus(for: model),
            operationState: modelInstaller.state(for: model)
        )
    }

    private func effectiveStatus(for model: TTSModel) -> ModelManagerViewModel.ModelStatus {
        previewSettingsState?.sample(for: model)?.status
            ?? modelManager.statuses[model.id]
            ?? .checking
    }

    private func install(_ model: TTSModel) {
        if IOSSimulatorRuntimeSupport.isSimulator {
            // UI-test only: run a fake download/install state-machine so
            // testers can exercise the install flow + every downstream
            // installed-model UI state without real model bytes.
            modelInstaller.simulatorFakeInstall(model)
            return
        }
        guard IOSSimulatorPreviewPolicy.allowsModelMutations else { return }
        modelInstaller.install(model)
    }

    private func cancel(_ model: TTSModel) {
        if IOSSimulatorRuntimeSupport.isSimulator {
            modelInstaller.simulatorFakeCancel(model)
            return
        }
        guard IOSSimulatorPreviewPolicy.allowsModelMutations else { return }
        modelInstaller.cancel(model)
    }

    private func delete(_ model: TTSModel) {
        if IOSSimulatorRuntimeSupport.isSimulator {
            modelInstaller.simulatorFakeDelete(model)
            return
        }
        guard IOSSimulatorPreviewPolicy.allowsModelMutations else { return }
        modelInstaller.delete(model)
    }
}

private struct IOSSettingsReferenceSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.88)
                .foregroundStyle(IOSAppTheme.textSecondary)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 6)

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }
}

private struct IOSSettingsUtilityIcon: View {
    let symbol: String

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(0.06))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
            }
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(IOSAppTheme.textPrimary)
            }
            .frame(width: 36, height: 36)
    }
}

private struct IOSSettingsReferenceDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 0.5)
            .padding(.leading, 64)
    }
}

private struct IOSSettingsReferenceSwitch: View {
    let isOn: Bool
    let tint: Color

    var body: some View {
        Capsule(style: .continuous)
            .fill(Color.white.opacity(0.06))
            .overlay {
                if isOn {
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    tint,
                                    tint.mix(with: .black, by: 0.18, in: .perceptual),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
            }
            .overlay {
                Capsule(style: .continuous)
                    .stroke(isOn ? tint.opacity(0.60) : Color.white.opacity(0.10), lineWidth: 0.5)
            }
            .overlay {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.98, green: 0.97, blue: 0.94),
                                Color(red: 0.86, green: 0.84, blue: 0.79),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(color: .black.opacity(isOn ? 0.22 : 0.18), radius: 2, x: 0, y: 1)
                    .frame(width: 21, height: 21)
                    .frame(maxWidth: .infinity, alignment: isOn ? .trailing : .leading)
                    .padding(2)
            }
            .shadow(color: isOn ? tint.opacity(0.18) : .clear, radius: 8, x: 0, y: 2)
            .frame(width: 44, height: 26)
    }
}

private struct IOSSettingsReferenceToggleRow: View {
    let symbol: String
    let title: String
    @Binding var isOn: Bool
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            IOSSettingsUtilityIcon(symbol: symbol)

            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(IOSAppTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                isOn.toggle()
                IOSHaptics.selection()
            } label: {
                IOSSettingsReferenceSwitch(isOn: isOn, tint: tint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isOn ? "On" : "Off")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct IOSSettingsReferenceStaticToggleRow: View {
    let symbol: String
    let title: String
    let isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            IOSSettingsUtilityIcon(symbol: symbol)

            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(IOSAppTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            IOSSettingsReferenceSwitch(
                isOn: isOn,
                tint: IOSBrandTheme.accent
            )
            .accessibilityLabel(title)
            .accessibilityValue(isOn ? "On" : "Off")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct IOSSettingsReferenceValueRow: View {
    let symbol: String
    let title: String
    let value: String
    let showsChevron: Bool

    var body: some View {
        HStack(spacing: 12) {
            IOSSettingsUtilityIcon(symbol: symbol)

            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(IOSAppTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(value)
                .font(.system(size: 14))
                .foregroundStyle(IOSAppTheme.textSecondary)
                .lineLimit(1)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IOSAppTheme.textTertiary)
                    .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct IOSSettingsBrandFooter: View {
    var body: some View {
        VStack(spacing: 2) {
            Image("VocelloLaunchLogo")
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .scaledToFit()
                .frame(width: 180)
                .shadow(color: IOSBrandTheme.accent.opacity(0.18), radius: 14, x: 0, y: 10)
                .accessibilityHidden(true)

            Text(Theme.Branding.version.uppercased())
                .font(.system(size: 11, weight: .medium))
                .tracking(0.66)
                .foregroundStyle(IOSAppTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .opacity(0.78)
    }
}

#if DEBUG
/// Simulator-only debug affordance for seeding a fixture `Generation` row.
///
/// The iOS Simulator stubs out the TTS engine (`IOSSimulatorTTSEngine`),
/// so a real generation never produces a History entry. That makes the
/// full-screen `IOSPlayerSheet` impossible to verify without a real
/// device. This row writes a 5-second silence WAV into `AppPaths.
/// outputsDir`, inserts a `Generation` pointing at it, and posts
/// `.generationSaved` so `IOSHistoryLibrarySection` reloads. The new
/// row appears in History; tapping it presents the Player sheet at
/// the design's centered-header / 42-bar-waveform / real-scrubber /
/// centered-transcript layout.
///
/// Three seed presets cycle the three modes — Custom (gold), Design
/// (lavender), Clone (terracotta) — so the Player sheet's mode tint
/// surface can be verified end-to-end.
private struct IOSSettingsSeedHistoryRow: View {
    @State private var status: String = ""
    @State private var seedIndex: Int = 0

    private struct Seed {
        let mode: String
        let voice: String
        let text: String
        let durationSeconds: Double
    }

    private var seeds: [Seed] {
        [
            Seed(
                mode: "design",
                voice: "British narrator",
                text: "Welcome back to the workshop. Today we are building a small wooden box, end to end. The first thing we need to do is measure twice, and cut once.",
                durationSeconds: 8.5
            ),
            Seed(
                mode: "custom",
                voice: "Aiden",
                text: "Hello, this is a sample preview of my voice, generated entirely on this iPhone.",
                durationSeconds: 6.0
            ),
            Seed(
                mode: "clone",
                voice: "UITestRef",
                text: "I cloned this voice from a short reference clip, and now it can speak any text I write.",
                durationSeconds: 7.0
            ),
        ]
    }

    var body: some View {
        Button {
            seedNext()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Seed sample history")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(IOSAppTheme.textPrimary)
                    Text(status.isEmpty
                         ? "Adds a fixture take to History so the Player sheet is reachable in Simulator."
                         : status)
                        .font(.footnote)
                        .foregroundStyle(IOSAppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 10)
                Image(systemName: "plus.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(IOSBrandTheme.settings)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("iosSettingsSeedHistory")
    }

    private func seedNext() {
        let seed = seeds[seedIndex % seeds.count]
        seedIndex += 1
        Task {
            do {
                let url = try writeSilenceWAV(durationSeconds: seed.durationSeconds)
                let generation = Generation(
                    id: nil,
                    text: seed.text,
                    mode: seed.mode,
                    modelTier: "speed",
                    voice: seed.voice,
                    emotion: "neutral",
                    speed: 1.0,
                    audioPath: url.path,
                    duration: seed.durationSeconds,
                    createdAt: Date()
                )
                _ = try await DatabaseService.shared.saveGenerationAsync(generation)
                await MainActor.run {
                    status = "Added \(seed.mode.capitalized) take. Tap History to play."
                    NotificationCenter.default.post(name: .generationSaved, object: nil)
                    IOSHaptics.selection()
                }
            } catch {
                await MainActor.run {
                    status = "Seed failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Writes a silence WAV file (24 kHz mono Int16 PCM) into
    /// `AppPaths.outputsDir`. The audio is silent but the file's
    /// duration drives the Player sheet's scrubber + karaoke timing.
    private func writeSilenceWAV(durationSeconds: Double) throws -> URL {
        try FileManager.default.createDirectory(at: AppPaths.outputsDir, withIntermediateDirectories: true)
        let outputURL = AppPaths.outputsDir
            .appendingPathComponent("seed-\(UUID().uuidString.prefix(8)).wav")

        let sampleRate: UInt32 = 24_000
        let bitsPerSample: UInt16 = 16
        let numChannels: UInt16 = 1
        let numSamples = Int((Double(sampleRate) * durationSeconds).rounded())
        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(numSamples) * UInt32(blockAlign)
        let fileSizeMinus8 = 36 + dataSize

        var data = Data()
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46])                      // "RIFF"
        data.appendLE(UInt32(fileSizeMinus8))
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45])                      // "WAVE"
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])                      // "fmt "
        data.appendLE(UInt32(16))                                              // fmt chunk size
        data.appendLE(UInt16(1))                                               // PCM format
        data.appendLE(numChannels)
        data.appendLE(sampleRate)
        data.appendLE(byteRate)
        data.appendLE(blockAlign)
        data.appendLE(bitsPerSample)
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61])                      // "data"
        data.appendLE(dataSize)
        // Silence: numSamples × 2 bytes of zeros
        data.append(Data(count: numSamples * Int(blockAlign)))

        try data.write(to: outputURL, options: [.atomic])
        return outputURL
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
#endif

private struct IOSSettingsLinkRow: View {
    let title: String
    let subtitle: String
    let urlString: String
    let accessibilityIdentifier: String

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            guard let url = URL(string: urlString) else { return }
            openURL(url)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(IOSAppTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(IOSAppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 10)
                Image(systemName: "arrow.up.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(IOSAppTheme.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct IOSSettingsSystemPreferencesRow: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            openURL(url)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Open iOS Settings")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(IOSAppTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Adjust permissions and system preferences for Vocello.")
                        .font(.footnote)
                        .foregroundStyle(IOSAppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 10)
                Image(systemName: "arrow.up.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(IOSAppTheme.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("iosSettingsOpenSystemSettings")
    }
}

private struct IOSSettingsPlaybackRow: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Auto-play generated audio")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(IOSAppTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Play each finished take automatically.")
                    .font(.footnote)
                    .foregroundStyle(IOSAppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .tint(IOSBrandTheme.settings)
        .padding(.vertical, 2)
    }
}

private struct IOSSettingsProminentActionButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule(style: .continuous)

        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background { shape.fill(Color.clear) }
            .overlay {
                shape
                    .stroke(tint.opacity(configuration.isPressed ? 0.62 : 0.48), lineWidth: 0.5)
            }
            .opacity(configuration.isPressed ? 0.96 : 1.0)
            .iosAppAnimation(IOSSelectionMotion.press, value: configuration.isPressed)
    }
}

private extension View {
    func iosSettingsProminentActionButtonStyle(tint: Color) -> some View {
        buttonStyle(IOSSettingsProminentActionButtonStyle(tint: tint))
    }
}

private struct IOSModelRow: View {
    let model: TTSModel
    let status: ModelManagerViewModel.ModelStatus
    let operationState: IOSModelInstallerViewModel.OperationState
    let onInstall: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    @State private var isPresentingInstallSheet = false
    @State private var isPresentingDeleteSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                header
                Spacer(minLength: 12)
                controls
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if showsStatusDetail {
                statusDetailView
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("iosModelRow_\(model.id)")
        // Track M (2026-05-21): Settings model rows now route Download +
        // Delete through the design's IOSModelInstallSheet and
        // IOSDeleteModelSheet rather than the bare iOSAdaptiveUtility
        // button + system confirmationDialog. The install sheet carries
        // the design's privacy callout ("Stays on your iPhone") + the
        // 56pt mode-tinted icon + size / On-device pills, which is
        // exactly where a user is most likely to want that reassurance.
        .sheet(isPresented: $isPresentingInstallSheet) {
            IOSModelInstallSheet(
                item: installSheetItem,
                isInstalling: installSheetIsInstalling,
                progress: installSheetProgress,
                onInstall: {
                    IOSHaptics.selection()
                    onInstall()
                },
                onCancel: {
                    onCancel()
                    isPresentingInstallSheet = false
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
            .presentationCornerRadius(IOSBottomSheetChrome.cornerRadius)
            .presentationBackground(IOSBottomSheetChrome.background)
        }
        .sheet(isPresented: $isPresentingDeleteSheet) {
            IOSDeleteModelSheet(
                modelName: model.name,
                sizeLabel: deleteSheetSizeLabel,
                onConfirm: {
                    onDelete()
                    isPresentingDeleteSheet = false
                },
                onCancel: {
                    isPresentingDeleteSheet = false
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.hidden)
            .presentationCornerRadius(IOSBottomSheetChrome.cornerRadius)
            .presentationBackground(IOSBottomSheetChrome.background)
        }
        // Auto-dismiss the install sheet once the operation lands
        // either at `.installed` or back at `.idle` after a cancel.
        .onChange(of: operationState) { _, newValue in
            guard isPresentingInstallSheet else { return }
            switch newValue {
            case .installed, .idle, .failed, .unavailable:
                isPresentingInstallSheet = false
            default:
                break
            }
        }
    }

    private func requestInstall() {
        isPresentingInstallSheet = true
    }

    private func requestDelete() {
        isPresentingDeleteSheet = true
    }

    // MARK: - Install sheet plumbing

    private var installSheetItem: IOSModelInstallSheetItem {
        IOSModelInstallSheetItem(
            id: model.id,
            name: model.name,
            symbol: "bolt.fill",
            sizeLabel: estimatedDownloadSizeLabel,
            description: installSheetDescription(for: model.mode),
            tint: IOSBrandTheme.modeColor(for: model.mode)
        )
    }

    /// Per-mode description that mirrors `design_references/Vocello iOS/
    /// data.js` `models[].desc`. Hand-wired here to avoid a model-layer
    /// change.
    private func installSheetDescription(for mode: GenerationMode) -> String {
        switch mode {
        case .custom: return "Built-in speaker presets with controllable emotion and delivery."
        case .design: return "Describe a voice in natural language and Vocello renders it."
        case .clone:  return "Speak your text in a saved voice or any 10-20 s reference clip."
        }
    }

    private var estimatedDownloadSizeLabel: String {
        if let estimated = model.estimatedDownloadBytes {
            return IOSSettingsFormatters.fileSize(estimated)
        }
        if case let .installed(sizeBytes) = status {
            return IOSSettingsFormatters.fileSize(Int64(sizeBytes))
        }
        return "—"
    }

    private var deleteSheetSizeLabel: String {
        if case let .installed(sizeBytes) = status {
            return IOSSettingsFormatters.fileSize(Int64(sizeBytes))
        }
        if let estimated = model.estimatedDownloadBytes {
            return IOSSettingsFormatters.fileSize(estimated)
        }
        return "several GB"
    }

    private var installSheetIsInstalling: Binding<Bool> {
        Binding(
            get: {
                switch operationState {
                case .downloading, .resuming, .restarting, .verifying, .installing:
                    return true
                default:
                    return false
                }
            },
            set: { _ in }   // host-driven; the sheet doesn't toggle this
        )
    }

    private var installSheetProgress: Binding<Double> {
        Binding(
            get: {
                switch operationState {
                case .downloading(let progress, _, _),
                     .resuming(let progress, _, _),
                     .restarting(let progress, _, _):
                    return progress ?? 0
                case .verifying, .installing:
                    return 1.0
                default:
                    return 0
                }
            },
            set: { _ in }
        )
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(IOSBrandTheme.modeColor(for: model.mode).opacity(0.16))
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(IOSBrandTheme.modeColor(for: model.mode).opacity(0.38), lineWidth: 0.5)
                Image(systemName: modelIconName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(IOSBrandTheme.modeColor(for: model.mode))
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.mode.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.075)
                    .foregroundStyle(IOSAppTheme.textPrimary)

                modelSubtitle
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var modelSubtitle: some View {
        HStack(spacing: 6) {
            Text(variantDisplayText)

            if let estimatedSizeText {
                Text("·")
                Text(estimatedSizeText)
                    .monospacedDigit()
            }

            if let statusSummaryText {
                Text("·")
                Text(statusSummaryText)
                    .fontWeight(statusSummaryText == "Active" ? .semibold : .regular)
                    .foregroundStyle(statusSummaryText == "Active"
                                     ? IOSBrandTheme.modeColor(for: model.mode)
                                     : IOSAppTheme.textSecondary)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(IOSAppTheme.textSecondary)
        .lineLimit(1)
    }

    private var modelIconName: String {
        switch model.mode {
        case .custom: return "mic.fill"
        case .design: return "wand.and.stars"
        case .clone: return "waveform"
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch operationState {
        case .idle:
            switch status {
            case .installed:
                installedControls
            case .checking:
                ProgressView()
            case .notInstalled:
                installButton(title: "Install", accessibilityIdentifier: "iosModelDownload_\(model.id)")
            case .incomplete, .error:
                installButton(title: "Repair", action: onInstall, accessibilityIdentifier: "iosModelRepair_\(model.id)")
            }
        case .installed:
            installedControls
        case .available:
            installButton(title: "Install", accessibilityIdentifier: "iosModelDownload_\(model.id)")
        case .downloading, .interrupted, .resuming, .restarting:
            installButton(title: "Cancel", action: onCancel, accessibilityIdentifier: "iosModelCancel_\(model.id)")
        case .verifying, .installing, .deleting:
            ProgressView()
        case .unavailable:
            if case .incomplete = status {
                installedControls
            }
        case .failed:
            installButton(title: "Retry", action: onInstall, accessibilityIdentifier: "iosModelRetry_\(model.id)")
        }
    }

    private var installedControls: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color(red: 0.19, green: 0.82, blue: 0.35))

            Button(role: .destructive, action: requestDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(IOSAppTheme.textSecondary)
                    .frame(width: 36, height: 36)
                    .background {
                        Circle()
                            .fill(Color.white.opacity(0.04))
                    }
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("iosModelDelete_\(model.id)")
        }
    }

    private func installButton(
        title: String,
        action: (() -> Void)? = nil,
        accessibilityIdentifier: String
    ) -> some View {
        Button(title, action: action ?? requestInstall)
            .iosSettingsProminentActionButtonStyle(tint: IOSBrandTheme.modeColor(for: model.mode))
            .accessibilityIdentifier(accessibilityIdentifier)
    }

    @ViewBuilder
    private var statusDetailView: some View {
        switch operationState {
        case .downloading(let progress, let downloadedBytes, let totalBytes):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress ?? 0)
                    .tint(IOSBrandTheme.modeColor(for: model.mode))
                Text(progressText(downloadedBytes: downloadedBytes, totalBytes: totalBytes))
                    .font(.system(size: 12))
                    .foregroundStyle(IOSAppTheme.textSecondary)
            }
        case .interrupted(let message, let downloadedBytes, let totalBytes):
            VStack(alignment: .leading, spacing: 6) {
                Text(message ?? "Download interrupted.")
                    .font(.system(size: 12))
                    .foregroundStyle(IOSAppTheme.textSecondary)
                Text(progressText(downloadedBytes: downloadedBytes, totalBytes: totalBytes))
                    .font(.system(size: 12))
                    .foregroundStyle(IOSAppTheme.textSecondary)
            }
        case .resuming(let progress, let downloadedBytes, let totalBytes),
                .restarting(let progress, let downloadedBytes, let totalBytes):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress ?? 0)
                    .tint(IOSBrandTheme.modeColor(for: model.mode))
                Text(progressText(downloadedBytes: downloadedBytes, totalBytes: totalBytes))
                    .font(.system(size: 12))
                    .foregroundStyle(IOSAppTheme.textSecondary)
            }
        case .failed(let message):
            if !IOSSimulatorPreviewPolicy.isSimulatorPreview {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .available, .verifying, .installing, .installed, .deleting, .unavailable, .idle:
            EmptyView()
        }
    }

    private var variantDisplayText: String {
        return "4-bit Speed"
    }

    private var estimatedSizeText: String? {
        let label = estimatedDownloadSizeLabel
        return label == "—" ? nil : label
    }

    private var showsStatusDetail: Bool {
        switch operationState {
        case .downloading, .interrupted, .resuming, .restarting:
            return true
        case .failed:
            return !IOSSimulatorPreviewPolicy.isSimulatorPreview
        default:
            return false
        }
    }

    private var statusSummaryText: String? {
        switch operationState {
        case .idle:
            switch status {
            case .checking:
                return "Checking…"
            case .notInstalled:
                return nil
            case .installed:
                return "Active"
            case .incomplete:
                return "Repair needed"
            case .error:
                return "Retry needed"
            }
        case .installed:
            return "Active"
        case .available:
            return nil
        case .downloading:
            return "Downloading…"
        case .interrupted:
            return "Interrupted"
        case .resuming:
            return "Resuming…"
        case .restarting:
            return "Restarting…"
        case .verifying:
            return "Verifying…"
        case .installing:
            return "Installing…"
        case .deleting:
            return "Removing…"
        case .unavailable:
            return IOSSimulatorPreviewPolicy.isSimulatorPreview ? "Unavailable in Simulator" : "Unavailable"
        case .failed:
            return IOSSimulatorPreviewPolicy.isSimulatorPreview ? "Unavailable in Simulator" : "Retry needed"
        }
    }

    private func progressText(downloadedBytes: Int64, totalBytes: Int64?) -> String {
        let current = IOSSettingsFormatters.fileSize(downloadedBytes)
        guard let totalBytes else { return "\(current) downloaded" }
        let total = IOSSettingsFormatters.fileSize(totalBytes)
        return "\(current) / \(total)"
    }
}
