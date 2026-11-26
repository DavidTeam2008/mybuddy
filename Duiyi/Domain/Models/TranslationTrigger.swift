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

    /// Minimum estimated words for a preview without a clause terminator.
    /// The research baseline is 4–6 English words.
    private static let minimumPreviewWords = 4

    static func action(for rawText: String, language: AppLanguage) -> Action {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .drop }
        if endsWithClause(text) {
            return .sendNow
        }
        return estimatedWordCount(text, language: language) >= minimumPreviewWords
            ? .debounce
            : .drop
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

    /// Script languages have no whitespace word boundaries, so raw counts are
    /// divided into approximate words. The divisors keep the 4-word minimum
    /// comparable to English; they are heuristics to revisit with P1-4 device
    /// data, not linguistic word segmentation.
    private static func estimatedWordCount(_ text: String, language: AppLanguage) -> Int {
        switch language {
        case .english:
            return ScriptCounts.wordCount(text)
        case .vietnamese:
            // Vietnamese writes syllables as whitespace tokens; a word is
            // usually two syllables.
            return ScriptCounts.wordCount(text) / 2
        case .zhHans:
            return ScriptCounts.hanCount(text) / 2
        case .japanese:
            return (ScriptCounts.kanaCount(text) + ScriptCounts.hanCount(text)) / 2
        case .korean:
            return ScriptCounts.hangulCount(text) / 2
        case .thai:
            return ScriptCounts.thaiCount(text) / 3
        }
    }
}
