import AVFoundation
import SwiftUI

/// Full-screen reference-clip capture surface from the iOS design reference
/// prototype (design_references/Vocello iOS/chrome.jsx RecordingOverlay).
/// Records a 24 kHz mono PCM WAV using AVAudioRecorder, shows a live
/// amplitude meter, and gates the "Use this clip" CTA to the 10-20s window
/// required by the Voice Cloning reference contract.
///
/// Consumers present this as a `.fullScreenCover` and receive the completed
/// WAV file URL via `onComplete`. The view does its own permission request;
/// callers don't need to pre-check microphone access.
struct IOSRecordingOverlay: View {
    var onComplete: (URL) -> Void
    var onCancel: () -> Void

    @StateObject private var recorder = IOSReferenceClipRecorder()

    @Environment(\.iosReduceMotionEnabled) private var reduceMotion

    var body: some View {
        ZStack {
            IOSModeBackdrop(tint: IOSBrandTheme.clone, intensity: .warm)
            Color(red: 13 / 255, green: 14 / 255, blue: 18 / 255)
                .opacity(0.70)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                captureStage
                Spacer()
                controls
            }
            .padding(.horizontal, 24)
            .padding(.top, 56)
            .padding(.bottom, 60)
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(true)
        .task {
            await recorder.requestPermissionIfNeeded()
        }
        .onDisappear {
            recorder.stopWithoutSaving()
        }
        .alert("Microphone access denied", isPresented: $recorder.showsPermissionAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {
                onCancel()
            }
        } message: {
            Text("Vocello needs the microphone to record reference clips. Enable it in Settings to continue.")
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Spacer()

            Button {
                recorder.stopWithoutSaving()
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(IOSAppTheme.textPrimary)
                    .frame(width: 40, height: 40)
                    .background {
                        Circle()
                            .fill(Color.white.opacity(0.06))
                    }
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    // MARK: - Capture stage

    private var progressColor: Color {
        if recorder.elapsed >= IOSReferenceClipRecorder.minDuration && recorder.elapsed <= IOSReferenceClipRecorder.maxDuration {
            return IOSBrandTheme.clone
        }
        if recorder.elapsed > IOSReferenceClipRecorder.maxDuration {
            return Color.orange
        }
        return IOSAppTheme.textTertiary
    }

    private var captureStage: some View {
        VStack(spacing: 28) {
            VStack(spacing: 28) {
                Text(phaseLabel.uppercased())
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(1.56)
                    .foregroundStyle(IOSAppTheme.textSecondary)

                Text(timeString)
                    .font(.system(size: 56, weight: .bold, design: .monospaced))
                    .tracking(-1.12)
                    .foregroundStyle(progressColor)
                    .monospacedDigit()

                Text("Read 10-20 s of clean, natural speech. Quiet room. One voice.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(IOSAppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 280)
            }

            // LIVE level meter driven by the real mic amplitude — bars rise when you speak
            // and fall when silent, so you can see your voice is heard + recorded.
            IOSLiveLevelMeter(
                levels: recorder.levels,
                tint: IOSBrandTheme.clone,
                isActive: recorder.isRecording
            )
            .frame(height: 96)
            .opacity(recorder.isRecording ? 1 : (recorder.elapsed > 0 ? 0.8 : 0.4))

            Text(statusLabel)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(IOSAppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var phaseLabel: String {
        if recorder.isRecording { return "Recording" }
        if recorder.elapsed > 0 { return "Captured" }
        return "Reference clip"
    }

    private var statusLabel: String {
        if !recorder.isRecording && recorder.elapsed == 0 {
            return "Tap Record to begin."
        }
        if recorder.elapsed < IOSReferenceClipRecorder.minDuration {
            return "Keep recording. 10 second minimum."
        }
        if recorder.elapsed <= IOSReferenceClipRecorder.maxDuration {
            return "Sounds good. Tap stop when ready."
        }
        return "Over 20 seconds. Stop now."
    }

    private var timeString: String {
        let total = max(0, Int(recorder.elapsed.rounded(.down)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 12) {
            if recorder.isRecording {
                IOSPrimaryCTAButton(
                    title: "Stop",
                    symbol: "stop.fill",
                    tint: IOSBrandTheme.clone,
                    isEnabled: true,
                    action: {
                        if let url = recorder.stopAndSave() {
                            onComplete(url)
                        }
                    }
                )
            } else if recorder.elapsed > 0 {
                Button("Retake") {
                    recorder.reset()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(IOSAppTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background {
                    Capsule(style: .continuous)
                        .fill(IOSAppTheme.glassSurfaceFillMuted)
                }
                .buttonStyle(.plain)

                let canUse = recorder.elapsed >= IOSReferenceClipRecorder.minDuration
                IOSPrimaryCTAButton(
                    title: canUse ? "Use this clip" : "Need 10 s",
                    symbol: canUse ? "checkmark" : nil,
                    tint: IOSBrandTheme.clone,
                    isEnabled: canUse,
                    action: {
                        if let url = recorder.lastSavedURL {
                            onComplete(url)
                        }
                    }
                )
            } else {
                IOSPrimaryCTAButton(
                    title: "Record",
                    symbol: "mic.fill",
                    tint: IOSBrandTheme.clone,
                    isEnabled: !recorder.permissionDenied,
                    action: {
                        Task { await recorder.start() }
                    }
                )
            }
        }
    }
}

// MARK: - Recorder

@MainActor
final class IOSReferenceClipRecorder: NSObject, ObservableObject {
    static let minDuration: Double = 10.0
    static let maxDuration: Double = 20.0

    @Published private(set) var isRecording: Bool = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var amplitude: Double = 0
    /// Rolling history of recent mic levels (oldest → newest, 0…1) that drives the live
    /// level meter so the user can SEE their voice being heard + recorded.
    @Published private(set) var levels: [Double] = []
    @Published var showsPermissionAlert: Bool = false
    @Published private(set) var permissionDenied: Bool = false
    @Published private(set) var lastSavedURL: URL?

    /// ~80 ms/sample × 48 ≈ a 3.8 s scrolling window.
    private let maxLevels = 48

    private var recorder: AVAudioRecorder?
    private var meteringTimer: Timer?
    private var startedAt: Date?

    func requestPermissionIfNeeded() async {
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined:
            _ = await AVAudioApplication.requestRecordPermission()
        case .denied:
            permissionDenied = true
            showsPermissionAlert = true
        case .granted:
            permissionDenied = false
        @unknown default:
            break
        }
    }

    func start() async {
        guard !isRecording else { return }

        switch AVAudioApplication.shared.recordPermission {
        case .denied:
            permissionDenied = true
            showsPermissionAlert = true
            return
        case .undetermined:
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else {
                permissionDenied = true
                showsPermissionAlert = true
                return
            }
        case .granted:
            break
        @unknown default:
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true, options: [])

            let url = makeOutputURL()
            // 24 kHz mono Int16 PCM matches the Vocello clone-reference
            // contract; AVAudioRecorder writes a WAV (since the extension
            // is .wav) and the platform handles any required downsampling
            // from the hardware rate.
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 24_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            recorder.delegate = self
            guard recorder.record(forDuration: Self.maxDuration + 0.5) else {
                return
            }

            self.recorder = recorder
            self.isRecording = true
            self.startedAt = Date()
            self.elapsed = 0
            self.amplitude = 0
            self.levels = []
            startMetering()
        } catch {
            isRecording = false
        }
    }

    @discardableResult
    func stopAndSave() -> URL? {
        guard let recorder else { return nil }
        recorder.stop()
        meteringTimer?.invalidate()
        meteringTimer = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false)
        lastSavedURL = recorder.url
        return recorder.url
    }

    func stopWithoutSaving() {
        recorder?.stop()
        if let url = recorder?.url {
            try? FileManager.default.removeItem(at: url)
        }
        recorder = nil
        meteringTimer?.invalidate()
        meteringTimer = nil
        isRecording = false
        elapsed = 0
        amplitude = 0
        levels = []
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    func reset() {
        stopWithoutSaving()
        lastSavedURL = nil
    }

    private func startMetering() {
        meteringTimer?.invalidate()
        meteringTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.tickMeter()
            }
        }
    }

    private func tickMeter() {
        guard let recorder, let startedAt else { return }
        recorder.updateMeters()
        // averagePower is in dBFS (-160 ... 0). Map to 0...1 with light
        // gamma so the meter feels visually responsive without overshooting
        // on loud speech.
        let dB = Double(recorder.averagePower(forChannel: 0))
        let normalized = pow(max(0, (dB + 50) / 50), 1.4)
        amplitude = min(1.0, normalized)
        levels.append(amplitude)
        if levels.count > maxLevels {
            levels.removeFirst(levels.count - maxLevels)
        }
        elapsed = Date().timeIntervalSince(startedAt)
        if elapsed >= Self.maxDuration + 0.4 {
            // Hardware cap reached; auto-stop and keep the WAV.
            _ = stopAndSave()
        }
    }

    private func makeOutputURL() -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-clone-references", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return tmp.appendingPathComponent("reference-\(stamp).wav", isDirectory: false)
    }
}

extension IOSReferenceClipRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.meteringTimer?.invalidate()
            self.meteringTimer = nil
            self.isRecording = false
            if flag {
                self.lastSavedURL = recorder.url
            }
        }
    }
}

// MARK: - Live level meter

/// A clean scrolling level meter for the recorder: each bar is a recent mic-amplitude sample
/// (newest on the right), centered so it reads as a waveform. It's driven by the REAL input
/// (`recorder.levels`), so it visibly rises when the user speaks and falls when silent —
/// honest feedback that the voice is being heard + recorded. Data-driven (no decorative
/// animation), so it stays truthful under Reduce Motion.
struct IOSLiveLevelMeter: View {
    let levels: [Double]
    let tint: Color
    var isActive: Bool = true

    private let barCount = 48
    private let spacing: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let barWidth = max(2.5, (geo.size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    let level = sample(at: i)
                    let height = max(3, geo.size.height * CGFloat(0.04 + 0.96 * level))
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [tint, tint.opacity(0.55)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: barWidth, height: height)
                        .opacity(opacity(at: i))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
    }

    /// Bar index 0 = left/oldest … `barCount-1` = right/newest; left-pad with silence until
    /// the buffer fills so the live edge scrolls in from the right.
    private func sample(at index: Int) -> Double {
        let offsetFromNewest = (barCount - 1) - index
        let srcIndex = levels.count - 1 - offsetFromNewest
        guard srcIndex >= 0, srcIndex < levels.count else { return 0 }
        return min(1, max(0, levels[srcIndex]))
    }

    /// Gentle left-fade so the live leading edge (the current voice) reads brightest.
    private func opacity(at index: Int) -> Double {
        guard isActive else { return 0.3 }
        let t = Double(index) / Double(max(1, barCount - 1))
        return 0.4 + 0.6 * t
    }
}
