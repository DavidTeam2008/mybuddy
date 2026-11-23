import Foundation
import Testing
@testable import Duiyi

struct TranslationTriggerTests {
    @Test(
        "A first packet is sent once it clears its language threshold",
        arguments: [
            (AppLanguage.zhHans, "你好"),
            (AppLanguage.english, "hello world"),
            (AppLanguage.english, "abcdefgh"),
            (AppLanguage.japanese, "です"),
            (AppLanguage.japanese, "日本"),
            (AppLanguage.korean, "안녕"),
            (AppLanguage.thai, "ไทย"),
            (AppLanguage.vietnamese, "xin chào"),
            (AppLanguage.vietnamese, "chào"),
            (AppLanguage.vietnamese, "abcdefgh"),
        ]
    )
    func firstPacketAboveThreshold(language: AppLanguage, text: String) {
        #expect(TranslationTrigger.shouldSendNow(text: text, isFirst: true, language: language))
    }

    @Test(
        "A first packet below its language threshold is not sent",
        arguments: [
            (AppLanguage.zhHans, "你"),
            (AppLanguage.english, "hello"),
            (AppLanguage.japanese, "あ"),
            (AppLanguage.korean, "안"),
            (AppLanguage.thai, "ไ"),
            (AppLanguage.vietnamese, "chao"),
        ]
    )
    func firstPacketBelowThreshold(language: AppLanguage, text: String) {
        #expect(!TranslationTrigger.shouldSendNow(text: text, isFirst: true, language: language))
    }

    @Test(
        "Clause terminators send immediately even after the first packet",
        arguments: [
            (AppLanguage.zhHans, "你好。"),
            (AppLanguage.zhHans, "。"),
            (AppLanguage.english, "Hello!"),
            (AppLanguage.english, "wait,"),
            (AppLanguage.japanese, "です。"),
            (AppLanguage.korean, "안녕?"),
            (AppLanguage.thai, "ไทย，"),
            (AppLanguage.vietnamese, "Chào,"),
        ]
    )
    func clauseTerminatorSends(language: AppLanguage, text: String) {
        #expect(TranslationTrigger.shouldSendNow(text: text, isFirst: false, language: language))
    }

    @Test(
        "Later volatile text without a clause terminator is not sent",
        arguments: [
            (AppLanguage.zhHans, "你好"),
            (AppLanguage.english, "hello world"),
            (AppLanguage.japanese, "です"),
            (AppLanguage.korean, "안녕"),
            (AppLanguage.thai, "ไทย"),
            (AppLanguage.vietnamese, "xin chào"),
        ]
    )
    func laterVolatileWithoutTerminatorIsHeld(language: AppLanguage, text: String) {
        #expect(!TranslationTrigger.shouldSendNow(text: text, isFirst: false, language: language))
    }

    @Test("Empty text is never sent")
    func emptyTextIsNotSent() {
        #expect(!TranslationTrigger.shouldSendNow(text: "", isFirst: true, language: .english))
        #expect(!TranslationTrigger.shouldSendNow(text: "", isFirst: false, language: .zhHans))
    }
}
