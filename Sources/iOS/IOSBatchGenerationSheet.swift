import SwiftUI
import QwenVoiceCore

struct IOSBatchGenerationSheet: View {
    @EnvironmentObject private var ttsEngine: TTSEngineStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.presentIOSPlayerSheet) private var presentPlayerSheet

    let mode: GenerationMode
    let tint: Color
    let requestBuilder: @MainActor (String) -> (request: GenerationRequest, model: TTSModel)?

    @StateObject private var coordinator = IOSBatchGenerationCoordinator()
    @State private var batchText: String = ""

    private var trimmedLineCount: Int {
        batchText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count
    }

    private var canStart: Bool {
        !coordinator.isProcessing
            && !coordinator.didCompleteAll
            && trimmedLineCount > 0
            && ttsEngine.isReady
            && !ttsEngine.hasActiveGeneration
    }

    var body: some View {
        NavigationStack {
            ZStack {
                IOSScreenBackdrop()
                content
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        coordinator.cancel()
                        dismiss()
                    }
                    .accessibilityIdentifier("batchSheetClose")
                }
            }
            .navigationTitle("Batch generation")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.large])
    }

    @ViewBuilder
    private var content: some View {
        if coordinator.items.isEmpty {
            editor
        } else {
            progress
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Each line becomes its own generation. They run one at a time on this device.")
                .font(IOSTypeStyle.body.font)
                .foregroundStyle(IOSAppTheme.textSecondary)

            ZStack(alignment: .topLeading) {
                IOSMultilineTextView(
                    text: $batchText,
                    placeholder: "Enter one line per generation…",
                    tint: tint,
                    isFocused: .constant(false),
                    accessibilityIdentifier: "batchSheetInput"
                )
                .frame(minHeight: 220)
            }
            .iosSelectionFieldChrome(tint: tint, isFocused: false)

            HStack {
                Text("\(trimmedLineCount) line\(trimmedLineCount == 1 ? "" : "s")")
                    .font(IOSTypeStyle.footnote.font)
                    .foregroundStyle(IOSAppTheme.textSecondary)
                Spacer()
            }

            if let topLevelError = coordinator.topLevelError {
                Text(topLevelError)
                    .font(IOSTypeStyle.footnote.font)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            Button {
                IOSHaptics.selection()
                coordinator.start(
                    lines: batchText.components(separatedBy: .newlines),
                    requestBuilder: requestBuilder,
                    engine: ttsEngine
                )
            } label: {
                Label("Generate batch", systemImage: "list.bullet.indent")
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .disabled(!canStart)
            .accessibilityIdentifier("batchSheetStart")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusHeader
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(coordinator.items.enumerated()), id: \.element.id) { offset, item in
                        IOSBatchItemRow(
                            index: offset + 1,
                            item: item,
                            tint: tint,
                            onPlay: {
                                guard let playerItem = playerSheetItem(for: item) else {
                                    return
                                }
                                IOSHaptics.selection()
                                presentPlayerSheet(playerItem)
                            }
                        )
                    }
                }
                .padding(.vertical, 4)
            }

            Spacer(minLength: 0)

            bottomActionRow
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var statusHeader: some View {
        let completed = coordinator.successCount + coordinator.failureCount
        let total = coordinator.items.count
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(completed) of \(total) complete")
                .font(IOSTypeStyle.bodyStrong.font)
                .foregroundStyle(IOSAppTheme.textPrimary)
            Text(headerSubtitle)
                .font(IOSTypeStyle.footnote.font)
                .foregroundStyle(IOSAppTheme.textSecondary)
        }
    }

    private func playerSheetItem(for item: IOSBatchGenerationCoordinator.Item) -> IOSPlayerSheetItem? {
        guard let audioPath = item.audioPath,
              FileManager.default.fileExists(atPath: audioPath) else {
            return nil
        }
        return IOSPlayerSheetItem(
            audioURL: URL(fileURLWithPath: audioPath),
            transcript: item.text,
            voiceName: "Batch take",
            modeLabel: mode.rawValue.capitalized,
            modeTint: tint,
            subtitle: "Batch generation",
            avatarSeed: audioPath,
            avatarInitials: "Batch",
            waveformSeed: IOSStableVisualHash.int(audioPath)
        )
    }

    private var headerSubtitle: String {
        if coordinator.isProcessing {
            return coordinator.isCancelling ? "Cancelling…" : "Running on-device. Keep the app foreground."
        }
        if coordinator.didCompleteAll {
            if coordinator.failureCount == 0 {
                return "All takes saved to History."
            }
            return "\(coordinator.successCount) saved · \(coordinator.failureCount) failed"
        }
        return ""
    }

    @ViewBuilder
    private var bottomActionRow: some View {
        if coordinator.isProcessing {
            Button(role: .destructive) {
                coordinator.cancel()
            } label: {
                Label("Cancel batch", systemImage: "xmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(coordinator.isCancelling)
            .accessibilityIdentifier("batchSheetCancel")
        } else {
            HStack(spacing: 10) {
                Button {
                    coordinator.reset()
                    batchText = ""
                } label: {
                    Label("New batch", systemImage: "plus.circle")
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(tint)
                .accessibilityIdentifier("batchSheetNewBatch")

                Button {
                    dismiss()
                } label: {
                    Label("Done", systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .accessibilityIdentifier("batchSheetDone")
            }
        }
    }
}

private struct IOSBatchItemRow: View {
    let index: Int
    let item: IOSBatchGenerationCoordinator.Item
    let tint: Color
    let onPlay: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index).")
                .font(IOSTypeStyle.bodyStrong.font)
                .foregroundStyle(IOSAppTheme.textSecondary)
                .frame(width: 28, alignment: .trailing)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.text)
                    .font(IOSTypeStyle.body.font)
                    .foregroundStyle(IOSAppTheme.textPrimary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                if let error = item.errorMessage, item.state == .failed {
                    Text(error)
                        .font(IOSTypeStyle.caption.font)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 4)

            statusBadge
        }
        .padding(12)
        .iosSubtleGlassSurface(
            in: RoundedRectangle(cornerRadius: 14, style: .continuous),
            tint: tint
        )
        .accessibilityIdentifier("batchSheetRow_\(index)")
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch item.state {
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(IOSAppTheme.textSecondary)
        case .running:
            ProgressView()
                .controlSize(.small)
        case .succeeded:
            Button(action: onPlay) {
                Image(systemName: "play.fill")
            }
            .iosAdaptiveUtilityButtonStyle(prominent: true, tint: tint)
            .accessibilityIdentifier("batchSheetPlay_\(index)")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}
