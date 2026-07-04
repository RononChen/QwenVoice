import Foundation

/// Copies a finished reference-clip recording out of the recorder's temp dir before
/// `ReferenceClipRecorder.stopWithoutSaving()` runs on overlay dismissal.
enum ReferenceClipRecordingStash {
    /// Returns a stable temp copy, or `nil` if the copy failed (callers may fall back to `url`).
    static func copyToStableTemp(_ url: URL) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-enroll", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(UUID().uuidString).wav", isDirectory: false)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        } catch {
            return nil
        }
    }
}
