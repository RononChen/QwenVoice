import Foundation
import XCTest

@testable import QwenVoice
@testable import QwenVoiceCore

@MainActor
final class CustomVoiceUIPerformanceTraceTests: XCTestCase {
    private var outputDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwenvoice-ui-perf-trace-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        CustomVoiceUIPerformanceTrace.resetForTesting()
    }

    override func tearDown() async throws {
        CustomVoiceUIPerformanceTrace.resetForTesting()
        if let outputDirectory {
            try? FileManager.default.removeItem(at: outputDirectory)
        }
        try await super.tearDown()
    }

    func testTraceActivationIsExplicit() {
        XCTAssertFalse(CustomVoiceUIPerformanceTrace.isEnabled(environment: [:]))
        XCTAssertFalse(CustomVoiceUIPerformanceTrace.isEnabled(environment: ["QWENVOICE_UI_PERF_AUDIT": "0"]))
        XCTAssertTrue(CustomVoiceUIPerformanceTrace.isEnabled(environment: ["QWENVOICE_UI_PERF_AUDIT": "1"]))
        XCTAssertTrue(CustomVoiceUIPerformanceTrace.isEnabled(environment: ["QWENVOICE_UI_PERF_AUDIT": "true"]))
        XCTAssertTrue(CustomVoiceUIPerformanceTrace.isEnabled(environment: ["QWENVOICE_UI_PERF_AUDIT": "ON"]))
    }

    func testTraceArtifactPreservesEventOrderAndRuntimeTimings() throws {
        CustomVoiceUIPerformanceTrace.beginForTesting(
            modelID: "pro_custom",
            outputDirectory: outputDirectory
        )
        CustomVoiceUIPerformanceTrace.mark(.coordinatorStarted)
        CustomVoiceUIPerformanceTrace.mark(.engineRequestStarted)
        CustomVoiceUIPerformanceTrace.markOnce(
            .firstLiveChunkEvent,
            metadata: [
                "chunk_path": "/Users/example/Library/Application Support/QwenVoice/session/chunk_0001.wav",
            ],
            metrics: [
                "request_id": 7,
            ]
        )
        CustomVoiceUIPerformanceTrace.attachBenchmarkSample(
            BenchmarkSample(
                streamingUsed: true,
                firstChunkMs: 543,
                timingsMS: [
                    "generation": 8_900,
                    "custom_prefix_prepare": 120,
                ],
                booleanFlags: [
                    "custom_prefix_cache_hit": true,
                ],
                stringFlags: [
                    "stream_session_directory": "/Users/example/session",
                ]
            )
        )
        CustomVoiceUIPerformanceTrace.finish(
            status: "success",
            outputPath: "/Users/example/Library/Application Support/QwenVoice/outputs/CustomVoice/final.wav",
            durationSeconds: 4.16
        )

        let artifactURL = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(
                at: outputDirectory,
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasPrefix("custom_voice_ui_trace_") }
        )
        let data = try Data(contentsOf: artifactURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["mode"] as? String, "CustomVoice")
        XCTAssertEqual(object["model_id"] as? String, "pro_custom")
        XCTAssertEqual(object["status"] as? String, "success")
        XCTAssertEqual(object["output_file"] as? String, "final.wav")
        XCTAssertEqual(object["duration_seconds"] as? Double, 4.16)

        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        let stages = events.compactMap { $0["stage"] as? String }
        XCTAssertEqual(
            stages,
            [
                "generate_action_accepted",
                "coordinator_started",
                "engine_request_started",
                "first_live_chunk_event",
                "generation_finished",
            ]
        )

        let firstChunkEvent = try XCTUnwrap(events.first { $0["stage"] as? String == "first_live_chunk_event" })
        let metadata = try XCTUnwrap(firstChunkEvent["metadata"] as? [String: String])
        XCTAssertEqual(metadata["chunk_path"], "chunk_0001.wav")

        let timings = try XCTUnwrap(object["runtime_timings_ms"] as? [String: Int])
        XCTAssertEqual(timings["generation"], 8_900)
        XCTAssertEqual(timings["custom_prefix_prepare"], 120)
        XCTAssertEqual(timings["benchmark_first_chunk_ms"], 543)

        let booleanFlags = try XCTUnwrap(object["runtime_boolean_flags"] as? [String: Bool])
        XCTAssertEqual(booleanFlags["custom_prefix_cache_hit"], true)

        let stringFlags = try XCTUnwrap(object["runtime_string_flags"] as? [String: String])
        XCTAssertEqual(stringFlags["stream_session_directory"], "session")

        let heartbeatSummary = try XCTUnwrap(object["main_thread_heartbeat_summary"] as? [String: Any])
        XCTAssertEqual(heartbeatSummary["count"] as? Int, 0)
    }

    func testTraceArtifactDoesNotPersistPromptTextOrAbsolutePaths() throws {
        CustomVoiceUIPerformanceTrace.beginForTesting(
            modelID: "pro_custom",
            outputDirectory: outputDirectory
        )
        CustomVoiceUIPerformanceTrace.mark(
            .finalFileReady,
            metadata: [
                "path": "/Users/example/Library/Application Support/QwenVoice/outputs/CustomVoice/final.wav",
            ]
        )
        CustomVoiceUIPerformanceTrace.finish(
            status: "success",
            outputPath: "/Users/example/Library/Application Support/QwenVoice/outputs/CustomVoice/final.wav",
            durationSeconds: 1.0
        )

        let artifactURL = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(
                at: outputDirectory,
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasPrefix("custom_voice_ui_trace_") }
        )
        let artifact = String(data: try Data(contentsOf: artifactURL), encoding: .utf8) ?? ""
        XCTAssertFalse(artifact.contains("/Users/example"))
        XCTAssertFalse(artifact.contains("Application Support"))
        XCTAssertFalse(artifact.contains("What should I say?"))
    }

    func testTraceArtifactSupportsAllGenerationModes() throws {
        CustomVoiceUIPerformanceTrace.beginForTesting(
            mode: .voiceDesign,
            modelID: "pro_design",
            outputDirectory: outputDirectory
        )
        CustomVoiceUIPerformanceTrace.finish(
            status: "success",
            outputPath: "/Users/example/outputs/VoiceDesign/final.wav",
            durationSeconds: 2.5
        )

        let artifactURL = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(
                at: outputDirectory,
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasPrefix("voice_design_ui_trace_") }
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: artifactURL)) as? [String: Any])

        XCTAssertEqual(object["mode"] as? String, "VoiceDesign")
        XCTAssertEqual(object["model_id"] as? String, "pro_design")
        XCTAssertEqual(object["output_file"] as? String, "final.wav")
    }

    func testLoadStateDescriptionIsStableForTraceMetadata() {
        XCTAssertEqual(CustomVoiceUIPerformanceTrace.loadStateDescription(for: .idle), "idle")
        XCTAssertEqual(CustomVoiceUIPerformanceTrace.loadStateDescription(for: .starting), "starting")
        XCTAssertEqual(CustomVoiceUIPerformanceTrace.loadStateDescription(for: .loaded(modelID: "pro_custom")), "loaded:pro_custom")
    }
}
