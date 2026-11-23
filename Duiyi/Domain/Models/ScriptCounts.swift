import Foundation

/// Pure script classification and counting used by language-style policies.
///
/// Domain policy (for example `TranslationTrigger`) and the speech assembler
/// both need these counts, so they live in Domain and depend on nothing but
/// Foundation.
enum ScriptCounts {
    static func hanCount(_ text: String) -> Int {
        text.unicodeScalars.filter(isHanScalar).count
    }

    static func kanaCount(_ text: String) -> Int {
        text.unicodeScalars.filter(isKanaScalar).count
    }

    static func hangulCount(_ text: String) -> Int {
        text.unicodeScalars.filter(isHangulScalar).count
    }

    static func thaiCount(_ text: String) -> Int {
        text.unicodeScalars.filter(isThaiScalar).count
    }

    static func vietnameseMarkCount(_ text: String) -> Int {
        text.unicodeScalars.filter(isVietnameseMarkScalar).count
    }

    static func letterCount(_ text: String) -> Int {
        text.unicodeScalars.filter(isLatinScalar).count
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    static func isHanScalar(_ scalar: UnicodeScalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
    }

    static func isKanaScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D:
            return true
        default:
            return false
        }
    }

    static func isHangulScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F:
            return true
        default:
            return false
        }
    }

    static func isThaiScalar(_ scalar: UnicodeScalar) -> Bool {
        (0x0E00...0x0E7F).contains(scalar.value)
    }

    static func isVietnameseMarkScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x00C0...0x00C3, 0x00C8...0x00CA, 0x00CC, 0x00CD, 0x00D2...0x00D5, 0x00D9, 0x00DA, 0x00DD,
             0x00E0...0x00E3, 0x00E8...0x00EA, 0x00EC, 0x00ED, 0x00F2...0x00F5, 0x00F9, 0x00FA, 0x00FD,
             0x0102, 0x0103, 0x0110, 0x0111, 0x0128, 0x0129, 0x0168, 0x0169,
             0x01A0, 0x01A1, 0x01AF, 0x01B0,
             0x1EA0...0x1EF9:
            return true
        default:
            return false
        }
    }

    static func isLatinScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x0041...0x005A, 0x0061...0x007A,
             0x00C0...0x00D6, 0x00D8...0x00F6, 0x00F8...0x00FF,
             0x0100...0x024F,
             0x1E00...0x1EFF:
            return true
        default:
            return false
        }
    }
}
