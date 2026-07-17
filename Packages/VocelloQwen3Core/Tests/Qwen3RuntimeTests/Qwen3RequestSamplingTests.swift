import MLX
@testable import MLXAudioTTS
import XCTest

final class Qwen3RequestSamplingTests: XCTestCase {
    func testCompatibilityMemoryPolicyPreservesShippingDefaults() {
        let policy = Qwen3RequestMemoryPolicy.compatibilityDefault
        XCTAssertTrue(policy.clearCacheOnStreamChunkEmit)
        XCTAssertEqual(policy.tokenMemoryClearCadence, 50)
        XCTAssertNil(policy.talkerKVGeneratedWindow)
    }

    func testRequestMemoryPoliciesRemainIndependentValues() {
        let constrained = Qwen3RequestMemoryPolicy(
            clearCacheOnStreamChunkEmit: true,
            tokenMemoryClearCadence: 24,
            talkerKVGeneratedWindow: 256
        )
        let unconstrained = Qwen3RequestMemoryPolicy(
            clearCacheOnStreamChunkEmit: false,
            tokenMemoryClearCadence: 200,
            talkerKVGeneratedWindow: nil
        )

        XCTAssertEqual(constrained.tokenMemoryClearCadence, 24)
        XCTAssertEqual(constrained.talkerKVGeneratedWindow, 256)
        XCTAssertFalse(unconstrained.clearCacheOnStreamChunkEmit)
        XCTAssertNil(unconstrained.talkerKVGeneratedWindow)
    }

    func testVersionTwoPolicyIsExactlyReproducible() {
        let policy = makePolicy(seed: 0xC0DE_CAFE)

        XCTAssertEqual(drawSequence(using: policy), drawSequence(using: policy))
    }

    func testVersionTwoPolicyDoesNotAdvanceGlobalRandomState() {
        MLXRandom.seed(0xABCD)
        let expectedGlobal = drawGlobalSequence()

        MLXRandom.seed(0xABCD)
        _ = drawSequence(using: makePolicy(seed: 0x1234))
        let observedGlobal = drawGlobalSequence()

        XCTAssertEqual(observedGlobal, expectedGlobal)
    }

    func testInterleavedRequestAndGlobalDrawsCannotPerturbReplay() {
        let policy = makePolicy(seed: 0x55AA)
        let expected = drawSequence(using: policy)

        MLXRandom.seed(0xDEAD_BEEF)
        _ = drawGlobalSequence()
        _ = drawSequence(using: makePolicy(seed: 0xFEED_FACE))
        _ = drawGlobalSequence()

        XCTAssertEqual(drawSequence(using: policy), expected)
        XCTAssertNotEqual(drawSequence(using: makePolicy(seed: 0x55AB)), expected)
    }

    private func makePolicy(seed: UInt64) -> Qwen3RequestSamplingPolicy {
        let stage = Qwen3SamplingStage(
            temperature: 0.9,
            topP: 1,
            topK: 50,
            minP: 0
        )
        return Qwen3RequestSamplingPolicy(
            effectiveSeed: seed,
            talker: stage,
            subtalker: stage,
            repetitionPenalty: 1.05,
            maximumCodecTokens: 128
        )
    }

    private func drawSequence(using policy: Qwen3RequestSamplingPolicy) -> [Int32] {
        policy.runWithRandomState {
            (0 ..< 16).map { _ in drawCategorical() }
        }
    }

    private func drawGlobalSequence() -> [Int32] {
        (0 ..< 16).map { _ in drawCategorical() }
    }

    private func drawCategorical() -> Int32 {
        let logits = MLXArray.zeros([1, 128], type: Float.self)
        let token = MLXRandom.categorical(logits).reshaped(1, 1)
        eval(token)
        return token.item(Int32.self)
    }
}
