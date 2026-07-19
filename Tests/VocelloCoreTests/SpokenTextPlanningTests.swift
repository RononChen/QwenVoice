import Foundation
@testable import QwenVoiceCore
import XCTest

final class SpokenTextPlanningTests: XCTestCase {
    func testNormalizationIsDeterministicAndConservative() throws {
        let original = "  Cafe\u{301}\u{00A0}\u{00A0}“hello”\r\n\r\n１２３．  "
        let first = try SpokenTextPlanner.plan(originalText: original)
        let second = try SpokenTextPlanner.plan(originalText: original)

        XCTAssertEqual(first.spokenText, "Café \"hello\"\n\n123.")
        XCTAssertEqual(first.spokenText, second.spokenText)
        XCTAssertEqual(first.originalTextDigest, second.originalTextDigest)
        XCTAssertEqual(first.spokenTextDigest, second.spokenTextDigest)
        XCTAssertGreaterThan(first.transformationCount, 0)
    }

    func testProtectedFormsRemainUnchangedAndReceiveTypedRanges() throws {
        let original = "See https://example.com/v1.2, email QA@example.com. Version v2.1 uses U.S.A. rules."
        let plan = try SpokenTextPlanner.plan(originalText: original)

        XCTAssertEqual(plan.spokenText, original)
        let kinds = Set(plan.risks.map(\.kind))
        XCTAssertTrue(kinds.contains(.protectedURL))
        XCTAssertTrue(kinds.contains(.protectedEmail))
        XCTAssertTrue(kinds.contains(.protectedVersion))
        XCTAssertTrue(kinds.contains(.protectedAcronym))

        for risk in plan.risks {
            let source = try plan.sourceSubstring(in: risk.sourceRange)
            let spoken = try risk.spokenRange.map { try plan.spokenSubstring(in: $0) }
            XCTAssertEqual(source, spoken)
        }
    }

    func testAmbiguousFormsAreReportedRatherThanRewritten() throws {
        let original = "Meet 03/04/2026 at 09:30 for $12.50 and 5kg."
        let plan = try SpokenTextPlanner.plan(originalText: original)

        XCTAssertEqual(plan.spokenText, original)
        XCTAssertEqual(
            Set(plan.risks.map(\.kind)),
            Set([
                SpokenTextRiskKind.ambiguousDate,
                .ambiguousTime,
                .ambiguousCurrency,
                .ambiguousUnit,
            ])
        )
    }

    func testCodeSwitchRangeIsDigestBoundAndMappedAcrossUnicode() throws {
        let original = "Hello 日本語 world"
        let digest = SpokenTextPlanner.originalTextDigest(for: original)
        let sourceRange = try utf8Range(of: "日本語", in: original)
        let input = SpokenTextCodeSwitchInput(
            languageIdentifier: "ja-JP",
            sourceRange: DigestBoundTextRange(textDigest: digest, range: sourceRange)
        )

        let plan = try SpokenTextPlanner.plan(originalText: original, codeSwitches: [input])
        let resolved = try XCTUnwrap(plan.codeSwitchRanges.first)
        XCTAssertEqual(try plan.sourceSubstring(in: resolved.sourceRange), "日本語")
        XCTAssertEqual(try plan.spokenSubstring(in: resolved.spokenRange), "日本語")
    }

    func testCodeSwitchRejectsWrongDigestAndNonBoundaryUTF8Offsets() throws {
        let original = "A😀B"
        let digest = SpokenTextPlanner.originalTextDigest(for: original)
        let wrongDigest = SpokenTextCodeSwitchInput(
            languageIdentifier: "en",
            sourceRange: DigestBoundTextRange(
                textDigest: String(repeating: "0", count: 64),
                range: TextUTF8Range(lowerBound: 0, upperBound: 1)
            )
        )
        XCTAssertThrowsError(
            try SpokenTextPlanner.plan(originalText: original, codeSwitches: [wrongDigest])
        ) { error in
            XCTAssertEqual(error as? SpokenTextPlanningError, .sourceDigestMismatch)
        }

        let splitEmoji = SpokenTextCodeSwitchInput(
            languageIdentifier: "und",
            sourceRange: DigestBoundTextRange(
                textDigest: digest,
                range: TextUTF8Range(lowerBound: 2, upperBound: 4)
            )
        )
        XCTAssertThrowsError(
            try SpokenTextPlanner.plan(originalText: original, codeSwitches: [splitEmoji])
        ) { error in
            XCTAssertEqual(error as? SpokenTextPlanningError, .invalidSourceRange)
        }
    }

    func testEvidenceSerializationContainsNoRawText() throws {
        let original = "Private phrase QA@example.com version v2.1"
        let plan = try SpokenTextPlanner.plan(originalText: original)
        let encoded = try plan.evidence.canonicalJSONData()
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertFalse(json.contains("Private phrase"))
        XCTAssertFalse(json.contains("QA@example.com"))
        XCTAssertFalse(json.contains("v2.1"))
        XCTAssertTrue(json.contains(plan.originalTextDigest))
        XCTAssertTrue(json.contains(plan.spokenTextDigest))
        XCTAssertEqual(try plan.evidence.canonicalDigest().count, 64)
    }

    private func utf8Range(of needle: String, in text: String) throws -> TextUTF8Range {
        let range = try XCTUnwrap(text.range(of: needle))
        return TextUTF8Range(
            lowerBound: text.utf8.distance(from: text.utf8.startIndex, to: range.lowerBound),
            upperBound: text.utf8.distance(from: text.utf8.startIndex, to: range.upperBound)
        )
    }
}
