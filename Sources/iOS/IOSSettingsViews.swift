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

    @Binding var selectedTab: IOSAppTab
    @AppStorage("autoPlay") private var autoPlay = true

    private var runtimeDescription: String {
        IOSSimulatorRuntimeSupport.isSimulator ? "Simulator" : "On-device"
    }

    private var previewSettingsState: IOSPreviewSettingsState? {
        IOSPreviewRuntime.current?.definition.settingsState
    }

    var body: some View {
        IOSStudioShellScreen(
            selectedTab: $selectedTab,
            activeTab: .settings,
            tint: IOSBrandTheme.settings
        ) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    IOSStudioWorkspaceHeading(title: "Settings")

                    IOSStudioSectionGroup(title: "Playback", tint: IOSBrandTheme.settings) {
                        IOSSettingsPlaybackRow(isOn: $autoPlay)
                    }

                    IOSStudioSectionGroup(title: "Model Assets", tint: IOSBrandTheme.settings) {
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
                                Divider()
                                    .overlay(IOSAppTheme.hairlineDivider)
                            }
                        }
                    }

                    IOSStudioSectionGroup(title: "Runtime", tint: IOSBrandTheme.settings) {
                        IOSHeaderMetricRow(label: "Runtime", value: runtimeDescription)

                        Divider()
                            .overlay(IOSAppTheme.hairlineDivider)

                        IOSHeaderMetricRow(
                            label: "Minimum supported hardware",
                            value: "iPhone 15 Pro or newer"
                        )
                    }

                    IOSStudioSectionGroup(title: "Help & support", tint: IOSBrandTheme.settings) {
                        IOSSettingsLinkRow(
                            title: "View documentation",
                            subtitle: "Open the project README on GitHub.",
                            urlString: "https://github.com/PowerBeef/QwenVoice#readme",
                            accessibilityIdentifier: "iosSettingsDocsLink"
                        )

                        Divider()
                            .overlay(IOSAppTheme.hairlineDivider)

                        IOSSettingsLinkRow(
                            title: "Report an issue",
                            subtitle: "File a bug or feature request on GitHub.",
                            urlString: "https://github.com/PowerBeef/QwenVoice/issues/new",
                            accessibilityIdentifier: "iosSettingsReportIssueLink"
                        )

                        Divider()
                            .overlay(IOSAppTheme.hairlineDivider)

                        IOSSettingsLinkRow(
                            title: "Privacy & local storage",
                            subtitle: "Where Vocello keeps generated audio and saved voices.",
                            urlString: "https://github.com/PowerBeef/QwenVoice/blob/main/docs/reference/privacy-storage.md",
                            accessibilityIdentifier: "iosSettingsPrivacyLink"
                        )

                        Divider()
                            .overlay(IOSAppTheme.hairlineDivider)

                        IOSSettingsSystemPreferencesRow()

                        Divider()
                            .overlay(IOSAppTheme.hairlineDivider)

                        IOSHeaderMetricRow(label: "App version", value: IOSSettingsSupportInfo.appVersionLabel)
                    }

                    #if DEBUG
                    if IOSSimulatorRuntimeSupport.isSimulator {
                        IOSStudioSectionGroup(title: "Debug", tint: IOSBrandTheme.settings) {
                            IOSSettingsSeedHistoryRow()
                        }
                    }
                    #endif
                }
                // Extra bottom padding so the bottom-most section clears
                // the TabDock's gradient fade in RootView. Without this,
                // long Settings + the Debug section get visually
                // swallowed by the dock's canvasBottom gradient.
                .padding(.bottom, 90)
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
    @ScaledMetric(relativeTo: .footnote) private var horizontalPadding = 14
    @ScaledMetric(relativeTo: .footnote) private var verticalPadding = 6

    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule(style: .continuous)

        configuration.label
            .font(.footnote.weight(.semibold))
            .foregroundStyle(configuration.isPressed ? IOSAppTheme.accentForegroundPressed : IOSAppTheme.accentForeground)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .iosSubtleGlassSurface(
                in: shape,
                tint: tint,
                fill: tint.opacity(configuration.isPressed ? 0.14 : 0.10),
                strokeOpacity: configuration.isPressed ? 0.30 : 0.22,
                interactive: true
            )
            .overlay {
                shape
                    .stroke(tint.opacity(configuration.isPressed ? 0.42 : 0.34), lineWidth: 0.9)
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
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    header
                    Spacer(minLength: 12)
                    controlsRow
                }

                VStack(alignment: .leading, spacing: 8) {
                    header
                    controlsRow
                }
            }

            statusDetailView
        }
        .padding(.vertical, 2)
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
            .presentationBackground(IOSBrandTheme.canvasTop)
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
            .presentationBackground(IOSBrandTheme.canvasTop)
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
        VStack(alignment: .leading, spacing: 3) {
            Text(model.name)
                .font(.body.weight(.semibold))
                .foregroundStyle(IOSAppTheme.textPrimary)
            Text(secondaryLineText)
                .font(.subheadline)
                .foregroundStyle(IOSAppTheme.textSecondary)
                .lineLimit(1)
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 8) {
            controls
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var controls: some View {
        switch operationState {
        case .idle:
            switch status {
            case .installed:
                Button("Delete", role: .destructive, action: requestDelete)
                    .controlSize(.small)
                    .iosAdaptiveUtilityButtonStyle(tint: .red)
                    .accessibilityIdentifier("iosModelDelete_\(model.id)")
            case .checking:
                ProgressView()
            case .notInstalled:
                EmptyView()
            case .incomplete, .error:
                Button("Repair", action: onInstall)
                    .iosSettingsProminentActionButtonStyle(tint: IOSBrandTheme.modeColor(for: model.mode))
                    .accessibilityIdentifier("iosModelRepair_\(model.id)")
            }
        case .installed:
            Button("Delete", role: .destructive, action: requestDelete)
                .controlSize(.small)
                .iosAdaptiveUtilityButtonStyle(tint: .red)
                .accessibilityIdentifier("iosModelDelete_\(model.id)")
        case .available:
            Button("Download", action: requestInstall)
                .iosSettingsProminentActionButtonStyle(tint: IOSBrandTheme.modeColor(for: model.mode))
                .accessibilityIdentifier("iosModelDownload_\(model.id)")
        case .downloading, .interrupted, .resuming, .restarting:
            Button("Cancel", action: onCancel)
                .controlSize(.small)
                .iosAdaptiveUtilityButtonStyle(tint: IOSBrandTheme.modeColor(for: model.mode))
                .accessibilityIdentifier("iosModelCancel_\(model.id)")
        case .verifying, .installing, .deleting:
            ProgressView()
        case .unavailable:
            if case .incomplete = status {
                Button("Delete", role: .destructive, action: requestDelete)
                    .controlSize(.small)
                    .iosAdaptiveUtilityButtonStyle(tint: .red)
                    .accessibilityIdentifier("iosModelDelete_\(model.id)")
            }
        case .failed:
            Button("Retry", action: onInstall)
                .iosSettingsProminentActionButtonStyle(tint: IOSBrandTheme.modeColor(for: model.mode))
                .accessibilityIdentifier("iosModelRetry_\(model.id)")
        }
    }

    @ViewBuilder
    private var statusDetailView: some View {
        switch operationState {
        case .downloading(let progress, let downloadedBytes, let totalBytes):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress ?? 0)
                Text(progressText(downloadedBytes: downloadedBytes, totalBytes: totalBytes))
                    .font(.footnote)
                    .foregroundStyle(IOSAppTheme.textSecondary)
            }
        case .interrupted(let message, let downloadedBytes, let totalBytes):
            VStack(alignment: .leading, spacing: 6) {
                Text(message ?? "Download interrupted.")
                    .font(.footnote)
                    .foregroundStyle(IOSAppTheme.textSecondary)
                Text(progressText(downloadedBytes: downloadedBytes, totalBytes: totalBytes))
                    .font(.footnote)
                    .foregroundStyle(IOSAppTheme.textSecondary)
            }
        case .resuming(let progress, let downloadedBytes, let totalBytes),
                .restarting(let progress, let downloadedBytes, let totalBytes):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress ?? 0)
                Text(progressText(downloadedBytes: downloadedBytes, totalBytes: totalBytes))
                    .font(.footnote)
                    .foregroundStyle(IOSAppTheme.textSecondary)
            }
        case .failed(let message):
            if !IOSSimulatorPreviewPolicy.isSimulatorPreview {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .available, .verifying, .installing, .installed, .deleting, .unavailable, .idle:
            EmptyView()
        }
    }

    private var secondaryLineText: String {
        [model.mode.displayName, model.tier.uppercased(), statusSummaryText]
            .compactMap { $0 }
            .joined(separator: " • ")
    }

    private var statusSummaryText: String? {
        switch operationState {
        case .idle:
            switch status {
            case .checking:
                return "Checking…"
            case .notInstalled:
                return "Not installed"
            case .installed(let sizeBytes):
                return "Installed \(IOSSettingsFormatters.fileSize(Int64(sizeBytes)))"
            case .incomplete:
                return "Repair needed"
            case .error:
                return "Retry needed"
            }
        case .installed:
            return "Installed"
        case .available(let estimatedBytes):
            guard let estimatedBytes else { return "Download available" }
            return "Download \(IOSSettingsFormatters.fileSize(estimatedBytes))"
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
