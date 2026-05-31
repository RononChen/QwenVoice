import Foundation
import QwenVoiceCore

/// `vocello voices` — manage saved (enrolled) clone voices.
enum VoicesCommand {
    @MainActor
    static func run(_ argv: [String]) async throws {
        var argv = argv
        let action = argv.first.map { $0.lowercased() } ?? "list"
        if !argv.isEmpty { argv.removeFirst() }
        if action == "help" || action == "--help" { printHelp(); return }

        let args = Args(argv)
        let runtime = try await CLIRuntime.bootstrap(
            dataDirectory: CLIPaths.dataDirectory(override: args.string("data-dir")),
            manifestOverride: args.string("manifest").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) })

        switch action {
        case "list", "ls":
            let voices = try await runtime.engine.listPreparedVoices()
            if voices.isEmpty {
                print("(no saved voices)")
                return
            }
            for v in voices {
                let warn = v.qualityWarnings.isEmpty ? "" : "  ⚠ \(v.qualityWarnings.joined(separator: ","))"
                print("\(v.name)\t[\(v.id)]\ttranscript=\(v.hasTranscript)\(warn)")
            }
        case "enroll", "add":
            let name = try args.require("name", "a name for the voice")
            let audio = try args.require("audio", "path to the reference .wav")
            let audioPath = (audio as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: audioPath) else {
                throw CLIError("audio not found: \(audioPath)")
            }
            let voice = try await runtime.engine.enrollPreparedVoice(
                name: name, audioPath: audioPath, transcript: args.string("transcript"))
            print("enrolled \(voice.name) [\(voice.id)]")
            if !voice.qualityWarnings.isEmpty {
                FileHandle.standardError.write(Data("⚠ \(voice.qualityWarnings.joined(separator: ", "))\n".utf8))
            }
        case "delete", "rm":
            let id = try args.require("id", "the saved voice id (see `voices list`)")
            try await runtime.engine.deletePreparedVoice(id: id)
            print("deleted \(id)")
        default:
            throw CLIError("unknown voices action '\(action)' (use list | enroll | delete)")
        }
    }

    static func printHelp() {
        print("""
        vocello voices — manage saved clone voices

        Usage:
          vocello voices list
          vocello voices enroll --name <name> --audio <wav> [--transcript "…"]
          vocello voices delete --id <id>

        Options:
          --data-dir   runtime dir (default ~/Library/Application Support/QwenVoice[-Debug])
          --manifest   override path to qwenvoice_contract.json
        """)
    }
}
