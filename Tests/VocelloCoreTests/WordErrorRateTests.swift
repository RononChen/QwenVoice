import QwenVoiceCore
import XCTest

final class WordErrorRateTests: XCTestCase {
    func testIdenticalReferenceAndHypothesis() {
        let wer = VoiceClipTranscriber.wordErrorRate(
            reference: "The train left the station.",
            hypothesis: "The train left the station."
        )
        XCTAssertEqual(wer, 0, accuracy: 0.001)
    }

    func testNormalizedPunctuationAndCase() {
        let wer = VoiceClipTranscriber.wordErrorRate(
            reference: "Le train a quitté la gare.",
            hypothesis: "le train a quitte la gare"
        )
        XCTAssertEqual(wer, 0, accuracy: 0.001)
    }

    func testSingleSubstitution() {
        let wer = VoiceClipTranscriber.wordErrorRate(
            reference: "one two three four",
            hypothesis: "one two four four"
        )
        XCTAssertEqual(wer, 0.25, accuracy: 0.001)
    }
}
