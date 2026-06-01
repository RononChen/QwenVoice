import ExtensionFoundation
import Foundation

/// iOS TTS engine, hosted out-of-process via **ExtensionKit** — the iOS
/// counterpart to the macOS `QwenVoiceEngineService` XPC service. Heavy MLX
/// generation runs here so the app process stays light. Connections are handed
/// to `VocelloEngineExtensionHost`, which adapts the XPC wire protocol.
///
/// Compile-safe only on `main`: on-device execution is deferred pending on-device
/// build/validation tooling — the increased-memory entitlement itself is self-serve
/// (enable on the App ID; see CLAUDE.md "Release & iPhone status").
@main
final class VocelloEngineExtension: AppExtension {
    private let host = VocelloEngineExtensionHost()

    required init() {}

    var configuration: ConnectionHandler {
        ConnectionHandler(onConnection: host.accept(connection:))
    }

    @AppExtensionPoint.Bind
    var boundExtensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier(host: "com.patricedery.vocello", name: "vocello-engine-service")
    }
}
