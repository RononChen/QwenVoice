import Foundation

enum LongTextGenerationRouter {
    static let directGenerationCharacterLimit = LongFormBatchSegmenter.defaultMaxCharacters

    static func shouldRouteToLongFormBatch(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count > directGenerationCharacterLimit
    }
}
