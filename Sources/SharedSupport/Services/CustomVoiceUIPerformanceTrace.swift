import Foundation
import OSLog
import QwenVoiceCore

@MainActor
enum CustomVoiceUIPerformanceTrace {
    enum Mode: String {
        case customVoice = "CustomVoice"
        case voiceDesign = "VoiceDesign"
        case voiceCloning = "Clones"

        var artifactSlug: String {
            switch self {
            case .customVoice:
                return "custom_voice"
            case .voiceDesign:
                return "voice_design"
            case .voiceCloning:
                return "voice_cloning"
            }
        }
    }

    enum Stage: String {
        case modeSelected = "mode_selected"
        case prewarmStarted = "prewarm_started"
        case prewarmFinished = "prewarm_finished"
        case generateActionAccepted = "generate_action_accepted"
        case coordinatorStarted = "coordinator_started"
        case previewSetupStarted = "preview_setup_started"
        case previewSetupFinished = "preview_setup_finished"
        case engineRequestStarted = "engine_request_started"
        case firstLiveChunkEvent = "first_live_chunk_event"
        case firstLiveChunkDecoded = "first_live_chunk_decoded"
        case firstLiveChunkScheduled = "first_live_chunk_scheduled"
        case engineRequestFinished = "engine_request_finished"
        case finalFileReady = "final_file_ready"
        case finalHandoffStarted = "final_handoff_started"
        case finalPlayerLoaded = "final_player_loaded"
        case databaseSaveFinished = "database_save_finished"
        case historyNotificationFinished = "history_notification_finished"
        case persistenceFinished = "persistence_finished"
        case uiHeartbeat = "ui_heartbeat"
        case generationFinished = "generation_finished"
        case generationFailed = "generation_failed"
    }

    private struct Event {
        let stage: Stage
        let elapsedMS: Int
        let metadata: [String: String]
        let metrics: [String: Int]
    }

    private final class Session {
        let id: String
        let mode: Mode
        let modelID: String
        let outputDirectory: URL
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let startedAtUnixMS = Int(Date().timeIntervalSince1970 * 1_000)
        var events: [Event] = []
        var markedOnceStages: Set<Stage> = []
        var runtimeTimingsMS: [String: Int] = [:]
        var runtimeBooleanFlags: [String: Bool] = [:]
        var runtimeStringFlags: [String: String] = [:]
        var status = "running"
        var outputFileName: String?
        var durationSeconds: Double?
        var hasWritten = false
        var mainThreadHeartbeatGapsMS: [Int] = []

        init(id: String, mode: Mode, modelID: String, outputDirectory: URL) {
            self.id = id
            self.mode = mode
            self.modelID = modelID
            self.outputDirectory = outputDirectory
        }

        func elapsedMS() -> Int {
            Int((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
        }
    }

    private static let enabledKey = "QWENVOICE_UI_PERF_AUDIT"
    private static let outputDirectoryKey = "QWENVOICE_UI_PERF_AUDIT_DIR"
    private static let logger = Logger(
        subsystem: "com.qwenvoice.app",
        category: "ui-performance"
    )
    private static var currentSession: Session?
    private static var heartbeatTimer: Timer?
    private static var lastHeartbeatUptime: UInt64?
    private static let heartbeatInterval: TimeInterval = 0.25
    private static let heartbeatEventThresholdMS = 750

    static func beginCustomVoiceGeneration(
        modelID: String,
        snapshotLoadState: String,
        isEngineReady: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        beginGeneration(
            mode: .customVoice,
            modelID: modelID,
            snapshotLoadState: snapshotLoadState,
            isEngineReady: isEngineReady,
            environment: environment
        )
    }

    static func beginGeneration(
        mode: Mode,
        modelID: String,
        snapshotLoadState: String,
        isEngineReady: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard isEnabled(environment: environment) else { return }
        let outputDirectory = resolvedOutputDirectory(environment: environment)
        let session = Session(
            id: UUID().uuidString,
            mode: mode,
            modelID: modelID,
            outputDirectory: outputDirectory
        )
        currentSession = session
        startHeartbeatMonitor()
        mark(
            .generateActionAccepted,
            metadata: [
                "mode": mode.rawValue,
                "model_id": modelID,
                "snapshot_load_state": snapshotLoadState,
                "engine_ready": isEngineReady ? "true" : "false",
            ]
        )
    }

    static func mark(
        _ stage: Stage,
        metadata: [String: String] = [:],
        metrics: [String: Int] = [:]
    ) {
        guard let session = currentSession else { return }
        let sanitizedMetadata = metadata.mapValues(sanitizeMetadataValue(_:))
        session.events.append(
            Event(
                stage: stage,
                elapsedMS: session.elapsedMS(),
                metadata: sanitizedMetadata,
                metrics: metrics
            )
        )
        logger.info(
            "CustomVoiceUIPerf stage=\(stage.rawValue, privacy: .public) elapsed_ms=\(session.elapsedMS(), privacy: .public)"
        )
    }

    static func markOnce(
        _ stage: Stage,
        metadata: [String: String] = [:],
        metrics: [String: Int] = [:]
    ) {
        guard let session = currentSession else { return }
        guard session.markedOnceStages.insert(stage).inserted else { return }
        mark(stage, metadata: metadata, metrics: metrics)
    }

    static func attachBenchmarkSample(_ sample: BenchmarkSample?) {
        guard let session = currentSession, let sample else { return }
        session.runtimeTimingsMS = sample.timingsMS
        session.runtimeBooleanFlags = sample.booleanFlags
        session.runtimeStringFlags = sample.stringFlags.mapValues(sanitizeMetadataValue(_:))
        if let firstChunkMs = sample.firstChunkMs {
            session.runtimeTimingsMS["benchmark_first_chunk_ms"] = firstChunkMs
        }
    }

    static func finish(
        status: String,
        outputPath: String? = nil,
        durationSeconds: Double? = nil
    ) {
        guard let session = currentSession else { return }
        session.status = status
        session.outputFileName = outputPath.map(sanitizedOutputFileName(_:))
        session.durationSeconds = durationSeconds
        mark(status == "success" ? .generationFinished : .generationFailed)
        stopHeartbeatMonitor()
        write(session)
        currentSession = nil
    }

    static func loadStateDescription(for loadState: EngineLoadState) -> String {
        switch loadState {
        case .idle:
            return "idle"
        case .starting:
            return "starting"
        case .loaded(let modelID):
            return "loaded:\(modelID)"
        case .running(let modelID, let label, _):
            return "running:\(modelID ?? "none"):\(label ?? "none")"
        case .failed:
            return "failed"
        }
    }

    static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        switch environment[enabledKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    private static func resolvedOutputDirectory(environment: [String: String]) -> URL {
        if let rawDirectory = environment[outputDirectoryKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !rawDirectory.isEmpty {
            return URL(fileURLWithPath: rawDirectory, isDirectory: true)
        }
        return FileManager.default
            .temporaryDirectory
            .appendingPathComponent("qwenvoice-ui-perf", isDirectory: true)
    }

    private static func write(_ session: Session) {
        guard !session.hasWritten else { return }
        session.hasWritten = true
        do {
            try FileManager.default.createDirectory(
                at: session.outputDirectory,
                withIntermediateDirectories: true
            )
            let artifact = makeArtifact(for: session)
            let data = try JSONSerialization.data(
                withJSONObject: artifact,
                options: [.prettyPrinted, .sortedKeys]
            )
            let url = session.outputDirectory
                .appendingPathComponent("\(session.mode.artifactSlug)_ui_trace_\(session.id).json")
            try data.write(to: url, options: [.atomic])
        } catch {
            logger.error(
                "CustomVoiceUIPerf artifact write failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func makeArtifact(for session: Session) -> [String: Any] {
        [
            "schema_version": 1,
            "session_id": session.id,
            "mode": session.mode.rawValue,
            "model_id": session.modelID,
            "started_at_unix_ms": session.startedAtUnixMS,
            "status": session.status,
            "output_file": session.outputFileName ?? NSNull(),
            "duration_seconds": session.durationSeconds ?? NSNull(),
            "events": session.events.map { event in
                [
                    "stage": event.stage.rawValue,
                    "elapsed_ms": event.elapsedMS,
                    "metadata": event.metadata,
                    "metrics": event.metrics,
                ] as [String: Any]
            },
            "runtime_timings_ms": session.runtimeTimingsMS,
            "runtime_boolean_flags": session.runtimeBooleanFlags,
            "runtime_string_flags": session.runtimeStringFlags,
            "main_thread_heartbeat_gaps_ms": session.mainThreadHeartbeatGapsMS,
            "main_thread_heartbeat_summary": heartbeatSummary(session.mainThreadHeartbeatGapsMS),
        ]
    }

    private static func startHeartbeatMonitor() {
        stopHeartbeatMonitor()
        lastHeartbeatUptime = DispatchTime.now().uptimeNanoseconds
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { _ in
            Task { @MainActor in
                recordHeartbeatTick()
            }
        }
        if let heartbeatTimer {
            RunLoop.main.add(heartbeatTimer, forMode: .common)
        }
    }

    private static func stopHeartbeatMonitor() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        lastHeartbeatUptime = nil
    }

    private static func recordHeartbeatTick() {
        guard let session = currentSession,
              let lastHeartbeatUptime else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let gapMS = Int((now - lastHeartbeatUptime) / 1_000_000)
        self.lastHeartbeatUptime = now
        session.mainThreadHeartbeatGapsMS.append(gapMS)
        if gapMS >= heartbeatEventThresholdMS {
            mark(
                .uiHeartbeat,
                metadata: [
                    "source": "main_thread",
                ],
                metrics: [
                    "gap_ms": gapMS,
                ]
            )
        }
    }

    private static func heartbeatSummary(_ gaps: [Int]) -> [String: Any] {
        guard !gaps.isEmpty else {
            return [
                "count": 0,
                "median_ms": NSNull(),
                "p95_ms": NSNull(),
                "max_ms": NSNull(),
            ]
        }
        let sorted = gaps.sorted()
        return [
            "count": gaps.count,
            "median_ms": percentile(sorted, percentile: 0.5),
            "p95_ms": percentile(sorted, percentile: 0.95),
            "max_ms": sorted.last ?? 0,
        ]
    }

    private static func percentile(_ sortedValues: [Int], percentile: Double) -> Int {
        guard !sortedValues.isEmpty else { return 0 }
        let rawIndex = Double(sortedValues.count - 1) * percentile
        return sortedValues[Int(rawIndex.rounded())]
    }

    private static func sanitizeMetadataValue(_ value: String) -> String {
        guard value.contains("/") else { return value }
        return URL(fileURLWithPath: value).lastPathComponent
    }

    static func sanitizedOutputFileName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

#if QW_TEST_SUPPORT
    static func beginForTesting(
        mode: Mode = .customVoice,
        modelID: String,
        outputDirectory: URL
    ) {
        currentSession = Session(
            id: "test-session",
            mode: mode,
            modelID: modelID,
            outputDirectory: outputDirectory
        )
        mark(
            .generateActionAccepted,
            metadata: [
                "model_id": modelID,
                "snapshot_load_state": "idle",
                "engine_ready": "true",
            ]
        )
    }

    static func resetForTesting() {
        stopHeartbeatMonitor()
        currentSession = nil
    }
#endif
}
