import AVFoundation
import Foundation
import Speech

/// Best-effort **on-device** transcription of a finished reference WAV, used to pre-fill the
/// (editable, optional) transcript when enrolling a recorded voice.
///
/// The transcript is OPTIONAL for Qwen3-TTS cloning — it improves prompt quality + enables the
/// conditioning cache, but generation works without it (see `NativeCloneSupport.swift`). So every
/// failure path returns `nil` and the enrollment flow is never blocked.
///
/// **Language:** the recording's language can differ from the app's (e.g. an English UI user who
/// speaks French). `SFSpeechRecognizer` has no language auto-detect, so we transcribe with each of
/// the user's **preferred languages** (`Locale.preferredLanguages`, on-device-capable only) and
/// keep the best result — confidence-ranked, falling back to the first non-empty pass when
/// on-device confidence isn't reported. Audio never leaves the device (`requiresOnDeviceRecognition`).
enum VoiceClipTranscriber {
    /// Max recognition passes (each is a full pass over the clip; the user's top languages first).
    private static let maxCandidates = 2

    static func transcribe(url: URL) async -> String? {
        guard await requestAuthorization() else { return nil }

        var best: (text: String, confidence: Float)?
        var firstNonEmpty: String?

        for locale in candidateLocales() {
            guard let pass = await recognize(url: url, locale: locale) else { continue }
            if firstNonEmpty == nil { firstNonEmpty = pass.text }
            if best == nil || pass.confidence > best!.confidence {
                best = pass
            }
            // A clearly-confident pass means we found the right language — stop early.
            if pass.confidence >= 0.85 { break }
        }

        // Prefer the highest-confidence pass; if confidence was never reported (on-device often
        // leaves it at 0), fall back to the first non-empty (the top preferred language).
        let chosen: String?
        if let best, best.confidence > 0 {
            chosen = best.text
        } else {
            chosen = firstNonEmpty
        }
        let trimmed = chosen?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// The user's preferred languages mapped to supported on-device recognition locales (deduped
    /// by language code, in preference order), capped to a couple of passes.
    private static func candidateLocales() -> [Locale] {
        let supported = SFSpeechRecognizer.supportedLocales()
        var result: [Locale] = []
        var seenLanguages = Set<String>()

        for identifier in Locale.preferredLanguages {
            guard let language = Locale(identifier: identifier).language.languageCode?.identifier,
                  !seenLanguages.contains(language) else { continue }
            let match = supported.first { locale in
                locale.language.languageCode?.identifier == language
                    && (SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition ?? false)
            }
            if let match {
                seenLanguages.insert(language)
                result.append(match)
            }
            if result.count >= maxCandidates { break }
        }

        if result.isEmpty,
           let fallback = SFSpeechRecognizer(),
           fallback.supportsOnDeviceRecognition {
            result = [fallback.locale]
        }
        return result
    }

    private static func recognize(url: URL, locale: Locale) async -> (text: String, confidence: Float)? {
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else { return nil }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        let once = ResumeOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<(text: String, confidence: Float)?, Never>) in
            recognizer.recognitionTask(with: request) { result, error in
                if error != nil {
                    once.run { continuation.resume(returning: nil) }
                    return
                }
                guard let result, result.isFinal else { return }
                let transcription = result.bestTranscription
                let text = transcription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                let segments = transcription.segments
                let confidence = segments.isEmpty
                    ? 0
                    : segments.map(\.confidence).reduce(0, +) / Float(segments.count)
                once.run {
                    continuation.resume(returning: text.isEmpty ? nil : (text, confidence))
                }
            }
        }
    }

    private static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}

/// One-shot guard so the recognition callback (which may fire more than once) resumes the
/// continuation exactly once. Lock-guarded so it's safe to capture in the `@Sendable` handler.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func run(_ block: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return }
        fired = true
        block()
    }
}
