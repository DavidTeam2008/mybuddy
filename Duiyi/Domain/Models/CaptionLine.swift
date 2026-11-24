import Foundation

struct CaptionLine: Identifiable, Equatable, Sendable {
    enum Phase: String, Equatable, Sendable {
        case streaming
        case settled
    }

    var id: UUID
    var side: SpeakerSide
    var source: AppLanguage
    var sourceText: String
    var translatedText: String
    var phase: Phase
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        side: SpeakerSide,
        source: AppLanguage,
        sourceText: String,
        translatedText: String = "",
        phase: Phase = .streaming,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.side = side
        self.source = source
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.phase = phase
        self.updatedAt = updatedAt
    }

    var displayText: String {
        translatedText.isEmpty ? sourceText : translatedText
    }

    func visibleText(forViewer language: AppLanguage) -> String {
        if !translatedText.isEmpty {
            return translatedText
        }
        if source == language {
            return sourceText
        }
        return "…"
    }
}

struct PaneState: Equatable, Sendable {
    var history: [CaptionLine] = []
    var live: CaptionLine?
    var speakingHint: String?

    static let empty = PaneState()
}
