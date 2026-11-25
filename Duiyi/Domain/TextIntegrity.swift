import Foundation

/// Integrity checks for translation text before it is displayed, persisted,
/// or exported. Observed on iPhone 13: a Chinese translation contained two
/// U+FFFD replacement characters from a framework streaming boundary.
enum TextIntegrity {
    static func containsReplacementCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value == 0xFFFD }
    }

    /// Control or surrogate scalars are never legitimate translation output.
    /// Tab, newline, and carriage return are allowed as whitespace.
    static func containsSuspiciousControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .surrogate:
                return scalar.value != 9 && scalar.value != 10 && scalar.value != 13
            default:
                return false
            }
        }
    }

    static func replacementCharacterCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { count, scalar in
            count + (scalar.value == 0xFFFD ? 1 : 0)
        }
    }

    static func isCorrupted(_ text: String) -> Bool {
        containsReplacementCharacter(text) || containsSuspiciousControlCharacters(text)
    }

    /// A stored translation that fails the integrity check is treated as
    /// absent, so history/detail/export show the source only.
    static func storedTranslation(_ text: String) -> String {
        isCorrupted(text) ? "" : text
    }
}
