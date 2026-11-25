import Foundation

struct Utterance: Equatable, Sendable, Identifiable {
    let id: UUID
    let language: AppLanguage
    let text: String
    let isFinal: Bool
    let createdAt: Date
    /// A final revision of an utterance that was already closed (for example
    /// a prefix finalized by the silence timer). It updates that utterance in
    /// place and must not be treated as the engine's current final.
    let isRevision: Bool

    init(
        id: UUID = UUID(),
        language: AppLanguage,
        text: String,
        isFinal: Bool,
        createdAt: Date = .now,
        isRevision: Bool = false
    ) {
        self.id = id
        self.language = language
        self.text = text
        self.isFinal = isFinal
        self.createdAt = createdAt
        self.isRevision = isRevision
    }
}
