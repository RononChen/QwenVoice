import Foundation
import XCTest
@testable import QwenVoiceCore

/// Smoke tests for the Session 5b mock infrastructure
/// (`MockMLXModelCoordinator` + `MLXTTSEngine.makeForTesting`). These
/// validate that `MLXTTSEngine` can be driven through its internal
/// load-coordinator seam without touching MLX, so the bulk test port in
/// Session 5c can rely on the recipe.
///
/// Coverage here is intentionally minimal — the goal is to prove the
/// seam works end-to-end, not to duplicate the 19 tests in
/// `NativeMLXMacEngineTests` (those land against the same recipe in
/// Session 5c).
@MainActor
final class MLXTTSEngineMockBackedTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        temporaryRoot = try Self.makeTemporaryRoot()
    }

    override func tearDown() async throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
        try await super.tearDown()
    }

    func testEngineSurfacesMockLoadFailureAndKeepsCurrentLoadedModelIDNil() async throws {
        let registry = try ContractBackedModelRegistry(
            manifestURL: try Self.bundledManifestURL()
        )
        let coordinator = MockMLXModelCoordinator()
        let engine = MLXTTSEngine.makeForTesting(
            modelRegistry: registry,
            rootDirectory: temporaryRoot,
            loadCoordinator: coordinator
        )
        try await engine.initialize(appSupportDirectory: temporaryRoot)

        XCTAssertEqual(engine.loadState, .idle)
        let preLoadID = await engine.currentLoadedModelID()
        XCTAssertNil(preLoadID)

        var didThrow = false
        do {
            try await engine.loadModel(id: "qwen3_custom_voice")
        } catch {
            didThrow = true
        }
        XCTAssertTrue(didThrow, "Expected loadModel to throw when the mock coordinator's loadHandler is nil.")

        XCTAssertEqual(coordinator.loadCalls.count, 1)
        XCTAssertEqual(coordinator.loadCalls.first?.modelID, "qwen3_custom_voice")
        let postLoadID = await engine.currentLoadedModelID()
        XCTAssertNil(postLoadID)
        if case .failed = engine.loadState {
            // Expected
        } else {
            XCTFail("Expected loadState to be .failed after the mock coordinator threw, got \(engine.loadState)")
        }
        XCTAssertNotNil(engine.visibleErrorMessage)
    }

    func testEngineUnloadInvokesMockCoordinatorAndClearsLoadState() async throws {
        let registry = try ContractBackedModelRegistry(
            manifestURL: try Self.bundledManifestURL()
        )
        let coordinator = MockMLXModelCoordinator()
        let engine = MLXTTSEngine.makeForTesting(
            modelRegistry: registry,
            rootDirectory: temporaryRoot,
            loadCoordinator: coordinator
        )
        try await engine.initialize(appSupportDirectory: temporaryRoot)

        try await engine.unloadModel()

        XCTAssertEqual(coordinator.unloadCallCount, 1)
        XCTAssertEqual(engine.loadState, .idle)
        let loadedID = await engine.currentLoadedModelID()
        XCTAssertNil(loadedID)
    }

    // MARK: - Ported from NativeMLXMacEngineTests (Session 5c batch 1)

    /// Ported equivalent of
    /// `NativeMLXMacEngineTests.testInitializeCreatesNativeRuntimeDirectoriesAndSupportsPreparedVoices`.
    /// Asserts the directory layout that `MLXTTSEngine.initialize` actually
    /// owns (a smaller set than `MacNativeRuntime` did — `models/`,
    /// `downloads/staging/`, `outputs/` etc. are owned by other layers and
    /// created on demand, not at init).
    func testInitializeCreatesEngineOwnedDirectoriesAndSupportsPreparedVoices() async throws {
        let sourceAudio = temporaryRoot.appendingPathComponent("sample.wav")
        try Data("sample-audio".utf8).write(to: sourceAudio)

        let registry = try ContractBackedModelRegistry(
            manifestURL: try Self.bundledManifestURL()
        )
        let coordinator = MockMLXModelCoordinator()
        let engine = MLXTTSEngine.makeForTesting(
            modelRegistry: registry,
            rootDirectory: temporaryRoot,
            loadCoordinator: coordinator
        )
        try await engine.initialize(appSupportDirectory: temporaryRoot)

        let engineOwnedDirectories = [
            "voices",
            "cache/normalized_clone_refs",
            "cache/stream_sessions",
        ]

        for relativePath in engineOwnedDirectories {
            let directoryURL = temporaryRoot.appendingPathComponent(relativePath, isDirectory: true)
            var isDirectory: ObjCBool = false
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
                "Expected directory at \(relativePath)"
            )
            XCTAssertTrue(isDirectory.boolValue, "Expected \(relativePath) to be a directory")
        }

        let enrolled = try await engine.enrollPreparedVoice(
            name: "Sample Voice",
            audioPath: sourceAudio.path,
            transcript: "Hello from the mock-backed engine"
        )
        XCTAssertEqual(enrolled.id, "Sample Voice")
        XCTAssertTrue(enrolled.hasTranscript)
        XCTAssertTrue(
            enrolled.audioPath.hasPrefix(temporaryRoot.appendingPathComponent("voices").path),
            "Expected enrolled voice audio under the engine's voices directory."
        )

        let listed = try await engine.listPreparedVoices()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.id, enrolled.id)
        XCTAssertEqual(listed.first?.name, enrolled.name)
        XCTAssertEqual(listed.first?.hasTranscript, enrolled.hasTranscript)
        XCTAssertEqual(
            URL(fileURLWithPath: listed.first?.audioPath ?? "").resolvingSymlinksInPath().path,
            URL(fileURLWithPath: enrolled.audioPath).resolvingSymlinksInPath().path
        )

        try await engine.deletePreparedVoice(id: enrolled.id)
        let remainingVoices = try await engine.listPreparedVoices()
        XCTAssertTrue(remainingVoices.isEmpty)
    }

    /// Ported equivalent of
    /// `NativeMLXMacEngineTests.testNativeMLXMacEnginePublishesStartingAndLoadedStateForAvailableModel`.
    /// The mock load handler sleeps 150 ms so the test can observe the
    /// `.starting` state transition before the load completes, then
    /// asserts the `.loaded(modelID:)` final state and clean unload.
    func testEnginePublishesStartingAndLoadedStateAcrossSuccessfulMockLoad() async throws {
        let registry = try ContractBackedModelRegistry(
            manifestURL: try Self.bundledManifestURL()
        )
        let coordinator = MockMLXModelCoordinator(loadHandler: { _, capabilityProfile in
            try await Task.sleep(nanoseconds: 150_000_000)
            return await NativeModelLoadResult.makeForTesting(
                capabilityProfile: capabilityProfile
            )
        })
        let engine = MLXTTSEngine.makeForTesting(
            modelRegistry: registry,
            rootDirectory: temporaryRoot,
            loadCoordinator: coordinator
        )
        try await engine.initialize(appSupportDirectory: temporaryRoot)
        XCTAssertEqual(engine.loadState, .idle)

        let loadTask = Task { @MainActor in
            try await engine.loadModel(id: "qwen3_custom_voice")
        }
        await Task.yield()
        _ = await waitUntil(
            timeoutSeconds: 0.5,
            description: "engine load state reaches .starting"
        ) {
            engine.loadState == .starting
        }
        XCTAssertEqual(engine.loadState, .starting)
        try await loadTask.value

        XCTAssertEqual(engine.loadState, .loaded(modelID: "qwen3_custom_voice"))
        XCTAssertNil(engine.visibleErrorMessage)
        let loadedID = await engine.currentLoadedModelID()
        XCTAssertEqual(loadedID, "qwen3_custom_voice")
        XCTAssertEqual(coordinator.loadCalls.count, 1)
        XCTAssertEqual(coordinator.loadCalls.first?.modelID, "qwen3_custom_voice")

        try await engine.unloadModel()
        XCTAssertEqual(engine.loadState, .idle)
        XCTAssertNil(engine.visibleErrorMessage)
        XCTAssertEqual(coordinator.unloadCallCount, 1)
    }

    // MARK: - Helpers

    private static func makeTemporaryRoot() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLXTTSEngineMockBackedTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private static func bundledManifestURL() throws -> URL {
        let bundles = [Bundle.main, Bundle(for: BundleLocator.self)] + Bundle.allBundles + Bundle.allFrameworks
        for bundle in bundles {
            if let url = bundle.url(forResource: "qwenvoice_contract", withExtension: "json") {
                return url
            }
        }
        throw NSError(
            domain: "MLXTTSEngineMockBackedTests",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate qwenvoice_contract.json in any test bundle."]
        )
    }

    private final class BundleLocator: NSObject {}
}
