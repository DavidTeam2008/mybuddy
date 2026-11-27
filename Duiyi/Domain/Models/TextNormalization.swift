import Foundation

/// Display normalization for ASR phrases and translated text. It only repairs
/// punctuation artifacts (a continuation phrase's leading marks, overlong dot
/// runs, Chinese ellipsis width) and never changes words.
enum TextNormalization {
    /// Marks a continuation phrase can start with when the phrase boundary cut
    /// the previous sentence. A single period is kept: it may be a decimal.
    private static let leadingContinuationMarks: Set<Character> = [
        ",", ";", ":", "!", "?", "…", "，", "；", "：", "！", "？", "、"
    ]

    /// A source phrase may start with punctuation belonging to the previous
    /// phrase (Apple can emit `,..` or `...` at a range boundary). Strip it
    /// only when words remain, so a punctuation-only result still reaches the
    /// revoke/empty path unchanged.
    static func sourcePhrase(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var stripped = trimmed
        while true {
            if let first = stripped.first, leadingContinuationMarks.contains(first) {
                stripped.removeFirst()
                continue
            }
            let leadingDots = stripped.prefix { $0 == "." }.count
            if leadingDots >= 2 {
                stripped.removeFirst(leadingDots)
                continue
            }
            break
        }
        let candidate = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = candidate.isEmpty ? trimmed : candidate
        return collapsingASCIIDots(base, maximum: 3)
    }

    /// Translation output follows the target language's typography. Chinese
    /// and Japanese use `……` for any ellipsis; other languages keep three
    /// ASCII dots. Digits such as `3.14` are left alone.
    static func translation(_ text: String, language: AppLanguage) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch language {
        case .zhHans, .japanese:
            return standardEllipsis(trimmed)
        default:
            return collapsingASCIIDots(trimmed, maximum: 3)
        }
    }

    private static func collapsingASCIIDots(_ text: String, maximum: Int) -> String {
        var result = ""
        var run = 0
        func flush() {
            guard run > 0 else { return }
            result += String(repeating: ".", count: min(run, maximum))
            run = 0
        }
        for character in text {
            if character == "." {
                run += 1
            } else {
                flush()
                result.append(character)
            }
        }
        flush()
        return result
    }

    private static func standardEllipsis(_ text: String) -> String {
        var result = ""
        var asciiRun = 0
        var ellipsisRun = 0
        func flush() {
            if asciiRun >= 3 || ellipsisRun > 0 {
                result += "……"
            } else if asciiRun > 0 {
                result += String(repeating: ".", count: asciiRun)
            }
            asciiRun = 0
            ellipsisRun = 0
        }
        for character in text {
            switch character {
            case ".":
                asciiRun += 1
            case "…":
                ellipsisRun += 1
            default:
                flush()
                result.append(character)
            }
        }
        flush()
        return result
    }
}
