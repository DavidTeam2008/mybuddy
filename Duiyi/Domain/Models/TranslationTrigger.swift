import Foundation

/// Pure translation cadence policy shared by the live translation modules.
///
/// It answers one question for non-final text: send it now, debounce it, or
/// drop it? A complete clause is always worth translating; otherwise a
/// preview must clear the language's minimum content size so two-word
/// fragments never reach the translation session. The final-packet bypass
/// belongs to `TranslationPipeline`.
enum TranslationTrigger {
    enum Action: Equatable {
        /// A clause terminator makes the text a stable unit; send it now.
        case sendNow
        /// The preview is useful but may still grow; wait for the debounce.
        case debounce
        /// Too short to translate; wait for more text or the final.
        case drop
    }

    /// Minimum content units for a preview without a clause terminator.
    /// The research baseline is 4–6 English words; script-count languages use
    /// the same unit count (4 characters/syllables) pending device tuning.
    private static let minimumPreviewUnits = 4

    static func action(for text: String, language: AppLanguage) -> Action {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .drop
        }
        if endsWithClause(text) {
            return .sendNow
        }
        return isWorthTranslating(text, language: language) ? .debounce : .drop
    }

    /// `ClauseSplitter` omits the ASCII period because it scans interior
    /// characters and must not split decimals; the trigger only looks at the
    /// last character, so a trailing period is a stable preview boundary.
    private static let previewTerminators = ClauseSplitter.terminators
        .union(CharacterSet(charactersIn: "."))

    private static func endsWithClause(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return last.unicodeScalars.allSatisfy { previewTerminators.contains($0) }
    }

    private static func isWorthTranslating(_ text: String, language: AppLanguage) -> Bool {
        contentUnits(text, language: language) >= minimumPreviewUnits
    }

    private static func contentUnits(_ text: String, language: AppLanguage) -> Int {
        switch language {
        case .zhHans:
            return ScriptCounts.hanCount(text)
        case .english:
            return ScriptCounts.wordCount(text)
        case .japanese:
            return ScriptCounts.kanaCount(text) + ScriptCounts.hanCount(text)
        case .korean:
            return ScriptCounts.hangulCount(text)
        case .thai:
            return ScriptCounts.thaiCount(text)
        case .vietnamese:
            return ScriptCounts.wordCount(text)
        }
    }
}
