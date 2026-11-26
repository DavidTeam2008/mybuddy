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
            (AppLanguage.english, "Hello! "),
            (AppLanguage.zhHans, " 你好。 "),
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
            (AppLanguage.zhHans, "你好世界你好世界"),
            (AppLanguage.english, "hello world my friend"),
            (AppLanguage.japanese, "ですですですです"),
            (AppLanguage.korean, "오늘 날씨가 정말 좋네요"),
            (AppLanguage.thai, "ไทยไทยไทยไทย"),
            (AppLanguage.vietnamese, "xin chào bạn nhé hôm nay rất vui"),
        ]
    )
    func usefulPreviewIsDebounced(language: AppLanguage, text: String) {
        #expect(TranslationTrigger.action(for: text, language: language) == .debounce)
    }

    @Test(
        "A preview below four estimated words is dropped instead of translated",
        arguments: [
            (AppLanguage.zhHans, "你好"),
            (AppLanguage.zhHans, "你好世界"),
            (AppLanguage.zhHans, "你好世界你好世"),
            (AppLanguage.english, "hello"),
            (AppLanguage.english, "hello world"),
            (AppLanguage.english, "hello world my"),
            (AppLanguage.english, "abcdefgh"),
            (AppLanguage.japanese, "です"),
            (AppLanguage.japanese, "ですです"),
            (AppLanguage.japanese, "ですですです"),
            (AppLanguage.korean, "안녕하세요"),
            (AppLanguage.korean, "오늘 날씨가 정말"),
            (AppLanguage.thai, "ไทยไทย"),
            (AppLanguage.thai, "ไทยไทยไทย"),
            (AppLanguage.vietnamese, "chào"),
            (AppLanguage.vietnamese, "xin chào bạn nhé"),
            (AppLanguage.vietnamese, "xin chào bạn nhé hôm nay"),
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
