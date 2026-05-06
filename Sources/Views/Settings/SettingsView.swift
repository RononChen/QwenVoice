import SwiftUI
import QwenVoiceCore
import AppKit

/// Unified Settings surface, modeled on macOS System Settings.
///
/// Single in-app surface that hosts model downloads + playback +
/// storage + about. Four grouped sections total:
///
/// 1. Models. One row per generation mode. Each row carries a
///    native popup `Picker` for variant selection (the System
///    Settings "Output device" idiom). The trailing action button
///    reflects the state of the currently-selected variant: Get,
///    Cancel + progress, Repair, or borderless trash when the
///    variant is active and on disk.
///
/// 2. Playback. Two toggles. Captions only where the toggle name
///    is not self-explanatory.
///
/// 3. Storage. Output directory + Application data, two compact
///    rows.
///
/// 4. About. Version line.
///
/// Mode color identity attaches to each row's leading 8 pt dot
/// rather than the section header — with one Models section, the
/// mode marker has to live on the row itself.
struct SettingsView: View {
    @EnvironmentObject private var viewModel: ModelManagerViewModel
    @Binding var highlightedModelID: String?

    @AppStorage("autoPlay") private var autoPlay = true
    @AppStorage("outputDirectory") private var outputDirectory = ""
    @AppStorage(AudioService.smoothPlaybackKey) private var smoothPlayback = false

    @State private var flashedMode: GenerationMode?
    @State private var modelToDelete: TTSModel?
    @State private var showDeleteConfirmation = false

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section("Models") {
                    ForEach(GenerationMode.allCases, id: \.self) { mode in
                        ModeRow(
                            mode: mode,
                            viewModel: viewModel,
                            isFlashed: flashedMode == mode,
                            onDelete: { model in request(delete: model) }
                        )
                        .id(mode.rawValue)
                    }
                }

                Section("Playback") {
                    Toggle("Auto-play generated audio", isOn: $autoPlay)
                        .tint(AppTheme.preferences)
                        .accessibilityIdentifier("preferences_autoPlayToggle")

                    Toggle(isOn: $smoothPlayback) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Smooth playback")
                            Text("Adds a few seconds before audio starts; eliminates mid-playback pauses.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(AppTheme.preferences)
                    .accessibilityIdentifier("preferences_smoothPlaybackToggle")
                }

                Section("Storage") {
                    LabeledContent("Output directory") {
                        HStack(spacing: 6) {
                            Text(outputDirectorySummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .accessibilityIdentifier("preferences_outputDirectory")
                            Button("Choose…") { browseForOutputDirectory() }
                                .controlSize(.small)
                                .accessibilityIdentifier("preferences_browseButton")
                            if !outputDirectory.isEmpty {
                                Button("Reset") { outputDirectory = "" }
                                    .controlSize(.small)
                                    .buttonStyle(.borderless)
                                    .accessibilityIdentifier("preferences_outputResetButton")
                            }
                        }
                    }

                    // Application data row carries the version
                    // text inline so the dedicated About section is
                    // unnecessary. Settings stays at three sections;
                    // the About box (menu Vocello -> About Vocello)
                    // already covers full version detail in the
                    // standard macOS spot.
                    LabeledContent("Application data") {
                        HStack(spacing: 8) {
                            Text(appVersion)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.open(QwenVoiceApp.appSupportDir)
                            }
                            .controlSize(.small)
                            .accessibilityIdentifier("preferences_openFinderButton")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle("Settings")
            .accessibilityIdentifier("screen_settings")
            .task {
                await viewModel.refresh()
                focusHighlighted(using: proxy)
            }
            .onChange(of: highlightedModelID) { _, _ in
                focusHighlighted(using: proxy)
            }
        }
        .alert("Delete Model?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { modelToDelete = nil }
            Button("Delete", role: .destructive) {
                if let model = modelToDelete { viewModel.delete(model) }
                modelToDelete = nil
            }
        } message: {
            if let model = modelToDelete {
                let status = viewModel.statuses[model.id]
                let sizeText: String = {
                    if case .downloaded(let sizeBytes) = status {
                        return " (\(ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)))"
                    }
                    return ""
                }()
                Text("This will delete \"\(model.name)\"\(sizeText) from disk.")
            }
        }
    }

    private func request(delete model: TTSModel) {
        modelToDelete = model
        showDeleteConfirmation = true
    }

    private var outputDirectorySummary: String {
        if outputDirectory.isEmpty { return "Default" }
        return outputDirectory
    }

    private func browseForOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url.path
        }
    }

    private var appVersion: String {
        let dict = Bundle.main.infoDictionary ?? [:]
        let version = dict["CFBundleShortVersionString"] as? String ?? "?"
        let build = dict["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func focusHighlighted(using proxy: ScrollViewProxy) {
        guard let modelID = highlightedModelID,
              let model = TTSModel.model(id: modelID) else { return }
        let mode = model.mode
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            proxy.scrollTo(mode.rawValue, anchor: .center)
        }
        flashedMode = mode
        self.highlightedModelID = nil

        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                if flashedMode == mode { flashedMode = nil }
            }
        }
    }
}

// MARK: - Mode row

/// Single row for one generation mode. Native System Settings
/// idiom: leading label + mode-color dot, trailing native popup
/// for variant selection plus a context-sensitive action button.
private struct ModeRow: View {
    let mode: GenerationMode
    @ObservedObject var viewModel: ModelManagerViewModel
    let isFlashed: Bool
    let onDelete: (TTSModel) -> Void

    private var pair: (speed: TTSModel?, quality: TTSModel?) {
        viewModel.pairedVariants(for: mode)
    }

    /// The variant currently active for this mode, falling back
    /// to whichever variant exists if none is explicitly selected.
    private var activeVariant: TTSModel? {
        if let speed = pair.speed, viewModel.isActive(speed) { return speed }
        if let quality = pair.quality, viewModel.isActive(quality) { return quality }
        return pair.speed ?? pair.quality
    }

    /// Picker selection drives the active-variant preference.
    /// Reads from `viewModel.isActive`; writes via `viewModel.use`.
    private var selectionBinding: Binding<String?> {
        Binding<String?>(
            get: { activeVariant?.id },
            set: { newID in
                guard let newID else { return }
                if let speed = pair.speed, speed.id == newID { viewModel.use(speed) }
                if let quality = pair.quality, quality.id == newID { viewModel.use(quality) }
            }
        )
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Picker("", selection: selectionBinding) {
                    if let speed = pair.speed {
                        Text(menuLabel(for: speed)).tag(Optional(speed.id))
                    }
                    if let quality = pair.quality {
                        Text(menuLabel(for: quality)).tag(Optional(quality.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(minWidth: 150)

                if let model = activeVariant {
                    ActionButton(
                        model: model,
                        viewModel: viewModel,
                        onDelete: { onDelete(model) }
                    )
                }
            }
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(AppTheme.modeColor(for: mode))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(mode.displayName)
            }
        }
        .listRowBackground(isFlashed ? Color.accentColor.opacity(0.10) : nil)
        .accessibilityIdentifier("settings_mode_\(mode.rawValue)")
    }

    /// Compact picker label. Just kind + bit-depth so the closed
    /// popup stays narrow and the row never wraps. Size lives on
    /// the trailing action button (`Get 2.31 GB`); recommendation
    /// and warning attach to the leading label area through the
    /// row's mode indicator.
    private func menuLabel(for model: TTSModel) -> String {
        let kind = model.variantKind?.displayName ?? model.name
        let bits = model.variantKind?.bitDepthLabel ?? ""
        return "\(kind) (\(bits))"
    }
}

// MARK: - Action button

/// Trailing single primary control whose role flips with the
/// status of the currently-selected variant for this mode.
private struct ActionButton: View {
    let model: TTSModel
    @ObservedObject var viewModel: ModelManagerViewModel
    let onDelete: () -> Void

    private var status: ModelManagerViewModel.ModelStatus {
        viewModel.statuses[model.id] ?? .checking
    }

    private var isDownloaded: Bool {
        if case .downloaded = status { return true }
        return false
    }

    private var isLiveActive: Bool {
        viewModel.isActive(model) && isDownloaded
    }

    var body: some View {
        switch status {
        case .checking:
            ProgressView()
                .controlSize(.small)
                .accessibilityIdentifier("settings_checking_\(model.id)")

        case .notDownloaded:
            Button(getButtonTitle) {
                Task { await viewModel.download(model) }
            }
            .controlSize(.small)
            .accessibilityIdentifier("settings_get_\(model.id)")

        case .downloading(let progress):
            HStack(spacing: 8) {
                if let total = progress.totalBytes, total > 0 {
                    ProgressView(value: Double(progress.downloadedBytes), total: Double(total))
                        .progressViewStyle(.linear)
                        .frame(width: 80)
                        .tint(AppTheme.statusProgressTint)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Cancel") {
                    viewModel.cancelDownload(model)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

        case .repairAvailable:
            Button("Repair") {
                Task { await viewModel.download(model) }
            }
            .controlSize(.small)
            .tint(.orange)
            .accessibilityIdentifier("settings_repair_\(model.id)")

        case .downloaded:
            // Active-and-downloaded: the picker shows it's selected,
            // so the trailing action becomes a quiet trash. If a
            // user picked this variant via the popup but the engine
            // hasn't moved it to active yet (rare race), there's
            // nothing else to do — same trash.
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Delete \(model.variantKind?.displayName ?? model.name) variant")
            .accessibilityIdentifier("settings_delete_\(model.id)")
        }
    }

    private var getButtonTitle: String {
        if let size = viewModel.sizeText(for: model) {
            return "Get \(size)"
        }
        return "Get"
    }
}
