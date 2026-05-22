import SwiftUI

/// Bottom sheet that lets the user edit the Voice Design brief, replacing
/// the legacy inline `IOSVoiceDesignSetupCard` editor. Multi-line text
/// editor + reference starter rows. Caller binds to the brief string;
/// tapping a starter fills it and dismisses the sheet.
///
/// Per design_references/Vocello iOS/sheets.jsx (DesignBriefSheet pattern).
struct IOSVoiceDesignBriefSheet: View {
    @Binding var voiceDescription: String
    let tint: Color
    var presentation: IOSBottomSheetPresentationStyle = .system
    var onDismiss: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    private let startingPoints = [
        "A warm, deep narrator with a subtle British accent.",
        "A bright young female, energetic and conversational.",
        "A gravelly older male, slow, late-night radio.",
        "A calm, careful narrator, clear diction, neutral.",
    ]

    var body: some View {
        IOSBottomSheetSurface(
            title: "Voice brief",
            tint: tint,
            presentation: presentation,
            onDismiss: onDismiss
        ) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Describe the voice. Combine character, age, accent, and texture.")
                    .font(.system(size: 14, weight: .regular))
                    .lineSpacing(1)
                    .foregroundStyle(IOSAppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $voiceDescription)
                        .focused($isFocused)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(IOSAppTheme.textPrimary)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)

                    if voiceDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("A warm, deep narrator with a subtle British accent.")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(IOSAppTheme.textTertiary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 18)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 116)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(isFocused ? tint.opacity(0.40) : tint.opacity(0.22), lineWidth: 0.5)
                }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)

                Text("Starting points".uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.88)
                    .foregroundStyle(IOSAppTheme.textSecondary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)

                VStack(spacing: 8) {
                    ForEach(startingPoints, id: \.self) { startingPoint in
                        Button {
                            voiceDescription = startingPoint
                            IOSHaptics.selection()
                            closeSheet()
                        } label: {
                            Text(startingPoint)
                                .font(.system(size: 14, weight: .regular))
                                .lineSpacing(1)
                                .foregroundStyle(IOSAppTheme.textPrimary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.white.opacity(0.03))
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 24)
        }
    }

    private func closeSheet() {
        onDismiss?()
        dismiss()
    }
}
