import Foundation
import QwenVoiceCore

/// `vocello generate` — synthesize one clip headlessly via the in-process engine.
enum GenerateCommand {
    @MainActor
    static func run(_ argv: [String]) async throws {
        let args = Args(argv)
        if args.flag("help") { printHelp(); return }

        let modeStr = (args.string("mode") ?? "custom").lowercased()
        guard let mode = GenerationMode(rawValue: modeStr) else {
            throw CLIError("invalid --mode '\(modeStr)' (use custom | design | clone)")
        }
        let quality: Bool
        switch (args.string("variant") ?? "speed").lowercased() {
        case "speed", "fast": quality = false
        case "quality", "hq": quality = true
        case let other: throw CLIError("invalid --variant '\(other)' (use speed | quality)")
        }

        let text = try resolveText(args)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError("empty text — pass --text \"…\" or --text-file <path>")
        }

        let dataDir = CLIPaths.dataDirectory(override: args.string("data-dir"))
        let manifestOverride = args.string("manifest").map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        }

        note("booting engine (data: \(dataDir.path))")
        let runtime = try await CLIRuntime.bootstrap(dataDirectory: dataDir, manifestOverride: manifestOverride)
        let modelID = try runtime.modelID(mode: mode, quality: quality)

        let payload: GenerationRequest.Payload
        switch mode {
        case .custom:
            let speakerID = args.string("speaker") ?? runtime.defaultSpeakerID
            payload = .custom(speakerID: speakerID, deliveryStyle: args.string("delivery"))
        case .design:
            let brief = try args.require("voice-brief", "a voice description for Voice Design")
            payload = .design(voiceDescription: brief, deliveryStyle: args.string("delivery"))
        case .clone:
            payload = .clone(reference: try await resolveCloneReference(args, runtime: runtime))
        }

        let outputPath = resolveOutputPath(args, dataDir: dataDir, mode: mode)
        // Create the parent dir only when --out actually has one (a bare filename
        // writes into the cwd — no directory to create).
        let outParent = URL(fileURLWithPath: outputPath).deletingLastPathComponent()
        if !outParent.path.isEmpty, outParent.path != "." {
            try FileManager.default.createDirectory(at: outParent, withIntermediateDirectories: true)
        }

        note("loading \(modelID)…")
        try await runtime.engine.loadModel(id: modelID)

        let request = GenerationRequest(
            mode: mode, modelID: modelID, text: text, outputPath: outputPath,
            shouldStream: false, payload: payload, generationID: UUID())

        note("generating (\(text.count) chars)…")
        let result = try await runtime.engine.generate(request)

        // stdout = machine-readable (the path). stderr = human notes.
        print(result.audioPath)
        note("✓ \(String(format: "%.2f", result.durationSeconds))s · finish=\(result.finishReason?.rawValue ?? "?")")

        if args.flag("play") {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            p.arguments = [result.audioPath]
            try? p.run(); p.waitUntilExit()
        }
    }

    /// Build the clone reference from either a saved voice (--voice <name|id>)
    /// or a raw reference clip (--reference <wav> [--transcript "…"]).
    @MainActor
    private static func resolveCloneReference(_ args: Args, runtime: CLIRuntime) async throws -> CloneReference {
        if let ref = args.string("reference") {
            let path = (ref as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else {
                throw CLIError("reference audio not found: \(path)")
            }
            return CloneReference(audioPath: path, transcript: args.string("transcript"), preparedVoiceID: nil)
        }
        let name = try args.require("voice", "a saved voice name/id, or --reference <wav>")
        let voices = try await runtime.engine.listPreparedVoices()
        guard let voice = voices.first(where: { $0.name == name || $0.id == name }) else {
            let avail = voices.map(\.name).joined(separator: ", ")
            throw CLIError("no saved voice '\(name)' (have: \(avail.isEmpty ? "none" : avail))")
        }
        return CloneReference(audioPath: voice.audioPath, transcript: nil, preparedVoiceID: voice.id)
    }

    private static func resolveText(_ args: Args) throws -> String {
        if let t = args.string("text") { return t }
        if let f = args.string("text-file") {
            let path = (f as NSString).expandingTildeInPath
            do { return try String(contentsOfFile: path, encoding: .utf8) }
            catch { throw CLIError("could not read --text-file \(path): \(error.localizedDescription)") }
        }
        throw CLIError("missing text — pass --text \"…\" or --text-file <path>")
    }

    private static func resolveOutputPath(_ args: Args, dataDir: URL, mode: GenerationMode) -> String {
        if let out = args.string("out") { return (out as NSString).expandingTildeInPath }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return dataDir
            .appendingPathComponent("outputs/cli", isDirectory: true)
            .appendingPathComponent("\(fmt.string(from: Date()))_\(mode.rawValue).wav").path
    }

    static func printHelp() {
        print("""
        vocello generate — synthesize a clip headlessly

        Usage:
          vocello generate --mode custom|design|clone --variant speed|quality \\
                           (--text "…" | --text-file <path>) [--out <path>] [options]

        Options:
          --mode         custom (default) | design | clone
          --variant      speed (default) | quality
          --text         inline script text
          --text-file    read script text from a file
          --speaker      (custom) speaker id; default = contract default
          --voice-brief  (design) voice description
          --voice        (clone) saved voice name or id
          --reference    (clone) path to a reference .wav (alternative to --voice)
          --transcript   (clone) transcript of the --reference clip
          --delivery     optional delivery style
          --out          output .wav path; default → <data>/outputs/cli/
          --data-dir     runtime dir (default ~/Library/Application Support/QwenVoice[-Debug])
          --manifest     override path to qwenvoice_contract.json
          --play         play the result with afplay when done

        Prints the output WAV path on stdout.
        """)
    }
}
