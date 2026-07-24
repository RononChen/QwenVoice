import SwiftUI
import QwenVoiceCore
import AppKit
import UniformTypeIdentifiers

/// Unified Settings surface, modeled on macOS System Settings.
///
/// Single in-app surface that hosts model downloads + playback +
/// storage. Settings remain grouped by user-facing responsibility:
///
/// 1. Interface. App-owned UI language selection.
///
/// 2. Voice cloning permission and model downloads. Compact status/action
///    rows cover the locally managed Speed and Quality packages.
///
/// 3. Playback, generation, performance, and storage preferences.
///
/// Mode color identity attaches to each row's leading 8 pt dot
/// rather than the section header.
struct SettingsView: View {
    @Environment(ModelManagerViewModel.self) private var viewModel
    /// Mode-keyed deep-link target. When the sidebar redirects
    /// the user to Settings (because a generation tab's required
    /// variant is missing), the upstream `ContentView` sets this
    /// so the Model downloads section can scroll to and flash that mode's
    /// row. Mode-keyed instead of model-id-keyed because the row
    /// is mode-keyed; the missing variant might not be the
    /// current generation selection.
    @Binding var highlightedMode: GenerationMode?
    private let showsNavigationTitle: Bool

    @AppStorage("autoPlay", store: AppDefaults.store) private var autoPlay = true
    @AppStorage(AppDisplayLanguage.preferenceKey, store: AppDefaults.store)
    private var interfaceLanguage = AppDisplayLanguage.system.rawValue
    @AppStorage("vocello.voiceCloningConsent.v1", store: AppDefaults.store)
    private var cloneConsentAcknowledged = false
    @AppStorage("outputDirectory", store: AppDefaults.store) private var outputDirectory = ""
    @AppStorage(GenerationVariationPreference.key, store: AppDefaults.store)
    private var generationVariation = GenerationVariationPreference.defaultValue
    /// Bound to `MacModelVariantPreferences.preferSpeedEverywhereKey`.
    /// When ON, every generation mode resolves to the Speed variant
    /// regardless of per-mode preferences or hardware recommendations.
    /// Useful on memory-constrained Macs.
    @AppStorage(MacModelVariantPreferences.preferSpeedEverywhereKey, store: AppDefaults.store)
    private var preferSpeedEverywhere = false

    @State private var flashedMode: GenerationMode?
    @State private var modelToDelete: TTSModel?
    @State private var showDeleteConfirmation = false
    /// Non-nil when the configured output folder is missing/unwritable
    /// (AudioService falls back to the default outputs folder).
    @State private var outputDirectoryIssue: String?

    init(highlightedMode: Binding<GenerationMode?>, showsNavigationTitle: Bool = true) {
        _highlightedMode = highlightedMode
        self.showsNavigationTitle = showsNavigationTitle
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section {
                    Picker("Interface language", selection: $interfaceLanguage) {
                        ForEach(AppDisplayLanguage.allCases) { language in
                            Text(verbatim: displayName(for: language))
                                .tag(language.rawValue)
                        }
                    }
                    .accessibilityIdentifier("settings_interfaceLanguage")

                    Text("Language changes take effect after you restart Sonafolio.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Interface")
                }

                Section("Voice cloning") {
                    Toggle(isOn: $cloneConsentAcknowledged) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("I own or have permission to clone the voices I use")
                            Text("Only clone voices you own or have explicit permission to use.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(AppTheme.voiceCloning)
                    .accessibilityIdentifier("voiceCloning_consentAcknowledgment")
                }

                Section("Model downloads") {
                    ModelSetupSummaryRow(viewModel: viewModel)

                    ForEach(GenerationMode.allCases, id: \.self) { mode in
                        ModelDownloadRow(
                            mode: mode,
                            viewModel: viewModel,
                            isFlashed: flashedMode == mode,
                            onDelete: { model in request(delete: model) }
                        )
                        .id(mode.rawValue)
                    }

                    WhisperModelDownloadRow()
                }

                Section("Playback") {
                    Toggle("Auto-play generated audio", isOn: $autoPlay)
                        .tint(AppTheme.preferences)
                        .accessibilityIdentifier("preferences_autoPlayToggle")
                }

                Section {
                    Picker("Variation", selection: $generationVariation) {
                        ForEach(Qwen3SamplingVariation.allCases, id: \.rawValue) { variation in
                            Text(variation.displayName.localizedForDisplay).tag(variation.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("settings_generationVariation")
                    Text(
                        "How much takes vary when regenerating the same text. " +
                        "Expressive is the model's official sampling (liveliest); " +
                        "Balanced and Consistent trade some liveliness for steadier, more repeatable takes."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("Generation")
                }

                Section {
                    Toggle(isOn: $preferSpeedEverywhere) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Prefer lower-memory models")
                                .font(.body)
                            Text(
                                "Pins every generation mode to the Speed package. " +
                                "Speed uses less memory and is safer on lower-RAM Macs, with lower fidelity than Quality. " +
                                "You can still switch per-generation in the mode screens; this toggle just changes the defaults."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(AppTheme.preferences)
                    .accessibilityIdentifier("settings_preferSpeedEverywhere")
                } header: {
                    Text("Performance")
                }

                Section("Storage") {
                    LabeledContent("Output directory") {
                        HStack(spacing: 6) {
                            if outputDirectoryIssue != nil {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .help(outputDirectoryIssue ?? "")
                                    .accessibilityIdentifier("preferences_outputDirectoryWarning")
                            }
                            Text(outputDirectorySummary.localizedForDisplay)
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

                    if let outputDirectoryIssue {
                        Text(outputDirectoryIssue.localizedForDisplay)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("preferences_outputDirectoryIssue")
                    }

                    // Application data carries the version inline; the
                    // standard About box already covers full version detail.
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
                            if let openSourceNoticeURL {
                                Button("Open-source licenses") {
                                    NSWorkspace.shared.open(openSourceNoticeURL)
                                }
                                .controlSize(.small)
                                .accessibilityIdentifier("preferences_openSourceLicensesButton")
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            // Match the darker canvas background used by Generate
            // tabs. Without this, Form's grouped style paints its
            // own lighter gray panel that diverges from the rest
            // of the app's chrome.
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .settingsNavigationTitle(showsNavigationTitle)
            .accessibilityIdentifier("screen_settings")
            .task {
                outputDirectoryIssue = AudioService.configuredOutputDirectoryIssue()
                await viewModel.refresh()
                focusHighlighted(using: proxy)
            }
            .onChange(of: highlightedMode) { _, _ in
                focusHighlighted(using: proxy)
            }
            .onChange(of: outputDirectory) { _, _ in
                outputDirectoryIssue = AudioService.configuredOutputDirectoryIssue()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                // The folder may have been deleted/restored while the user
                // was away — keep the warning truthful.
                outputDirectoryIssue = AudioService.configuredOutputDirectoryIssue()
            }
        }
        .alert("Delete Model?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { modelToDelete = nil }
            Button("Delete", role: .destructive) {
                if let model = modelToDelete {
                    Task { await viewModel.delete(model) }
                }
                modelToDelete = nil
            }
        } message: {
            if let model = modelToDelete {
                Text(deleteMessage(for: model))
            }
        }
    }

    private func request(delete model: TTSModel) {
        modelToDelete = model
        showDeleteConfirmation = true
    }

    private func displayName(for language: AppDisplayLanguage) -> String {
        language == .system
            ? AppLocalization.string("Follow System")
            : language.nativeDisplayName
    }

    private func deleteMessage(for model: TTSModel) -> String {
        let variant = viewModel.activeVariantLabel(for: model)
        let status = viewModel.statuses[model.id]
        let sizeText: String = {
            if case .downloaded(let sizeBytes) = status, sizeBytes > 0 {
                let size = ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
                return " (\(size))"
            }
            return ""
        }()
        return AppLocalization.format(
            "This will delete %@ %@%@ from disk. You can download it again later.",
            model.mode.displayName.localizedForDisplay,
            variant,
            sizeText
        )
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

    private var openSourceNoticeURL: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let nestedNotice = resources
            .appendingPathComponent("ThirdPartyNotices", isDirectory: true)
            .appendingPathComponent("NOTICE.txt", isDirectory: false)
        if FileManager.default.isReadableFile(atPath: nestedNotice.path) {
            return nestedNotice
        }
        // Xcode's resource build phase flattens this source folder in local
        // builds, while the release packager may preserve the notice tree.
        let flattenedNotice = resources.appendingPathComponent("NOTICE.txt", isDirectory: false)
        return FileManager.default.isReadableFile(atPath: flattenedNotice.path)
            ? flattenedNotice
            : nil
    }

    private func focusHighlighted(using proxy: ScrollViewProxy) {
        guard let mode = highlightedMode else { return }
        AppLaunchConfiguration.performAnimated(.spring(response: 0.35, dampingFraction: 0.82)) {
            proxy.scrollTo(mode.rawValue, anchor: .center)
        }
        flashedMode = mode
        self.highlightedMode = nil

        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                if flashedMode == mode { flashedMode = nil }
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func settingsNavigationTitle(_ isVisible: Bool) -> some View {
        if isVisible {
            navigationTitle("Settings")
        } else {
            self
        }
    }
}

// MARK: - Model download rows

private struct ModelSetupSummaryRow: View {
    var viewModel: ModelManagerViewModel

    private var summary: ModelManagerViewModel.ModelSetupSummary {
        viewModel.modelSetupSummary()
    }

    private var setupProgress: ModelManagerViewModel.RecommendedSetupProgress? {
        viewModel.recommendedSetupProgress
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(summary.text.localizedForDisplay, systemImage: summaryIconName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .labelStyle(.titleAndIcon)
                    .accessibilityIdentifier("settings_modelDownloadsSummary")

                Spacer(minLength: 12)

                if setupProgress != nil {
                    Button("Cancel") {
                        viewModel.cancelRecommendedSetup()
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("settings_cancelRecommendedSetup")
                } else if !viewModel.recommendedSetupCandidates().isEmpty {
                    Button("Download recommended") {
                        viewModel.setUpRecommendedModels()
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("settings_downloadRecommendedModels")
                }
            }

            if let setupProgress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: setupProgress.fraction)
                        .progressViewStyle(.linear)
                        .tint(AppTheme.statusProgressTint)
                    Text(setupProgressText(setupProgress))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings_recommendedSetupProgress")
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var summaryIconName: String {
        summary.installedRecommendedCount == summary.totalRecommendedCount
            ? "checkmark.circle.fill"
            : "arrow.down.circle"
    }

    private func setupProgressText(_ progress: ModelManagerViewModel.RecommendedSetupProgress) -> String {
        if let modelID = progress.currentModelID,
           let model = TTSModel.model(id: modelID) {
            return AppLocalization.format(
                "Downloading %@ %@ · %lld of %lld complete",
                model.mode.displayName.localizedForDisplay,
                viewModel.activeVariantLabel(for: model),
                Int64(progress.completedCount),
                Int64(progress.totalCount)
            )
        }
        return AppLocalization.format(
            "%lld of %lld complete",
            Int64(progress.completedCount),
            Int64(progress.totalCount)
        )
    }
}

private struct ModelDownloadRow: View {
    let mode: GenerationMode
    var viewModel: ModelManagerViewModel
    let isFlashed: Bool
    let onDelete: (TTSModel) -> Void

    private var variants: [TTSModel] {
        viewModel.variants(for: mode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: AppTheme.modeGlyph(for: mode))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.modeColor(for: mode))
                    .frame(width: 16)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.displayName.localizedForDisplay)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(viewModel.modePurpose(for: mode))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
            }

            VStack(spacing: 5) {
                ForEach(variants) { model in
                    ModelPackageLine(
                        model: model,
                        viewModel: viewModel,
                        onDelete: { onDelete(model) }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 18)
        }
        .padding(.vertical, 5)
        .listRowBackground(isFlashed ? Color.accentColor.opacity(0.10) : nil)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings_mode_\(mode.rawValue)")
    }
}

private struct WhisperModelDownloadRow: View {
    @State private var modelManager = SubtitleModelManager.shared

    private var modelURL: URL {
        SubtitleModelDescriptor.installedURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "captions.bubble.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.preferences)
                    .frame(width: 16)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Whisper subtitle model".localizedForDisplay)
                        .font(.callout.weight(.semibold))
                    Text("Local SRT timing model · 574 MB".localizedForDisplay)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                statusLabel
                    .frame(width: 94, alignment: .leading)

                primaryAction
                    .frame(width: 78, alignment: .trailing)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Place the downloaded file here:".localizedForDisplay)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(modelURL.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings_whisperModelPath")

                Text(
                    AppLocalization.format(
                        "Required file name: %@",
                        SubtitleModelDescriptor.fileName
                    )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)

                Text("Hugging Face model page:".localizedForDisplay)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(SubtitleModelDescriptor.manualDownloadPageURL.absoluteString)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("Open Hugging Face") {
                        NSWorkspace.shared.open(SubtitleModelDescriptor.manualDownloadPageURL)
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("settings_openWhisperHuggingFace")

                    Button("Import File…") {
                        importDownloadedModel()
                    }
                    .controlSize(.small)
                    .disabled(modelManager.isBusy)
                    .accessibilityIdentifier("settings_importWhisperModel")

                    Button("Show Folder") {
                        revealModelLocation()
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("settings_revealWhisperModel")

                    Button("Copy Path") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(modelURL.path, forType: .string)
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("settings_copyWhisperModelPath")

                    Button("Recheck") {
                        modelManager.refresh()
                    }
                    .controlSize(.small)
                    .disabled(modelManager.isBusy)
                    .accessibilityIdentifier("settings_recheckWhisperModel")
                }
            }
            .padding(.leading, 26)

            if case .failed(let message) = modelManager.state {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 26)
                    .accessibilityIdentifier("settings_whisperModelError")
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings_whisperModel")
    }

    @ViewBuilder
    private var statusLabel: some View {
        HStack(spacing: 5) {
            switch modelManager.state {
            case .checking:
                ProgressView()
                    .controlSize(.mini)
                Text("Checking".localizedForDisplay)
            case .notInstalled:
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                Text("Not installed".localizedForDisplay)
            case .downloading:
                ProgressView()
                    .controlSize(.mini)
                Text("Downloading".localizedForDisplay)
            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Ready".localizedForDisplay)
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Failed".localizedForDisplay)
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch modelManager.state {
        case .checking:
            ProgressView()
                .controlSize(.small)
        case .notInstalled:
            Button("Download") {
                modelManager.install()
            }
            .controlSize(.small)
            .accessibilityIdentifier("settings_downloadWhisperModel")
        case .downloading:
            Text("Downloading".localizedForDisplay)
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .ready:
            Button("Show Folder") {
                revealModelLocation()
            }
            .controlSize(.small)
        case .failed:
            Button("Retry") {
                modelManager.install()
            }
            .controlSize(.small)
            .accessibilityIdentifier("settings_retryWhisperModel")
        }
    }

    private func importDownloadedModel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        panel.nameFieldStringValue = SubtitleModelDescriptor.fileName
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
        modelManager.importModel(from: sourceURL)
    }

    private func revealModelLocation() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: AppPaths.subtitleModelsDir,
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: modelURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([modelURL])
        } else {
            NSWorkspace.shared.open(AppPaths.subtitleModelsDir)
        }
    }
}

private struct ModelPackageLine: View {
    let model: TTSModel
    var viewModel: ModelManagerViewModel
    let onDelete: () -> Void
    @State private var showsManualDownload = false

    private var presentation: ModelManagerViewModel.ModelPackagePresentation {
        viewModel.packagePresentation(for: model)
    }

    private var status: ModelManagerViewModel.ModelStatus {
        viewModel.statuses[model.id] ?? .checking
    }

    private var repositoryPageURL: URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(model.huggingFaceRepo)/tree/\(model.huggingFaceRevision ?? "main")"
        return components.url
    }

    private var localModelDirectory: URL {
        model.installDirectory(in: QwenVoiceApp.modelsDir)
    }

    private var fullRepositoryDownloadCommand: String? {
        guard let revision = model.huggingFaceRevision?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !revision.isEmpty else {
            return nil
        }
        return [
            "hf download",
            shellQuoted(model.huggingFaceRepo),
            "--revision",
            shellQuoted(revision),
            "--local-dir",
            shellQuoted(localModelDirectory.path),
        ].joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(viewModel.activeVariantLabel(for: model).localizedForDisplay)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    packageBadge
                }
                .layoutPriority(1)

                Spacer(minLength: 6)

                HStack(spacing: 5) {
                    statusGlyph
                    Text(presentation.label.localizedForDisplay)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                        .accessibilityIdentifier("settings_packageStatus_\(model.id)")
                }
                .frame(width: 94, alignment: .leading)

                ActionButton(
                    model: model,
                    viewModel: viewModel,
                    onDelete: onDelete
                )
                .frame(width: 78, alignment: .trailing)
            }

            if let detail = presentation.detail ?? capabilityDetail {
                Text(detail.localizedForDisplay)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            downloadProgress

            Button {
                showsManualDownload.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: showsManualDownload ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 9)
                        .accessibilityHidden(true)
                    Text("Manual download".localizedForDisplay)
                        .font(.caption2.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings_manualDownload_\(model.id)")

            if showsManualDownload {
                manualDownloadDetails
                    .padding(.top, 5)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(.quaternary.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings_package_\(model.id)")
    }

    @ViewBuilder
    private var packageBadge: some View {
        if viewModel.isHardwareRisky(model) {
            Text("Heavy")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .help("Heavy on this Mac")
                .accessibilityLabel("Heavy on this Mac")
        } else if viewModel.isHardwareRecommended(model) {
            Text("Recommended")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
        }
    }

    private var capabilityDetail: String? {
        var parts: [String] = []
        if let size = model.modelSizeLabel {
            parts.append(size)
        }
        if model.mode == .custom, !model.supportsInstructionControl {
            parts.append("speaker only".localizedForDisplay)
        } else if model.mode == .custom {
            parts.append("delivery control".localizedForDisplay)
        }
        if model.mode == .clone, model.supportsVoiceClone {
            parts.append("clone capable".localizedForDisplay)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch presentation.kind {
        case .checking, .downloading:
            ProgressView()
                .controlSize(.mini)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.green)
                .imageScale(.small)
        case .notInstalled:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.secondary)
                .imageScale(.small)
        case .needsRepair:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .imageScale(.small)
        }
    }

    private var statusColor: Color {
        switch presentation.kind {
        case .ready:
            return .green
        case .needsRepair:
            return .orange
        default:
            return .secondary
        }
    }

    @ViewBuilder
    private var downloadProgress: some View {
        if case .downloading(let progress) = status,
           let total = progress.totalBytes,
           total > 0 {
            ProgressView(value: Double(progress.downloadedBytes), total: Double(total))
                .progressViewStyle(.linear)
                .tint(AppTheme.statusProgressTint)
                .accessibilityIdentifier("settings_downloadProgress_\(model.id)")
        }
    }

    private var manualDownloadDetails: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Hugging Face repository:".localizedForDisplay)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let repositoryPageURL {
                Text(repositoryPageURL.absoluteString)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Local model folder:".localizedForDisplay)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Text(localModelDirectory.path)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings_modelPath_\(model.id)")

            Text("Download the complete repository and preserve its directory structure.".localizedForDisplay)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Requires the official Hugging Face hf command-line tool.".localizedForDisplay)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Open Hugging Face") {
                    if let repositoryPageURL {
                        NSWorkspace.shared.open(repositoryPageURL)
                    }
                }
                .controlSize(.small)
                .disabled(repositoryPageURL == nil)
                .accessibilityIdentifier("settings_openHuggingFace_\(model.id)")

                Button("Copy Full Download Command") {
                    if let fullRepositoryDownloadCommand {
                        copyToPasteboard(fullRepositoryDownloadCommand)
                    }
                }
                .controlSize(.small)
                .disabled(fullRepositoryDownloadCommand == nil)
                .accessibilityIdentifier("settings_copyDownloadCommand_\(model.id)")
            }

            HStack(spacing: 8) {
                Button("Show Folder") {
                    revealModelLocation()
                }
                .controlSize(.small)
                .accessibilityIdentifier("settings_revealModelPath_\(model.id)")

                Button("Copy Path") {
                    copyToPasteboard(localModelDirectory.path)
                }
                .controlSize(.small)
                .accessibilityIdentifier("settings_copyModelPath_\(model.id)")

                Button("Recheck") {
                    Task { await viewModel.refresh() }
                }
                .controlSize(.small)
                .accessibilityIdentifier("settings_recheckModel_\(model.id)")
            }
        }
        .padding(.leading, 14)
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private func revealModelLocation() {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: localModelDirectory.path) {
            NSWorkspace.shared.activateFileViewerSelecting([localModelDirectory])
            return
        }
        try? fileManager.createDirectory(
            at: QwenVoiceApp.modelsDir,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(QwenVoiceApp.modelsDir)
    }
}

// MARK: - Action button

/// Compact package control whose role flips with install state.
private struct ActionButton: View {
    let model: TTSModel
    var viewModel: ModelManagerViewModel
    let onDelete: () -> Void

    /// Holder for the NSView that backs the Manage button's
    /// background, used as the anchor for the AppKit `NSMenu`'s
    /// popUp positioning.
    @State private var manageHostHolder = NSViewHostHolder()

    private var status: ModelManagerViewModel.ModelStatus {
        viewModel.statuses[model.id] ?? .checking
    }

    var body: some View {
        switch status {
        case .checking:
            ProgressView()
                .controlSize(.small)
                .accessibilityIdentifier("settings_checking_\(model.id)")

        case .notDownloaded:
            HoverableActionButton(title: downloadButtonTitle) {
                Task { await viewModel.download(model) }
            }
            .help(downloadHelp)
            .accessibilityIdentifier("settings_download_\(model.id)")

        case .downloading:
            HoverableActionButton(title: "Cancel") {
                Task { await viewModel.cancelDownload(model) }
            }
            .help("Cancel the download (discards partial data)")
            .accessibilityIdentifier("settings_cancel_\(model.id)")

        case .repairAvailable:
            HoverableActionButton(title: "Repair", tint: .orange) {
                Task { await viewModel.download(model) }
            }
            .accessibilityIdentifier("settings_repair_\(model.id)")

        case .downloaded:
            Button {
                presentManageMenu()
            } label: {
                Text("Manage")
                .frame(maxWidth: .infinity)
            }
            .background(NSViewHostAccessor(holder: manageHostHolder))
            .help(
                "\("Manage".localizedForDisplay) " +
                (model.variantKind?.displayName.localizedForDisplay ?? model.name)
            )
            .controlSize(.small)
            .accessibilityIdentifier("settings_manage_\(model.id)")
        }
    }

    private var downloadButtonTitle: String {
        "Download"
    }

    private var downloadHelp: String {
        if let size = viewModel.sizeText(for: model) {
            return "\("Download".localizedForDisplay) \(size)"
        }
        return "Download".localizedForDisplay
    }

    /// Build a real AppKit NSMenu and pop it up from the Manage
    /// button's host NSView. The closure-based items use a small
    /// retained `ClosureMenuItem` wrapper so we don't need a
    /// separate `@objc` controller.
    private func presentManageMenu() {
        guard let host = manageHostHolder.view else { return }

        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(
            title: AppLocalization.string("Reveal in Finder"),
            systemImage: "folder",
            handler: {
                let url = model.installDirectory(in: QwenVoiceApp.modelsDir)
                // `activateFileViewerSelecting(_:)` highlights the
                // model folder inside its parent (the macOS native
                // "Reveal in Finder" idiom), as opposed to
                // `open(_:)` which would open the folder's contents.
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        ))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(
            title: AppLocalization.string("Delete Model"),
            systemImage: "trash",
            isDestructive: true,
            handler: onDelete
        ))

        // Popping up at the bottom-leading corner of the host
        // makes the menu appear directly under the button.
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: host.bounds.height + 2),
            in: host
        )
    }
}

// MARK: - AppKit menu bridge

/// Holds a weak reference to the NSView that backs the SwiftUI
/// Manage button so we can position an AppKit `NSMenu` against
/// it. `@State`-friendly because it's a class — SwiftUI keeps the
/// same instance across renders.
private final class NSViewHostHolder {
    weak var view: NSView?
}

/// Captures the SwiftUI Button's host NSView via a transparent
/// background view. SwiftUI mounts the NSView in the same
/// position as the Button itself, so its `bounds` are usable as
/// the menu anchor.
private struct NSViewHostAccessor: NSViewRepresentable {
    let holder: NSViewHostHolder

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            holder.view = view
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        holder.view = nsView
    }
}

/// `NSMenuItem` subclass that retains a Swift closure and runs
/// it when the item is selected. Cleaner than a separate `@objc`
/// controller object — each item owns its own handler.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(
        title: String,
        systemImage: String? = nil,
        isDestructive: Bool = false,
        handler: @escaping () -> Void
    ) {
        self.handler = handler
        let localizedTitle = title.localizedForDisplay
        super.init(
            title: localizedTitle,
            action: #selector(invoke),
            keyEquivalent: ""
        )
        target = self
        if let systemImage {
            image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        }
        if isDestructive {
            attributedTitle = NSAttributedString(
                string: localizedTitle,
                attributes: [.foregroundColor: NSColor.systemRed]
            )
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported for ClosureMenuItem")
    }

    @objc private func invoke() {
        handler()
    }
}

// MARK: - Hoverable bordered button

/// Bordered button with a subtle hover highlight. macOS bordered
/// buttons in SwiftUI don't have a built-in hover state — only
/// press feedback — so the rest action surface reads as static
/// between clicks. `brightness(0.07)` on hover lifts every visible
/// pixel of the button (bezel, text, tint) without any
/// shape-matching gymnastics. Returns to resting brightness with a
/// short ease-out when the cursor leaves.
private struct HoverableActionButton: View {
    let title: String
    var tint: Color? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            action()
        } label: {
            Text(title.localizedForDisplay)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.small)
        .tint(tint)
        .brightness(isHovering ? 0.12 : 0)
        .scaleEffect(isHovering ? 1.02 : 1.0)
        .onHover { hovering in
            AppLaunchConfiguration.performAnimated(.easeOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
    }
}
