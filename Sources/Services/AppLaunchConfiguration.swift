import SwiftUI
import AppKit
import CoreGraphics
import QwenVoiceCore

struct AppLaunchConfiguration {
#if QW_TEST_SUPPORT
    let isUITest: Bool
    let disableAnimations: Bool
    let fastIdle: Bool
    let initialScreenID: String?
    let debugCaptureEnabled: Bool
    let uiTestWindowSize: CGSize?
    let isAudioQualityHeadlessHost: Bool

    static let current = AppLaunchConfiguration(
        arguments: ProcessInfo.processInfo.arguments,
        environment: ProcessInfo.processInfo.environment
    )
    static let audioQualityHeadlessHostEnvironmentKey = "QWENVOICE_AUDIO_QC_HEADLESS_APP_HOST"
    @MainActor private static var openedInitialSettingsWindow = false

    init(arguments: [String], environment: [String: String]) {
        let inferredUITest = arguments.contains("--uitest")
            || arguments.contains("--uitest-disable-animations")
            || arguments.contains("--uitest-fast-idle")
            || arguments.contains("--uitest-debug-capture")
            || arguments.contains(where: { $0.hasPrefix("--uitest-screen=") })

        isUITest = inferredUITest
        disableAnimations = inferredUITest && (
            arguments.contains("--uitest") || arguments.contains("--uitest-disable-animations")
        )
        fastIdle = inferredUITest && (
            arguments.contains("--uitest") || arguments.contains("--uitest-fast-idle")
        )
        debugCaptureEnabled = inferredUITest && arguments.contains("--uitest-debug-capture")
        initialScreenID = arguments.first(where: { $0.hasPrefix("--uitest-screen=") })?
            .replacingOccurrences(of: "--uitest-screen=", with: "")
        uiTestWindowSize = Self.parseWindowSize(environment["QWENVOICE_UI_TEST_WINDOW_SIZE"])
        isAudioQualityHeadlessHost = Self.isTruthy(environment[Self.audioQualityHeadlessHostEnvironmentKey])
    }

    var initialSidebarItem: SidebarItem? {
        guard let initialScreenID else { return nil }
        return SidebarItem(testScreenID: initialScreenID)
    }

    var shouldOpenSettingsOnLaunch: Bool {
        initialScreenID == "preferences"
    }

    var animationsEnabled: Bool {
        !disableAnimations
    }
#else
    let animationsEnabled: Bool

    static let current = AppLaunchConfiguration()

    init(animationsEnabled: Bool = true) {
        self.animationsEnabled = animationsEnabled
    }

    var initialSidebarItem: SidebarItem? {
        nil
    }

    var shouldOpenSettingsOnLaunch: Bool {
        false
    }
#endif

    func animation(_ animation: Animation?) -> Animation? {
        animationsEnabled ? animation : nil
    }

    static func performAnimated<Result>(_ animation: Animation?, _ updates: () -> Result) -> Result {
        withAnimation(current.animation(animation), updates)
    }

    @MainActor static func openSettingsWindowIfNeeded() {
#if QW_TEST_SUPPORT
        guard current.shouldOpenSettingsOnLaunch, !openedInitialSettingsWindow else { return }
        openedInitialSettingsWindow = true
        DispatchQueue.main.async {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
#endif
    }

#if QW_TEST_SUPPORT
    @MainActor static func configureAudioQualityHeadlessHostIfNeeded() {
        guard current.isAudioQualityHeadlessHost else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    static func shouldUseStubBackend(
        isStubBackendMode: Bool,
        isAudioQualityHeadlessHost: Bool
    ) -> Bool {
        isStubBackendMode || isAudioQualityHeadlessHost
    }

    @MainActor static func hideAudioQualityHeadlessHostWindowsIfNeeded() {
        guard current.isAudioQualityHeadlessHost else { return }
        configureAudioQualityHeadlessHostIfNeeded()
        for window in NSApplication.shared.windows {
            window.orderOut(nil)
        }
        NSApplication.shared.hide(nil)
    }

    private static func parseWindowSize(_ rawValue: String?) -> CGSize? {
        guard let rawValue else { return nil }

        let parts = rawValue
            .lowercased()
            .split(separator: "x", maxSplits: 1)
            .map(String.init)
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]),
              width > 0,
              height > 0 else {
            return nil
        }

        return CGSize(width: width, height: height)
    }

    private static func isTruthy(_ value: String?) -> Bool {
        guard let value else { return false }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }
#endif
}

enum MacGenerationBenchmarkOptions {
    static let uiPerformanceAuditEnvironmentKey = "QWENVOICE_UI_PERF_AUDIT"
    static let postRequestCachePolicyEnvironmentKey = "QWENVOICE_QWEN3_POST_REQUEST_CACHE_POLICY"

    private static let supportedPostRequestCachePolicies: Set<String> = [
        "current",
        "always",
        "failure-only",
        "never",
    ]

    static func requestOptions(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> GenerationRequest.BenchmarkOptions? {
        guard isTruthy(environment[uiPerformanceAuditEnvironmentKey]) else { return nil }

        let postRequestCachePolicy = environment[postRequestCachePolicyEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let postRequestCachePolicy,
              supportedPostRequestCachePolicies.contains(postRequestCachePolicy) else {
            return nil
        }

        return GenerationRequest.BenchmarkOptions(
            postRequestCachePolicy: postRequestCachePolicy
        )
    }

    private static func isTruthy(_ value: String?) -> Bool {
        guard let value else { return false }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }
}
