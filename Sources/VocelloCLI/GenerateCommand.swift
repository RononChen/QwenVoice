import Foundation
import QwenVoiceCore

/// `vocello generate` — synthesize one clip headlessly via the in-process engine.
enum GenerateCommand {
    /// Machine-readable result emitted under `--json`.
    struct GenerateJSON: Encodable {
        let audioPath: String
        let durationSeconds: Double
        let wallSeconds: Double
        let realtimeFactor: Double
        let finishReason: String?
        let mode: String
        let variant: String
        let modelID: String
        let firstChunkMS: Double?
    }

    @MainActor
    static func run(_ argv: [String]) async throws {
        let args = Args(argv)
        if args.flag("help") { printHelp(); return }
        CLIOutput.configure(args)

        let mode = try resolveMode(args)
        let quality = try resolveQuality(args)
        let streaming = args.flag("stream")

        let text = try resolveText(args)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError("empty text — pass --text \"…\", --text-file <path>, or pipe text on stdin")
        }

        let dataDir = CLIPaths.dataDirectory(override: args.string("data-dir"))
        let manifestOverride = args.string("manifest").map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        }

        note("booting engine (data: \(dataDir.path))")
        let runtime = try await CLIRuntime.bootstrap(dataDirectory: dataDir, manifestOverride: manifestOverride)
        let modelID = try runtime.modelID(mode: mode, quality: quality)
        let payload = try await buildPayload(args, mode: mode, runtime: runtime)

        let outputPath = resolveOutputPath(args, dataDir: dataDir, mode: mode)
        ensureParentDirectory(of: outputPath)

        note("loading \(modelID)…")
        try await runtime.engine.loadModel(id: modelID)

        let request = GenerationRequest(
            mode: mode, modelID: modelID, text: text, outputPath: outputPath,
            shouldStream: streaming, payload: payload, generationID: UUID())

        // Streaming: drain the engine's event stream on a side task and record
        // the wall time to the first audio chunk (TTFC) — the user-perceived
        // latency the non-streaming path can't observe.
        let submitWall = Date()
        let firstChunkTask: Task<Double?, Never>? = streaming ? {
            let events = runtime.engine.events
            return Task.detached(priority: .utility) {
                for await event in events {
                    switch event {
                    case .chunk: return Date().timeIntervalSince(submitWall) * 1000
                    case .completed, .failed: return nil
                    default: continue
                    }
                }
                return nil
            }
        }() : nil

        note("generating (\(text.count) chars)\(streaming ? ", streaming" : "")…")
        let result = try await runtime.engine.generate(request)
        let wall = Date().timeIntervalSince(submitWall)
        var firstChunkMS: Double?
        if let firstChunkTask { firstChunkMS = await firstChunkTask.value }

        let rtf = wall > 0 ? result.durationSeconds / wall : 0
        if args.flag("json") {
            emitJSON(GenerateJSON(
                audioPath: result.audioPath, durationSeconds: result.durationSeconds,
                wallSeconds: wall, realtimeFactor: rtf,
                finishReason: result.finishReason?.rawValue,
                mode: mode.rawValue, variant: quality ? "quality" : "speed",
                modelID: modelID, firstChunkMS: firstChunkMS))
        } else {
            // stdout = machine-readable (the path). stderr = human notes.
            print(result.audioPath)
        }
        let ttfc = firstChunkMS.map { " · ttfc=\(String(format: "%.0f", $0))ms" } ?? ""
        note("✓ \(String(format: "%.2f", result.durationSeconds))s audio · rtf=\(String(format: "%.2f", rtf))\(ttfc) · finish=\(result.finishReason?.rawValue ?? "?")")

        if args.flag("play") {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            p.arguments = [result.audioPath]
            try? p.run(); p.waitUntilExit()
        }
    }

    // MARK: - Reusable request building (shared with `batch`)

    static func resolveMode(_ args: Args) throws -> GenerationMode {
        let modeStr = (args.string("mode") ?? "custom").lowercased()
        guard let mode = GenerationMode(rawValue: modeStr) else {
            throw CLIError("invalid --mode '\(modeStr)' (use custom | design | clone)")
        }
        return mode
    }

    static func resolveQuality(_ args: Args) throws -> Bool {
        switch (args.string("variant") ?? "speed").lowercased() {
        case "speed", "fast": return false
        case "quality", "hq": return true
        case let other: throw CLIError("invalid --variant '\(other)' (use speed | quality)")
        }
    }

    /// Build the payload for a (mode, args) pair. For clone this resolves the
    /// reference once; `batch` reuses it across all of its requests.
    @MainActor
    static func buildPayload(_ args: Args, mode: GenerationMode, runtime: CLIRuntime) async throws -> GenerationRequest.Payload {
        switch mode {
        case .custom:
            return .custom(speakerID: args.string("speaker") ?? runtime.defaultSpeakerID,
                           deliveryStyle: args.string("delivery"))
        case .design:
            return .design(voiceDescription: try args.require("voice-brief", "a voice description for Voice Design"),
                           deliveryStyle: args.string("delivery"))
        case .clone:
            return .clone(reference: try await resolveCloneReference(args, runtime: runtime))
        }
    }

    /// Build the clone reference from either a saved voice (--voice <name|id>)
    /// or a raw reference clip (--reference <wav> [--transcript "…"]).
    @MainActor
    static func resolveCloneReference(_ args: Args, runtime: CLIRuntime) async throws -> CloneReference {
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

    /// Resolve script text from --text, --text-file, or piped stdin (`-` forces stdin).
    static func resolveText(_ args: Args) throws -> String {
        if let t = args.string("text") {
            return t == "-" ? (readStdinText() ?? "") : t
        }
        if let f = args.string("text-file") {
            if f == "-" { return readStdinText() ?? "" }
            let path = (f as NSString).expandingTildeInPath
            do { return try String(contentsOfFile: path, encoding: .utf8) }
            catch { throw CLIError("could not read --text-file \(path): \(error.localizedDescription)") }
        }
        if let piped = readStdinText() { return piped }
        throw CLIError("missing text — pass --text \"…\", --text-file <path>, or pipe text on stdin")
    }

    /// Create the parent directory of an output path when it has one (a bare
    /// filename writes into the cwd — nothing to create).
    static func ensureParentDirectory(of outputPath: String) {
        let parent = URL(fileURLWithPath: outputPath).deletingLastPathComponent()
        if !parent.path.isEmpty, parent.path != "." {
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
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
                           (--text "…" | --text-file <path> | piped stdin) [--out <path>] [options]

        Options:
          --mode         custom (default) | design | clone
          --variant      speed (default) | quality
          --text         inline script text ("-" reads stdin)
          --text-file    read script text from a file ("-" reads stdin)
          --speaker      (custom) speaker id; default = contract default (see `vocello speakers list`)
          --voice-brief  (design) voice description
          --voice        (clone) saved voice name or id
          --reference    (clone) path to a reference .wav (alternative to --voice)
          --transcript   (clone) transcript of the --reference clip
          --delivery     optional delivery style
          --out          output .wav path; default → <data>/outputs/cli/
          --stream       streaming synthesis; reports first-chunk latency (TTFC)
          --play         play the result with afplay when done
          --json         emit a JSON result object on stdout instead of the bare path
          --quiet|--verbose   suppress / expand stderr progress notes
          --data-dir     runtime dir (default ~/Library/Application Support/QwenVoice[-Debug])
          --manifest     override path to qwenvoice_contract.json

        Prints the output WAV path on stdout (or a JSON object with --json).
        """)
    }
}
