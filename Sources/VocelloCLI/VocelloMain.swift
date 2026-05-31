import Foundation

/// `vocello` — headless Vocello TTS over the in-process MLX engine.
/// User-facing generation without the UI + the deterministic benchmark/test driver.
@main
@MainActor
enum VocelloMain {
    static func main() async {
        // Exit cleanly on Ctrl-C (130 = 128 + SIGINT) instead of dumping a stack.
        // Partial output left mid-generation is acceptable for a dev/bench tool;
        // review temp files are defer-cleaned within a run.
        signal(SIGINT) { _ in exit(130) }

        var argv = Array(CommandLine.arguments.dropFirst())
        guard let sub = argv.first else { printUsage(); exit(2) }
        argv.removeFirst()

        do {
            switch sub {
            case "generate", "gen":
                try await GenerateCommand.run(argv)
            case "batch":
                try await BatchCommand.run(argv)
            case "voices", "voice":
                try await VoicesCommand.run(argv)
            case "speakers", "speaker":
                try await SpeakersCommand.run(argv)
            case "models", "model":
                try await ModelsCommand.run(argv)
            case "bench", "benchmark":
                try await BenchCommand.run(argv)
            case "review":
                try await ReviewCommand.run(argv)
            case "help", "-h", "--help":
                printUsage()
            case "version", "--version", "-v":
                print("vocello \(vocelloCLIVersion)")
            default:
                FileHandle.standardError.write(Data("unknown command: \(sub)\n\n".utf8))
                printUsage()
                exit(2)
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func printUsage() {
        print("""
        vocello — headless Vocello TTS (Qwen3-TTS via MLX)

        Commands:
          generate   synthesize a clip            (vocello generate --help)
          batch      synthesize many clips, one model load (vocello batch --help)
          voices     manage saved clone voices    (vocello voices help)
          speakers   list built-in Custom Voice speakers (vocello speakers help)
          models     inventory installed models   (vocello models help)
          bench      drive the perf/quality matrix (vocello bench --help)
          review     adjudicate flagged clips by ear via agy (vocello review --help)
          help       show this message
          version    print version

        Global: --json (machine-readable stdout), --quiet / --verbose (stderr notes).
        """)
    }
}
