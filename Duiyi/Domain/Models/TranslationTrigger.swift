import Foundation

/// Pure translation cadence policy shared by the live translation modules.
///
/// It answers one question for non-final text only: should this caption line be
/// sent to the translation Host now, or wait for the feature's debounce? The
/// final-packet bypass belongs to `TranslationPipeline`.
enum TranslationTrigger {
    static func shouldSendNow(text: String, isFirst: Bool, language: AppLanguage) -> Bool {
        endsWithClause(text) || (isFirst && isWorthTranslating(text, language: language))
    }

    private static func endsWithClause(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return last.unicodeScalars.allSatisfy { ClauseSplitter.terminators.contains($0) }
    }

    private static func isWorthTranslating(_ text: String, language: AppLanguage) -> Bool {
        switch language {
        case .zhHans:
            return UtteranceAssembler.hanCount(text) >= 2
        case .english:
            return UtteranceAssembler.wordCount(text) >= 2 || text.count >= 8
        case .japanese:
            return UtteranceAssembler.kanaCount(text) + UtteranceAssembler.hanCount(text) >= 2
        case .korean:
            return UtteranceAssembler.hangulCount(text) >= 2
        case .thai:
            return UtteranceAssembler.thaiCount(text) >= 2
        case .vietnamese:
            return UtteranceAssembler.wordCount(text) >= 2
                || UtteranceAssembler.vietnameseMarkCount(text) >= 1
                || text.count >= 8
        }
    }
}
