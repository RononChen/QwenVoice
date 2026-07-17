import XCTest
@testable import QwenVoiceCore

final class RequestLocalSamplingPolicyTests: XCTestCase {
    func testRequestedSeedAndVariationResolveIntoOneImmutablePolicy() throws {
        let policy = Qwen3TalkerSamplingOverride.samplingConfiguration(
            requestedSeed: 19_790_615,
            variation: .balanced
        )

        XCTAssertEqual(policy.algorithmVersion, 2)
        XCTAssertEqual(policy.effectiveSeed, 19_790_615)
        XCTAssertEqual(policy.seed, 19_790_615)
        XCTAssertEqual(policy.talker.temperature, 0.8, accuracy: 0.0001)
        XCTAssertEqual(policy.talker.topP, 0.95, accuracy: 0.0001)
        XCTAssertEqual(policy.talker.topK, 50)
        XCTAssertEqual(policy.subtalker, policy.talker)
        XCTAssertNoThrow(try policy.validated())
    }

    func testUnseededRequestStillReceivesReplayableEffectiveSeed() {
        let first = Qwen3TalkerSamplingOverride.samplingConfiguration(
            requestedSeed: nil,
            variation: .expressive
        )
        let second = Qwen3TalkerSamplingOverride.samplingConfiguration(
            requestedSeed: nil,
            variation: .expressive
        )

        XCTAssertNil(first.seed)
        XCTAssertNil(second.seed)
        XCTAssertNotEqual(first.effectiveSeed, second.effectiveSeed)
    }
}
