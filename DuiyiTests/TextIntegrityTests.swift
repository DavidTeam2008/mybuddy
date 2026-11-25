import Foundation
import Testing
@testable import Duiyi

struct TextIntegrityTests {
    @Test("Normal Chinese and English are not corrupted")
    func normalTextIsClean() {
        #expect(!TextIntegrity.isCorrupted("我感到震惊、骄傲、解放和困惑。"))
        #expect(!TextIntegrity.isCorrupted("Hello, world.\nSecond line\tTabbed"))
        #expect(!TextIntegrity.isCorrupted(""))
    }

    @Test("Replacement characters are corrupted")
    func replacementCharacterIsCorrupted() {
        #expect(TextIntegrity.isCorrupted("我感到驚\u{FFFD}\u{FFFD}然、骄傲"))
        #expect(TextIntegrity.containsReplacementCharacter("a\u{FFFD}b"))
        #expect(!TextIntegrity.containsReplacementCharacter("no replacement"))
    }

    @Test("Control characters are corrupted except whitespace")
    func controlCharactersAreCorrupted() {
        #expect(TextIntegrity.isCorrupted("hello\u{0007}world"))
        #expect(!TextIntegrity.isCorrupted("hello\nworld\t!"))
    }

    @Test("Replacement character count is reported for diagnostics")
    func replacementCharacterCount() {
        #expect(TextIntegrity.replacementCharacterCount("你\u{FFFD}好\u{FFFD}") == 2)
        #expect(TextIntegrity.replacementCharacterCount("你好") == 0)
    }

    @Test("Stored translations drop corrupted text")
    func storedTranslationSanitizes() {
        #expect(TextIntegrity.storedTranslation("你好") == "你好")
        #expect(TextIntegrity.storedTranslation("你\u{FFFD}好") == "")
    }
}
