import SwiftUI
import AppKit

struct TextInputView: View {
    @Binding var text: String
    @Binding var speechRate: Double
    @Binding var generateSubtitles: Bool

    var isGenerating: Bool
    var placeholder: String = "Type or paste your script"
    var buttonColor: Color = AppTheme.customVoice
    var batchAction: (() -> Void)? = nil
    var batchDisabled: Bool = true
    var generateDisabled: Bool = false
    var isEmbedded: Bool = false
    var usesFlexibleEmbeddedHeight: Bool = false
    var onGenerate: () -> Void
    var onCancel: (() -> Void)? = nil

    @State private var isEditorFocused = false

    private var isTextEmptyForGeneration: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var subtitleGenerationIsBlocked: Bool {
        generateSubtitles && !SubtitleModelManager.shared.isReady
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isEmbedded ? LayoutConstants.composerEmbeddedSpacing : 12) {
            editor
            actionRow
        }
        .frame(maxHeight: usesFlexibleEmbeddedHeight ? .infinity : nil, alignment: .topLeading)
        .background(shortcutBridge)
    }

    private var editor: some View {
        ScriptTextEditor(
            text: $text,
            placeholder: placeholder,
            font: .systemFont(ofSize: NSFont.systemFontSize),
            isFocused: $isEditorFocused
        )
        .padding(isEmbedded ? LayoutConstants.composerEmbeddedEditorInset : 8)
        .frame(
            maxWidth: .infinity,
            minHeight: isEmbedded ? LayoutConstants.composerEmbeddedMinHeight : 160,
            maxHeight: usesFlexibleEmbeddedHeight && isEmbedded ? .infinity : LayoutConstants.textEditorMaxHeight,
            alignment: .topLeading
        )
        .glassTextField(
            radius: 10,
            strokeColor: isEditorFocused ? buttonColor.opacity(0.24) : AppTheme.fieldStroke
        )
        .frame(maxHeight: usesFlexibleEmbeddedHeight ? .infinity : nil, alignment: .topLeading)
    }

    private var actionRow: some View {
        HStack(alignment: .center, spacing: isEmbedded ? 10 : 12) {
            ControlGroup {
                if let batchAction {
                    Button("Batch") {
                        batchAction()
                    }
                    .buttonStyle(.bordered)
                    .disabled(batchDisabled)
                    .accessibilityIdentifier("textInput_batchButton")
                }

                if isGenerating, let onCancel {
                    Button {
                        onCancel()
                    } label: {
                        Label("Cancel", systemImage: "stop.fill")
                            .frame(minWidth: 100)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .accessibilityIdentifier("textInput_cancelButton")
                } else {
                    Button {
                        onGenerate()
                    } label: {
                        Label("Generate", systemImage: "waveform")
                            .frame(minWidth: 100)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(buttonColor)
                    .disabled(
                        isTextEmptyForGeneration
                            || isGenerating
                            || generateDisabled
                            || subtitleGenerationIsBlocked
                    )
                    .accessibilityIdentifier("textInput_generateButton")
                }
            }

            SpeechRateField(rate: $speechRate, isDisabled: isGenerating)
            SubtitleGenerationControl(
                isEnabled: $generateSubtitles,
                isDisabled: isGenerating
            )

            Spacer(minLength: 0)

            characterCount
        }
    }

    /// Pairs the character count with an icon when the script crosses
    /// the 500-char "long" threshold. Color-only signal (the prior
    /// orange-tint-on-overflow) violated WCAG 1.4.1; the icon +
    /// accessibility label give non-color-perceiving users the same
    /// information.
    private var characterCount: some View {
        let isLong = text.count > 500
        let baseLabel = AppLocalization.format("%lld characters", Int64(text.count))
        return HStack(spacing: 6) {
            if isLong {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            }
            Text(baseLabel.localizedForDisplay)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(isLong ? .orange : .secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isLong
                ? AppLocalization.format("%@, long script", baseLabel)
                : baseLabel
        )
        .accessibilityIdentifier("textInput_charCount")
    }

    private var shortcutBridge: some View {
        Button("", action: onGenerate)
            .keyboardShortcut(.return, modifiers: .command)
            .opacity(0.001)
            .disabled(
                isTextEmptyForGeneration
                    || isGenerating
                    || generateDisabled
                    || subtitleGenerationIsBlocked
            )
            .accessibilityHidden(true)
    }
}

struct SubtitleGenerationControl: View {
    @Binding var isEnabled: Bool
    var isDisabled = false

    @State private var modelManager = SubtitleModelManager.shared

    var body: some View {
        HStack(spacing: 6) {
            Toggle("Generate SRT".localizedForDisplay, isOn: $isEnabled)
                .toggleStyle(.checkbox)
                .disabled(isDisabled)
                .accessibilityIdentifier("textInput_generateSRTToggle")
                .onChange(of: isEnabled) { _, enabled in
                    if enabled, !modelManager.isReady {
                        modelManager.install()
                    }
                }

            switch modelManager.state {
            case .checking:
                if isEnabled {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Checking subtitle model".localizedForDisplay)
                }
            case .downloading:
                if isEnabled {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Downloading subtitle model".localizedForDisplay)
                    Text("574 MB")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            case .failed:
                if isEnabled {
                    Button {
                        modelManager.install()
                    } label: {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help("Retry subtitle model download".localizedForDisplay)
                    .accessibilityLabel("Retry subtitle model download".localizedForDisplay)
                }
            case .notInstalled, .ready:
                EmptyView()
            }
        }
        .help(subtitleHelpText.localizedForDisplay)
    }

    private var subtitleHelpText: String {
        switch modelManager.state {
        case .checking:
            return "Checking the local subtitle model."
        case .notInstalled:
            return "Generate an SRT from the final WAV. Enabling this downloads a 574 MB local model once."
        case .downloading:
            return "Downloading the 574 MB subtitle model. Generation is available when the download finishes."
        case .ready:
            return "Generate an SRT beside the final WAV after speech-rate adjustment."
        case .failed(let message):
            return AppLocalization.format("Subtitle model download failed: %@", message)
        }
    }
}

struct SpeechRateField: View {
    @Binding var rate: Double
    var isDisabled = false

    @State private var input: String
    @FocusState private var isFocused: Bool

    init(rate: Binding<Double>, isDisabled: Bool = false) {
        _rate = rate
        self.isDisabled = isDisabled
        _input = State(initialValue: SpeechRateControl.formatted(rate.wrappedValue))
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("Speech rate".localizedForDisplay)
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("1.00", text: $input)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .focused($isFocused)
                .onSubmit(commit)
                .onChange(of: isFocused) { _, focused in
                    if !focused { commit() }
                }
                .onChange(of: input) { _, newValue in
                    let sanitized = sanitize(newValue)
                    if sanitized != newValue {
                        input = sanitized
                        return
                    }
                    guard let value = Double(sanitized),
                          value >= SpeechRateControl.minimum,
                          value <= SpeechRateControl.maximum else { return }
                    rate = SpeechRateControl.normalized(value)
                }
                .onChange(of: rate) { _, newValue in
                    guard !isFocused else { return }
                    input = SpeechRateControl.formatted(newValue)
                }
                .disabled(isDisabled)
                .accessibilityIdentifier("textInput_speechRateField")
                .accessibilityLabel("Speech rate".localizedForDisplay)
                .accessibilityValue(SpeechRateControl.formatted(rate))

            Text("×")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .help("Enter a value from 0.01 to 2.50. 1.00 is the original speed.".localizedForDisplay)
    }

    private func commit() {
        let parsed = Double(input) ?? rate
        let normalized = SpeechRateControl.normalized(parsed)
        rate = normalized
        input = SpeechRateControl.formatted(normalized)
    }

    private func sanitize(_ value: String) -> String {
        let normalizedSeparator = value.replacingOccurrences(of: ",", with: ".")
        var output = ""
        var sawDecimalPoint = false
        var fractionDigits = 0
        for character in normalizedSeparator {
            if character.isNumber {
                if sawDecimalPoint {
                    guard fractionDigits < 2 else { continue }
                    fractionDigits += 1
                }
                output.append(character)
            } else if character == ".", !sawDecimalPoint {
                sawDecimalPoint = true
                output.append(character)
            }
        }
        return output
    }
}

// MARK: - Native NSTextView wrapper

struct ScriptTextEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let font: NSFont
    @Binding var isFocused: Bool
    var accessibilityIdentifier: String = "textInput_textEditor"

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = PlaceholderTextView()

        textView.font = font
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.lineFragmentPadding = 4
        textView.delegate = context.coordinator
        textView.string = text
        textView.placeholderString = placeholder.localizedForDisplay
        textView.identifier = NSUserInterfaceItemIdentifier(accessibilityIdentifier)
        textView.setAccessibilityIdentifier(accessibilityIdentifier)
        textView.setAccessibilityEnabled(true)
        textView.onFocusChange = { focused in
            DispatchQueue.main.async { isFocused = focused }
        }

        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = textView

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? PlaceholderTextView else { return }
        if textView.identifier?.rawValue != accessibilityIdentifier {
            textView.identifier = NSUserInterfaceItemIdentifier(accessibilityIdentifier)
            textView.setAccessibilityIdentifier(accessibilityIdentifier)
        }
        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ScriptTextEditor

        init(_ parent: ScriptTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

final class PlaceholderTextView: NSTextView {
    var placeholderString: String = ""
    var onFocusChange: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocusChange?(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { onFocusChange?(false) }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if string.isEmpty, let font = self.font {
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.tertiaryLabelColor,
                .font: font
            ]
            let inset = textContainerInset
            let padding = textContainer?.lineFragmentPadding ?? 0
            let rect = NSRect(
                x: inset.width + padding,
                y: inset.height,
                width: bounds.width - (inset.width + padding) * 2,
                height: bounds.height - inset.height * 2
            )
            placeholderString.draw(in: rect, withAttributes: attrs)
        }
    }
}
