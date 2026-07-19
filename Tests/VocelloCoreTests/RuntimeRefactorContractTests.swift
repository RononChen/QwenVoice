import Foundation
@testable import QwenVoiceCore
import XCTest

final class RuntimeRefactorContractTests: XCTestCase {
    func testCurrentConstrainedTierChunkDefaultsRemainExact() {
        XCTAssertEqual(
            StreamChunkPolicy.currentConstrainedTierDefault(for: .custom),
            StreamChunkPolicy(
                firstCodecFrames: 7,
                laterCodecFrames: 7,
                pendingFrameLimit: 7,
                materializationLeadSteps: 0,
                evaluationPolicy: .full
            )
        )
        for mode in [GenerationMode.design, .clone] {
            XCTAssertEqual(
                StreamChunkPolicy.currentConstrainedTierDefault(for: mode),
                StreamChunkPolicy(
                    firstCodecFrames: 7,
                    laterCodecFrames: 14,
                    pendingFrameLimit: 14,
                    materializationLeadSteps: 0,
                    evaluationPolicy: .full
                )
            )
        }
    }

    func testEvidenceProjectionIsCanonicalAndPrivacySafe() throws {
        let plan = makePlan()
        let first = try plan.evidenceIdentity.canonicalJSONData()
        let second = try plan.evidenceIdentity.canonicalJSONData()

        XCTAssertEqual(first, second)
        XCTAssertEqual(try plan.evidenceIdentity.canonicalDigest().count, 64)
        let encoded = try XCTUnwrap(String(data: first, encoding: .utf8))
        for privateValue in [
            "Private original text",
            "Private spoken text",
            "Private model text",
            "Private delivery",
            "/private/output.wav",
        ] {
            XCTAssertFalse(encoded.contains(privateValue))
        }
        XCTAssertTrue(encoded.contains("pro_custom_speed"))
        XCTAssertTrue(encoded.contains("originalTextUTF8ByteCount"))
    }

    func testRawPlansCannotEnterGenericDurableEncoders() {
        XCTAssertFalse(isEncodable(ProductGenerationPlan.self))
        XCTAssertFalse(isEncodable(CoreGenerationPlan.self))
        XCTAssertFalse(isEncodable(ProductOutputPlan.self))
        XCTAssertFalse(isEncodable(CoreConditioningPlan.self))
        XCTAssertTrue(isEncodable(GenerationEvidenceIdentity.self))
    }

    func testDependencyDigestsInvalidateOnlyTheirOwnedInputs() {
        let baseline = makePlan()
        let changedOutput = ProductGenerationPlan(
            originalText: baseline.originalText,
            spokenText: baseline.spokenText,
            core: baseline.core,
            output: ProductOutputPlan(
                destinationPath: "/private/other.wav",
                shouldStream: true,
                batchIndex: nil,
                batchTotal: nil,
                publicationPolicyVersion: 1
            ),
            quality: baseline.quality
        )

        XCTAssertEqual(
            baseline.dependencyIdentities.modelPreparation,
            changedOutput.dependencyIdentities.modelPreparation
        )
        XCTAssertEqual(
            baseline.dependencyIdentities.conditioning,
            changedOutput.dependencyIdentities.conditioning
        )
        XCTAssertEqual(
            baseline.dependencyIdentities.sampling,
            changedOutput.dependencyIdentities.sampling
        )
        XCTAssertEqual(
            baseline.dependencyIdentities.chunking,
            changedOutput.dependencyIdentities.chunking
        )
        XCTAssertEqual(
            baseline.dependencyIdentities.memory,
            changedOutput.dependencyIdentities.memory
        )
        XCTAssertNotEqual(
            baseline.dependencyIdentities.output,
            changedOutput.dependencyIdentities.output
        )
        XCTAssertNotEqual(
            baseline.dependencyIdentities.complete,
            changedOutput.dependencyIdentities.complete
        )
    }

    func testLengthFramedIdentityDoesNotAliasLegacySeparators() {
        let left = makePlan(
            conditioning: .custom(speakerID: "speaker|delivery", deliveryInstruction: "style")
        )
        let right = makePlan(
            conditioning: .custom(speakerID: "speaker", deliveryInstruction: "delivery|style")
        )

        XCTAssertNotEqual(
            left.dependencyIdentities.conditioning,
            right.dependencyIdentities.conditioning
        )
    }

    func testPlanValidationFailsClosedForModeAndBatchMismatches() throws {
        XCTAssertNoThrow(try makePlan().validated())

        let baseline = makePlan()
        let mismatchedCore = CoreGenerationPlan(
            generationID: baseline.core.generationID,
            mode: .clone,
            modelFacingText: baseline.core.modelFacingText,
            language: baseline.core.language,
            model: baseline.core.model,
            conditioning: baseline.core.conditioning,
            sampling: baseline.core.sampling,
            chunking: baseline.core.chunking,
            memory: baseline.core.memory
        )
        XCTAssertThrowsError(try mismatchedCore.validated()) { error in
            XCTAssertEqual(error as? RuntimeRefactorPlanError, .modeConditioningMismatch)
        }

        let invalidOutput = ProductOutputPlan(
            destinationPath: "/private/output.wav",
            shouldStream: true,
            batchIndex: 2,
            batchTotal: 1,
            publicationPolicyVersion: 1
        )
        XCTAssertThrowsError(try invalidOutput.validated()) { error in
            XCTAssertEqual(error as? RuntimeRefactorPlanError, .invalidBatchPosition)
        }
    }

    func testEvidenceDigestHasFixedCanonicalValue() throws {
        XCTAssertEqual(
            try makePlan().evidenceIdentity.canonicalDigest(),
            "9ed5690b711acbfdc4f1e1a4c908de8b7948a42f85c1d037e47b91766c1ab463"
        )
    }

    private func makePlan(
        conditioning: CoreConditioningPlan = .custom(
            speakerID: "aiden",
            deliveryInstruction: "Private delivery"
        )
    ) -> ProductGenerationPlan {
        let generationID = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let stage = SamplingStage(temperature: 0.9, topP: 1, topK: 50, minP: 0)
        let core = CoreGenerationPlan(
            generationID: generationID,
            mode: conditioning.mode,
            modelFacingText: "Private model text",
            language: "english",
            model: CoreModelIdentity(
                modelID: "pro_custom_speed",
                repository: "mlx-community/model",
                revision: String(repeating: "a", count: 40),
                artifactVersion: "artifact-v1",
                integrityManifestDigest: String(repeating: "b", count: 64),
                runtimeProfileSignature: "runtime-profile"
            ),
            conditioning: conditioning,
            sampling: Qwen3SamplingPolicy(
                algorithmVersion: 2,
                effectiveSeed: 42,
                talker: stage,
                subtalker: stage,
                repetitionPenalty: 1.05,
                maximumCodecTokens: 2_048
            ),
            chunking: .currentConstrainedTierDefault(for: conditioning.mode),
            memory: RuntimeMemoryPolicy(
                tier: .floor8GBMac,
                clearCacheOnStreamChunk: true,
                clearCacheAfterGeneration: true,
                tokenMemoryClearCadence: 50,
                talkerKVGeneratedWindow: nil,
                retentionPolicy: .retainUntilIdle
            )
        )
        return ProductGenerationPlan(
            originalText: "Private original text",
            spokenText: "Private spoken text",
            core: core,
            output: ProductOutputPlan(
                destinationPath: "/private/output.wav",
                shouldStream: true,
                batchIndex: nil,
                batchTotal: nil,
                publicationPolicyVersion: 1
            ),
            quality: ProductQualityPolicy(reviewPolicyID: "fast", algorithmVersion: 3)
        )
    }

    private func isEncodable<T>(_ type: T.Type) -> Bool {
        type is any Encodable.Type
    }
}
