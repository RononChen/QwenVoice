@testable import QwenVoiceCore
import XCTest

final class GenerationQualityReportTests: XCTestCase {
    func testFastReviewRequiresPersistedOutputAndContinuity() throws {
        let policy = QualityReviewPolicy(
            depth: .fast,
            requiresLanguageASR: false
        )
        let report = GenerationQualityReport(
            generationID: UUID(),
            policy: policy,
            results: passingResults(for: policy)
        )

        let verdict = try QualityGateRegistry.evaluate(report)

        XCTAssertEqual(verdict.outcome, .pass)
        XCTAssertEqual(
            Set(verdict.requiredGates),
            [.terminal, .tokenCap, .codecBehavior, .persistedWAV, .streamingContinuity]
        )
    }

    func testOnePassASRCannotProducePromotionPass() throws {
        let policy = QualityReviewPolicy(
            depth: .standard,
            requiresLanguageASR: true
        )
        var results = passingResults(for: policy)
        let index = try XCTUnwrap(results.firstIndex(where: { $0.gate == .languageASR }))
        results[index] = GenerationQualityGateResult(
            gate: .languageASR,
            outcome: .pass,
            algorithmVersion: 1,
            measurements: [
                GenerationQualityMeasurement(key: .consensusPassCount, value: 1),
            ]
        )

        XCTAssertThrowsError(try QualityGateRegistry.evaluate(
            GenerationQualityReport(
                generationID: UUID(),
                policy: policy,
                results: results
            )
        )) { error in
            XCTAssertEqual(
                error as? QualityGateRegistryIssue,
                .insufficientASRConsensus
            )
        }
    }

    func testUnavailableRequiredSpeakerGateBlocksCanonicalPromotion() throws {
        let policy = QualityReviewPolicy(
            depth: .canonical,
            requiresLanguageASR: true,
            isLongForm: true,
            requiresSpeakerOnset: true
        )
        var results = passingResults(for: policy)
        let index = try XCTUnwrap(results.firstIndex(where: { $0.gate == .speakerOnset }))
        results[index] = GenerationQualityGateResult(
            gate: .speakerOnset,
            outcome: .unavailable,
            algorithmVersion: 1
        )

        let verdict = try QualityGateRegistry.evaluate(GenerationQualityReport(
            generationID: UUID(),
            policy: policy,
            results: results
        ))

        XCTAssertEqual(verdict.outcome, .fail)
        XCTAssertEqual(verdict.issues, ["quality_gate_unavailable.speaker_onset"])
    }

    func testRequiredGateCannotClaimNotApplicableAndStillPass() throws {
        let policy = QualityReviewPolicy(
            depth: .fast,
            requiresLanguageASR: false
        )
        var results = passingResults(for: policy)
        let index = try XCTUnwrap(results.firstIndex(where: { $0.gate == .persistedWAV }))
        results[index] = GenerationQualityGateResult(
            gate: .persistedWAV,
            outcome: .notApplicable,
            algorithmVersion: 1
        )

        let verdict = try QualityGateRegistry.evaluate(GenerationQualityReport(
            generationID: UUID(),
            policy: policy,
            results: results
        ))

        XCTAssertEqual(verdict.outcome, .fail)
        XCTAssertEqual(verdict.issues, ["quality_gate_not_applicable.persisted_wav"])
    }

    func testEvidenceDigestAndMeasurementKeysAreFailClosed() throws {
        let policy = QualityReviewPolicy(
            depth: .fast,
            requiresLanguageASR: false
        )
        var invalidDigest = passingResults(for: policy)
        invalidDigest[0] = GenerationQualityGateResult(
            gate: invalidDigest[0].gate,
            outcome: .pass,
            algorithmVersion: 1,
            evidenceDigest: "NOT-A-DIGEST"
        )
        XCTAssertThrowsError(try QualityGateRegistry.evaluate(
            GenerationQualityReport(
                generationID: UUID(),
                policy: policy,
                results: invalidDigest
            )
        )) { error in
            XCTAssertEqual(
                error as? QualityGateRegistryIssue,
                .invalidEvidenceDigest(invalidDigest[0].gate)
            )
        }

        var duplicateMeasurement = passingResults(for: policy)
        duplicateMeasurement[0] = GenerationQualityGateResult(
            gate: duplicateMeasurement[0].gate,
            outcome: .pass,
            algorithmVersion: 1,
            evidenceDigest: String(repeating: "a", count: 64),
            measurements: [
                GenerationQualityMeasurement(key: .durationSeconds, value: 1),
                GenerationQualityMeasurement(key: .durationSeconds, value: 2),
            ]
        )
        XCTAssertThrowsError(try QualityGateRegistry.evaluate(
            GenerationQualityReport(
                generationID: UUID(),
                policy: policy,
                results: duplicateMeasurement
            )
        )) { error in
            XCTAssertEqual(
                error as? QualityGateRegistryIssue,
                .duplicateMeasurement(
                    duplicateMeasurement[0].gate,
                    .durationSeconds
                )
            )
        }
    }

    func testCriticalRiskAddsCriticalTokenGate() {
        let policy = QualityReviewPolicy(
            depth: .standard,
            requiresLanguageASR: false,
            transformationRisks: [.protectedURL, .criticalToken]
        )

        XCTAssertTrue(QualityGateRegistry.requiredGates(for: policy).contains(.criticalTokens))
    }

    func testConstrainedScheduleReleasesTTSBeforeHeavyReview() {
        let schedule = QualityResourceSchedule(
            policy: QualityReviewPolicy(
                depth: .canonical,
                requiresLanguageASR: true
            ),
            constrainedMemory: true
        )

        XCTAssertEqual(schedule.stages, [
            .synthesis,
            .fastAnalysis,
            .releaseTTSResources,
            .speechRecognition,
            .advancedAnalysis,
        ])
        XCTAssertFalse(schedule.permitsConcurrentHeavyReviewerAndSynthesis)
    }

    func testCandidateRetriesRequireDistinctSequentialLeasesAndSeeds() {
        let attempts = (0 ... 2).map { index in
            QualityCandidateAttemptIdentity(
                attemptIndex: index,
                operationLeaseID: UUID(),
                derivedSeed: UInt64(100 + index),
                evidenceDigest: String(repeating: String(index), count: 64)
            )
        }
        XCTAssertTrue(QualityCandidateRetryPolicy.validate(attempts))
        XCTAssertFalse(QualityCandidateRetryPolicy.validate(attempts + [attempts[0]]))
    }

    private func passingResults(
        for policy: QualityReviewPolicy
    ) -> [GenerationQualityGateResult] {
        QualityGateRegistry.requiredGates(for: policy).map { gate in
            GenerationQualityGateResult(
                gate: gate,
                outcome: .pass,
                algorithmVersion: 1,
                evidenceDigest: String(repeating: "a", count: 64),
                measurements: gate == .languageASR
                    ? [GenerationQualityMeasurement(key: .consensusPassCount, value: 3)]
                    : []
            )
        }
    }
}
