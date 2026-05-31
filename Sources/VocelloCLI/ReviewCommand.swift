import Foundation
import QwenVoiceCore

/// One clip's agy listening verdict.
struct AgyVerdict: Sendable {
    let clip: String
    let len: String
    let state: String
    let flags: [String]
    /// real_defect | false_positive | uncertain
    let verdict: String
    let heard: String          // AUDIBLE_DEFECT | CLEAN | CANNOT_LISTEN | (raw)
    let reason: String
}

/// Drives `agy` (Antigravity/Gemini) as the audio ear for flagged clips. agy's
/// multimodal input rejects the engine's 24 kHz Int16 WAV mime, so we transcode
/// to AAC/m4a (built-in `afconvert`) first, then hand agy the m4a to LISTEN and
/// judge whether a flagged issue is a real audible defect or a false positive
/// (e.g. the natural pause at a comma). Dev/benchmark workflow only — never part
/// of the shipped app; the product still keeps user audio on-device.
enum AgyReviewer {
    static var isAvailable: Bool { resolveAgy() != nil && FileManager.default.isExecutableFile(atPath: "/usr/bin/afconvert") }

    @MainActor
    static func review(clip: String, text: String, len: String, state: String, flags: [String]) -> AgyVerdict {
        func v(_ verdict: String, _ heard: String, _ reason: String) -> AgyVerdict {
            AgyVerdict(clip: clip, len: len, state: state, flags: flags, verdict: verdict, heard: heard, reason: reason)
        }
        guard let agy = resolveAgy() else { return v("uncertain", "NO_AGY", "agy not found on PATH") }

        // Transcode WAV → m4a (Gemini-friendly mime).
        let tmpDir = NSTemporaryDirectory()
        let m4a = tmpDir + "vocello_review_\(UUID().uuidString).m4a"
        let conv = run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", clip, m4a])
        guard conv.code == 0, FileManager.default.fileExists(atPath: m4a) else {
            return v("uncertain", "CONVERT_FAILED", "afconvert failed: \(conv.out.prefix(120))")
        }
        defer { try? FileManager.default.removeItem(atPath: m4a) }

        let rubric = """
        Listen to the audio at: \(m4a) — use your own multimodal audio hearing only (do NOT use any external/cloud speech-to-text tool, and do NOT read project files). \
        It should say: "\(text)". An automated reference-free detector flagged: \(flags.joined(separator: ", ")). \
        Listening to the actual audio, is there an AUDIBLE unnatural silence gap, glitch, click, pop, or dropout mid-utterance, or does it sound like clean natural speech (with at most the natural brief pause at a comma or sentence boundary)? \
        Give ONE sentence describing what you actually hear, then end with a final line exactly one of: HEARD: AUDIBLE_DEFECT  /  HEARD: CLEAN  /  HEARD: CANNOT_LISTEN
        """
        let res = run(agy, ["-p", rubric, "--add-dir", tmpDir, "--print-timeout", "4m"])
        let out = res.out
        let heard = parseHeard(out)
        let verdict: String
        switch heard {
        case "AUDIBLE_DEFECT": verdict = "real_defect"
        case "CLEAN": verdict = "false_positive"
        default: verdict = "uncertain"
        }
        return v(verdict, heard, lastMeaningfulLine(out))
    }

    // MARK: - process + parsing

    private static func resolveAgy() -> String? {
        let home = NSHomeDirectory()
        for c in ["\(home)/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
        where FileManager.default.isExecutableFile(atPath: c) { return c }
        let (out, code) = run("/usr/bin/env", ["which", "agy"])
        let p = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return (code == 0 && !p.isEmpty) ? p : nil
    }

    /// Run a process, capturing combined stdout/stderr via a temp file (no pipe
    /// deadlock on large agent output). Blocks until exit.
    @discardableResult
    private static func run(_ exe: String, _ args: [String]) -> (out: String, code: Int32) {
        let logURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vocello_proc_\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let fh = try? FileHandle(forWritingTo: logURL)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let fh { p.standardOutput = fh; p.standardError = fh }
        do { try p.run() } catch {
            try? fh?.close(); try? FileManager.default.removeItem(at: logURL)
            return ("launch failed: \(error.localizedDescription)", -1)
        }
        p.waitUntilExit()
        try? fh?.close()
        let out = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: logURL)
        return (out, p.terminationStatus)
    }

    private static func parseHeard(_ out: String) -> String {
        let upper = out.uppercased()
        if upper.contains("HEARD: AUDIBLE_DEFECT") || upper.contains("HEARD:AUDIBLE_DEFECT") { return "AUDIBLE_DEFECT" }
        if upper.contains("HEARD: CLEAN") || upper.contains("HEARD:CLEAN") { return "CLEAN" }
        if upper.contains("HEARD: CANNOT_LISTEN") || upper.contains("CANNOT_LISTEN") { return "CANNOT_LISTEN" }
        return "UNPARSED"
    }

    private static func lastMeaningfulLine(_ out: String) -> String {
        let lines = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.uppercased().hasPrefix("HEARD:") }
        return String((lines.last ?? "").prefix(240))
    }
}

/// `vocello review` — adjudicate flagged clips by ear via agy.
enum ReviewCommand {
    @MainActor
    static func run(_ argv: [String]) async throws {
        let args = Args(argv)
        if args.flag("help") { printHelp(); return }
        guard AgyReviewer.isAvailable else {
            throw CLIError("agy and/or afconvert not available — `agy` must be on PATH and /usr/bin/afconvert present")
        }

        if let clip = args.string("clip") {
            let path = (clip as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else { throw CLIError("clip not found: \(path)") }
            let text = args.string("text") ?? ""
            let flags = (args.string("flags") ?? "unspecified").split(separator: ",").map(String.init)
            note("reviewing \(path) via agy…")
            let r = AgyReviewer.review(clip: path, text: text, len: "?", state: "?", flags: flags)
            printVerdict(r)
            return
        }

        // --diag <dir>: review every flagged clip from a bench run.
        let diag = (args.string("diag").map { ($0 as NSString).expandingTildeInPath })
            ?? CLIPaths.dataDirectory(override: nil).appendingPathComponent("diagnostics").path
        let flagged = FlaggedClips.discover(diagnosticsDir: diag)
        guard !flagged.isEmpty else { print("(no flagged clips found under \(diag))"); return }
        note("reviewing \(flagged.count) flagged clip(s) via agy (sequential; agy is heavy)…")
        var verdicts: [AgyVerdict] = []
        for f in flagged {
            let r = AgyReviewer.review(clip: f.clip, text: f.text, len: f.len, state: f.state, flags: f.flags)
            printVerdict(r)
            verdicts.append(r)
        }
        FlaggedClips.writeReviewLog(verdicts, diagnosticsDir: diag)
    }

    static func printVerdict(_ r: AgyVerdict) {
        let mark = r.verdict == "real_defect" ? "✗ REAL DEFECT" : r.verdict == "false_positive" ? "✓ false positive" : "? uncertain"
        print("\(mark)  [\(r.len)/\(r.state)] \(r.flags.joined(separator: ",")) — \(r.reason)")
    }

    static func printHelp() {
        print("""
        vocello review — adjudicate flagged clips by ear (agy multimodal listening)

        Usage:
          vocello review --clip <wav> [--text "…"] [--flags dropout:469ms]
          vocello review --diag <diagnostics-dir>     # review all flagged clips from a bench run

        Transcodes each clip to m4a (afconvert) and hands it to `agy` to LISTEN and
        judge real-defect vs false-positive (e.g. a natural comma pause). Dev workflow
        only. Writes verdicts to <diag>/review/review.jsonl in --diag mode.
        """)
    }
}

func note(_ message: String) { FileHandle.standardError.write(Data("• \(message)\n".utf8)) }

/// A flagged clip discovered from a bench run's diagnostics + outputs.
struct FlaggedClip { let clip: String; let text: String; let len: String; let state: String; let flags: [String] }

/// Correlates flagged engine telemetry rows (audioQC warn/fail) to the bench
/// output WAVs by the `<mode>_<modelID>_<len>_<state>_<n>.wav` naming convention,
/// one representative clip per flagged cell.
enum FlaggedClips {
    static func lenBucket(_ chars: Int) -> String {
        chars == 0 ? "n/a" : chars < 70 ? "short" : chars > 220 ? "long" : "medium"
    }

    static func discover(diagnosticsDir: String) -> [FlaggedClip] {
        let enginePath = (diagnosticsDir as NSString).appendingPathComponent("engine/generations.jsonl")
        guard let content = try? String(contentsOfFile: enginePath, encoding: .utf8) else { return [] }
        let benchOut = ((diagnosticsDir as NSString).deletingLastPathComponent as NSString).appendingPathComponent("outputs/bench")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: benchOut)) ?? []
        var seen = Set<String>()
        var result: [FlaggedClip] = []
        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let qc = row["audioQC"] as? [String: Any],
                  let verdict = qc["verdict"] as? String, verdict == "warn" || verdict == "fail" else { continue }
            let mode = row["mode"] as? String ?? "?"
            let modelID = (row["modelID"] as? String ?? "?").split(separator: "/").last.map(String.init) ?? "?"
            let state = row["warmState"] as? String ?? "?"
            let chars = Int((row["notes"] as? [String: Any])?["promptChars"] as? String ?? "0") ?? 0
            let len = lenBucket(chars)
            let key = "\(mode)|\(modelID)|\(len)|\(state)"
            if seen.contains(key) { continue }
            seen.insert(key)
            let pattern = "\(mode)_\(modelID)_\(len)_\(state)_"
            guard let f = files.filter({ $0.hasPrefix(pattern) && $0.hasSuffix(".wav") }).sorted().first else { continue }
            result.append(FlaggedClip(
                clip: (benchOut as NSString).appendingPathComponent(f),
                text: BenchCommand.corpus.first { $0.len == len }?.text ?? "",
                len: len, state: state, flags: (qc["flags"] as? [String]) ?? []))
        }
        return result
    }

    static func writeReviewLog(_ verdicts: [AgyVerdict], diagnosticsDir: String) {
        let dir = (diagnosticsDir as NSString).appendingPathComponent("review")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: (dir as NSString).appendingPathComponent("review.jsonl"))
        var lines = ""
        for v in verdicts {
            let obj: [String: Any] = [
                "clip": (v.clip as NSString).lastPathComponent, "len": v.len, "state": v.state,
                "flags": v.flags, "verdict": v.verdict, "heard": v.heard, "reason": v.reason,
            ]
            if let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) {
                lines += s + "\n"
            }
        }
        try? lines.write(to: url, atomically: true, encoding: .utf8)
        note("wrote \(url.path)")
    }
}
