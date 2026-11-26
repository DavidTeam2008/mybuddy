import Foundation
import Testing
@testable import Duiyi

struct TranslationTriggerTests {
    @Test(
        "A clause terminator sends immediately",
        arguments: [
            (AppLanguage.zhHans, "你好。"),
            (AppLanguage.zhHans, "。"),
            (AppLanguage.english, "Hello!"),
            (AppLanguage.english, "wait,"),
            (AppLanguage.english, "OK."),
            (AppLanguage.japanese, "です。"),
            (AppLanguage.korean, "안녕?"),
            (AppLanguage.thai, "ไทย，"),
            (AppLanguage.vietnamese, "Chào,"),
        ]
    )
    func clauseTerminatorSends(language: AppLanguage, text: String) {
        #expect(TranslationTrigger.action(for: text, language: language) == .sendNow)
    }

    @Test(
        "A useful preview without a terminator is debounced",
        arguments: [
            (AppLanguage.zhHans, "你好世界"),
            (AppLanguage.english, "hello world my friend"),
            (AppLanguage.japanese, "ですです"),
            (AppLanguage.korean, "안녕하세요"),
            (AppLanguage.thai, "ไทยไทย"),
            (AppLanguage.vietnamese, "xin chào bạn nhé"),
        ]
    )
    func usefulPreviewIsDebounced(language: AppLanguage, text: String) {
        #expect(TranslationTrigger.action(for: text, language: language) == .debounce)
    }

    @Test(
        "A short preview is dropped instead of translated",
        arguments: [
            (AppLanguage.zhHans, "你好"),
            (AppLanguage.english, "hello"),
            (AppLanguage.english, "hello world"),
            (AppLanguage.english, "abcdefgh"),
            (AppLanguage.japanese, "です"),
            (AppLanguage.korean, "안녕"),
            (AppLanguage.thai, "ไทย"),
            (AppLanguage.vietnamese, "chào"),
            (AppLanguage.vietnamese, "xin chào"),
        ]
    )
    func shortPreviewIsDropped(language: AppLanguage, text: String) {
        #expect(TranslationTrigger.action(for: text, language: language) == .drop)
    }

    @Test("Empty text is dropped")
    func emptyTextIsDropped() {
        #expect(TranslationTrigger.action(for: "", language: .english) == .drop)
        #expect(TranslationTrigger.action(for: "  \n", language: .zhHans) == .drop)
    }
}
