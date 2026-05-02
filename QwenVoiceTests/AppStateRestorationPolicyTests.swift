import XCTest
@testable import QwenVoice

final class AppStateRestorationPolicyTests: XCTestCase {
    func testDisablesStateRestorationDuringUITestLaunches() {
        XCTAssertFalse(
            AppStateRestorationPolicy.allowsStateRestoration(
                isUITestLaunch: true,
                isAudioQualityHeadlessHost: false
            )
        )
    }

    func testAllowsStateRestorationOutsideUITestLaunches() {
        XCTAssertTrue(
            AppStateRestorationPolicy.allowsStateRestoration(
                isUITestLaunch: false,
                isAudioQualityHeadlessHost: false
            )
        )
    }

    func testDisablesStateRestorationDuringAudioQualityHeadlessHostLaunches() {
        XCTAssertFalse(
            AppStateRestorationPolicy.allowsStateRestoration(
                isUITestLaunch: false,
                isAudioQualityHeadlessHost: true
            )
        )
    }
}

final class AppLaunchConfigurationTests: XCTestCase {
    func testParsesAudioQualityHeadlessHostFlag() {
        let enabled = AppLaunchConfiguration(
            arguments: [],
            environment: [
                AppLaunchConfiguration.audioQualityHeadlessHostEnvironmentKey: "1",
            ]
        )
        XCTAssertTrue(enabled.isAudioQualityHeadlessHost)

        let disabled = AppLaunchConfiguration(arguments: [], environment: [:])
        XCTAssertFalse(disabled.isAudioQualityHeadlessHost)
    }

    func testShouldUseStubBackendWhenEitherFlagIsSet() {
        XCTAssertFalse(
            AppLaunchConfiguration.shouldUseStubBackend(
                isStubBackendMode: false,
                isAudioQualityHeadlessHost: false
            )
        )
        XCTAssertTrue(
            AppLaunchConfiguration.shouldUseStubBackend(
                isStubBackendMode: true,
                isAudioQualityHeadlessHost: false
            )
        )
        XCTAssertTrue(
            AppLaunchConfiguration.shouldUseStubBackend(
                isStubBackendMode: false,
                isAudioQualityHeadlessHost: true
            )
        )
        XCTAssertTrue(
            AppLaunchConfiguration.shouldUseStubBackend(
                isStubBackendMode: true,
                isAudioQualityHeadlessHost: true
            )
        )
    }
}
