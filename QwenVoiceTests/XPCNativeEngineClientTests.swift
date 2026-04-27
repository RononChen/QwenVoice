import XCTest
@testable import QwenVoiceNative

final class XPCNativeEngineClientTests: XCTestCase {
    private func invalidateAndDrain(_ clients: XPCNativeEngineClient...) async {
        for client in clients {
            await client.debugInvalidateConnectionForTesting()
        }
        try? await Task.sleep(for: .milliseconds(50))
    }

    func testClientInitializesAndPingsBundledEngineService() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let client = XPCNativeEngineClient()
        try await client.initialize(appSupportDirectory: root)

        let pingResult = try await client.ping()
        XCTAssertTrue(pingResult)
        XCTAssertTrue(client.snapshot.isReady)
        XCTAssertEqual(client.snapshot.loadState, .idle)
        XCTAssertNil(client.snapshot.visibleErrorMessage)

        await invalidateAndDrain(client)
    }

    func testClientPreparedVoiceLifecycleUsesEngineServiceAppSupportDirectory() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceAudio = root.appendingPathComponent("reference.wav")
        try NativeRuntimeTestSupport.writeTestWAV(to: sourceAudio, sampleRate: 24_000, channels: 1)

        let client = XPCNativeEngineClient()
        try await client.initialize(appSupportDirectory: root)

        let enrolled = try await client.enrollPreparedVoice(
            name: "XPC Test Voice",
            audioPath: sourceAudio.path,
            transcript: "hello from xpc"
        )
        XCTAssertEqual(enrolled.id, "XPC Test Voice")
        XCTAssertTrue(enrolled.audioPath.hasPrefix(root.appendingPathComponent("voices").path))

        let listed = try await client.listPreparedVoices()
        XCTAssertEqual(listed.map(\.id), ["XPC Test Voice"])
        XCTAssertTrue(listed.first?.hasTranscript ?? false)

        try await client.deletePreparedVoice(id: enrolled.id)
        let remainingVoices = try await client.listPreparedVoices()
        XCTAssertTrue(remainingVoices.isEmpty)

        await invalidateAndDrain(client)
    }

    func testClientReinitializesAfterConnectionInvalidation() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let client = XPCNativeEngineClient()
        try await client.initialize(appSupportDirectory: root)
        let initialPing = try await client.ping()
        XCTAssertTrue(initialPing)

        await client.debugInvalidateConnectionForTesting()

        _ = await waitUntil(
            timeoutSeconds: 0.5,
            description: "client becomes not-ready after invalidation"
        ) {
            !client.snapshot.isReady
        }
        XCTAssertFalse(client.snapshot.isReady)
        XCTAssertNotNil(client.snapshot.visibleErrorMessage)

        let reconnectPing = try await client.ping()
        XCTAssertTrue(reconnectPing)
        _ = await waitUntil(
            timeoutSeconds: 0.5,
            description: "client becomes ready after reconnect"
        ) {
            client.snapshot.isReady
        }
        XCTAssertTrue(client.snapshot.isReady)
        XCTAssertEqual(client.snapshot.loadState, .idle)
        XCTAssertNil(client.snapshot.visibleErrorMessage)

        await invalidateAndDrain(client)
    }

    func testSecondClientRemainsActiveWhenFirstConnectionInvalidates() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let firstClient = XPCNativeEngineClient()
        let secondClient = XPCNativeEngineClient()

        try await firstClient.initialize(appSupportDirectory: root)
        try await secondClient.initialize(appSupportDirectory: root)

        let firstPing = try await firstClient.ping()
        let secondInitialPing = try await secondClient.ping()
        XCTAssertTrue(firstPing)
        XCTAssertTrue(secondInitialPing)

        await firstClient.debugInvalidateConnectionForTesting()

        _ = await waitUntil(
            timeoutSeconds: 0.5,
            description: "second client clears any visible error"
        ) {
            secondClient.snapshot.visibleErrorMessage == nil
        }

        let secondPing = try await secondClient.ping()
        XCTAssertTrue(secondPing)
        XCTAssertTrue(secondClient.snapshot.isReady)
        XCTAssertNil(secondClient.snapshot.visibleErrorMessage)

        await invalidateAndDrain(firstClient, secondClient)
    }

    func testClientMapsRemoteCancelledGenerationReplyToCancellationError() async throws {
        let transport = ClientTestXPCTransport()
        let client = XPCNativeEngineClient(
            transportFactory: { handlers in
                transport.install(handlers: handlers)
                return transport
            }
        )
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        async let initialize: Void = client.initialize(appSupportDirectory: root)
        try await waitForPerformCallCount(1, transport: transport)
        transport.reply(
            with: EngineReplyEnvelope(
                id: try XCTUnwrap(transport.lastRequestID),
                reply: .void
            )
        )
        try await initialize

        let request = GenerationRequest(
            modelID: "pro_custom",
            text: "Cancel me",
            outputPath: root.appendingPathComponent("cancel.wav").path,
            shouldStream: true,
            payload: .custom(speakerID: "vivian", deliveryStyle: nil)
        )

        async let generation: GenerationResult = client.generate(request)
        try await waitForPerformCallCount(2, transport: transport)
        transport.reply(
            with: EngineReplyEnvelope(
                id: try XCTUnwrap(transport.lastRequestID),
                reply: .failure(
                    RemoteErrorPayload(
                        message: "Generation cancelled",
                        domain: "QwenVoiceNative",
                        code: .cancelled
                    )
                )
            )
        )

        do {
            _ = try await generation
            XCTFail("Expected cancelled generation to throw.")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testClientAcceptsCapabilityReplyForPing() async throws {
        let transport = ClientTestXPCTransport()
        let client = XPCNativeEngineClient(
            transportFactory: { handlers in
                transport.install(handlers: handlers)
                return transport
            }
        )
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        async let initialize: Void = client.initialize(appSupportDirectory: root)
        try await waitForPerformCallCount(1, transport: transport)
        transport.reply(
            with: EngineReplyEnvelope(
                id: try XCTUnwrap(transport.lastRequestID),
                reply: .void
            )
        )
        try await initialize

        async let ping: Bool = client.ping()
        try await waitForPerformCallCount(2, transport: transport)
        transport.reply(
            with: EngineReplyEnvelope(
                id: try XCTUnwrap(transport.lastRequestID),
                reply: .capabilities(.macOSXPCDefault)
            )
        )

        let pingResult = try await ping
        XCTAssertTrue(pingResult)
    }

    func testClientReconnectsAfterPostGenerationInterruption() async throws {
        let firstTransport = ClientTestXPCTransport()
        let secondTransport = ClientTestXPCTransport()
        let factory = ClientTestTransportFactory([firstTransport, secondTransport])
        let client = XPCNativeEngineClient(
            transportFactory: { handlers in
                factory.makeTransport(handlers: handlers)
            },
            reconnectDelays: [.milliseconds(1)]
        )
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        async let initialize: Void = client.initialize(appSupportDirectory: root)
        try await waitForPerformCallCount(1, transport: firstTransport)
        firstTransport.reply(
            with: EngineReplyEnvelope(
                id: try XCTUnwrap(firstTransport.lastRequestID),
                reply: .snapshot(
                    TTSEngineSnapshot(
                        isReady: true,
                        loadState: .idle,
                        clonePreparationState: .idle,
                        visibleErrorMessage: nil
                    )
                )
            )
        )
        try await initialize

        let request = GenerationRequest(
            modelID: "pro_custom",
            text: "hello there",
            outputPath: root.appendingPathComponent("hello.wav").path,
            shouldStream: true,
            payload: .custom(speakerID: "vivian", deliveryStyle: nil)
        )
        async let generation: GenerationResult = client.generate(request)
        try await waitForPerformCallCount(2, transport: firstTransport)
        firstTransport.reply(
            with: EngineReplyEnvelope(
                id: try XCTUnwrap(firstTransport.lastRequestID),
                reply: .generationResult(
                    GenerationResult(
                        audioPath: request.outputPath,
                        durationSeconds: 1.2,
                        streamSessionDirectory: nil,
                        benchmarkSample: BenchmarkSample(streamingUsed: true)
                    )
                )
            )
        )
        _ = try await generation

        firstTransport.interruptFromTest()
        _ = await waitUntil(
            timeoutSeconds: 0.5,
            description: "client publishes reconnecting snapshot"
        ) {
            client.snapshot.visibleErrorMessage == "Reconnecting engine…"
        }

        try await waitForPerformCallCount(1, transport: secondTransport)
        XCTAssertEqual(
            secondTransport.performedCommands.first,
            .initialize(appSupportDirectoryPath: root.path)
        )
        secondTransport.reply(
            with: EngineReplyEnvelope(
                id: try XCTUnwrap(secondTransport.lastRequestID),
                reply: .snapshot(
                    TTSEngineSnapshot(
                        isReady: true,
                        loadState: .idle,
                        clonePreparationState: .idle,
                        visibleErrorMessage: nil
                    )
                )
            )
        )

        try await waitForPerformCallCount(2, transport: secondTransport)
        secondTransport.reply(
            with: EngineReplyEnvelope(
                id: try XCTUnwrap(secondTransport.lastRequestID),
                reply: .capabilities(.macOSXPCDefault)
            )
        )
        _ = await waitUntil(
            timeoutSeconds: 0.5,
            description: "client returns to ready snapshot"
        ) {
            client.snapshot.isReady && client.snapshot.visibleErrorMessage == nil
        }

        async let reconnectPing: Bool = client.ping()
        try await waitForPerformCallCount(3, transport: secondTransport)
        secondTransport.reply(
            with: EngineReplyEnvelope(
                id: try XCTUnwrap(secondTransport.lastRequestID),
                reply: .capabilities(.macOSXPCDefault)
            )
        )
        let reconnectPingResult = try await reconnectPing
        XCTAssertTrue(reconnectPingResult)
    }

    private func waitForPerformCallCount(
        _ expectedCount: Int,
        transport: ClientTestXPCTransport,
        timeoutSeconds: TimeInterval = 1.0
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if transport.performCallCount >= expectedCount {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for transport perform count \(expectedCount)")
    }
}

private final class ClientTestXPCTransport: XPCNativeEngineTransporting, @unchecked Sendable {
    var handlers: XPCNativeEngineTransportHandlers?
    private(set) var performCallCount = 0
    private(set) var lastRequestID: UUID?
    private(set) var performedCommands: [EngineCommand] = []
    private var replyHandlers: [(@Sendable (Data) -> Void)] = []

    func install(handlers: XPCNativeEngineTransportHandlers) {
        self.handlers = handlers
    }

    func resume() {}

    func invalidate() {}

    func perform(_ payload: Data, reply: @escaping @Sendable (Data) -> Void) {
        performCallCount += 1
        if let envelope = try? EngineServiceCodec.decode(EngineRequestEnvelope.self, from: payload) {
            lastRequestID = envelope.id
            performedCommands.append(envelope.command)
        }
        replyHandlers.append(reply)
    }

    func reply(with envelope: EngineReplyEnvelope) {
        guard !replyHandlers.isEmpty else { return }
        let replyHandler = replyHandlers.removeFirst()
        let payload = try! EngineServiceCodec.encode(envelope)
        replyHandler(payload)
    }

    func interruptFromTest() {
        handlers?.onInterrupted()
    }
}

private final class ClientTestTransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [ClientTestXPCTransport]

    init(_ transports: [ClientTestXPCTransport]) {
        self.transports = transports
    }

    func makeTransport(handlers: XPCNativeEngineTransportHandlers) -> any XPCNativeEngineTransporting {
        lock.lock()
        defer { lock.unlock() }
        let transport = transports.removeFirst()
        transport.install(handlers: handlers)
        return transport
    }
}
