import Foundation

struct TranslationJob: Equatable, Sendable, Identifiable {
    let id: UUID
    let utteranceID: UUID
    let source: AppLanguage
    let target: AppLanguage
    let text: String
    let isFinal: Bool
    /// Monotonic submission order assigned by `TranslationPipeline`. Jobs built
    /// outside the pipeline (history detail, test fixtures) use 0 and are
    /// exempt from the stale-sequence check.
    let sequence: Int

    init(
        id: UUID = UUID(),
        utteranceID: UUID,
        source: AppLanguage,
        target: AppLanguage,
        text: String,
        isFinal: Bool,
        sequence: Int = 0
    ) {
        self.id = id
        self.utteranceID = utteranceID
        self.source = source
        self.target = target
        self.text = text
        self.isFinal = isFinal
        self.sequence = sequence
    }
}
