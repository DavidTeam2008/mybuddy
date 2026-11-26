import Foundation
import Testing
@testable import Duiyi

private final class TestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_700_000_000)
}

struct UtteranceAssemblerTests {
    @Test("Chinese script wins over latin noise")
    func chineseWins() {
        var assembler = UtteranceAssembler()
        _ = assembler.ingest(language: .english, text: "uh", isFinal: false)
        let result = assembler.ingest(language: .zhHans, text: "我想点一杯咖啡", isFinal: false)
        #expect(result?.language == .zhHans)
        #expect(result?.text == "我想点一杯咖啡")
        #expect(result?.isFinal == false)
    }

    @Test("English words win when there is no Chinese")
    func englishWins() {
        var assembler = UtteranceAssembler()
        let result = assembler.ingest(language: .english, text: "I'd like a cup of coffee", isFinal: false)
        #expect(result?.language == .english)
    }

    @Test("Short filler keeps the previous language")
    func shortFillerKeepsLastLanguage() {
        var assembler = UtteranceAssembler()
        _ = assembler.ingest(language: .zhHans, text: "我们三点见吧啊", isFinal: true)
        assembler.acknowledgeFinal(language: .zhHans)
        let result = assembler.ingest(language: .english, text: "um", isFinal: false)
        #expect(result == nil || result?.language == .zhHans)
    }

    @Test("Final result from one locale is preferred")
    func finalPreferred() {
        var assembler = UtteranceAssembler()
        _ = assembler.ingest(language: .english, text: "hello there", isFinal: false)
        let result = assembler.ingest(language: .zhHans, text: "你好啊朋友们", isFinal: true)
        #expect(result?.isFinal == true)
        #expect(result?.language == .zhHans)
    }

    @Test("Volatile updates keep a stable utterance id")
    func stableIdentity() {
        var assembler = UtteranceAssembler()
        let first = assembler.ingest(language: .english, text: "Hello", isFinal: false)
        let second = assembler.ingest(language: .english, text: "Hello there", isFinal: false)
        #expect(first?.id == second?.id)
    }

    @Test("Silence timeout finalizes and starts a new id")
    func silenceStartsNewUtterance() {
        var assembler = UtteranceAssembler()
        let live = assembler.ingest(language: .zhHans, text: "明天见吧", isFinal: false)
        let finalized = assembler.silenceTimedOut()
        #expect(finalized?.isFinal == true)
        #expect(finalized?.id == live?.id)
        let next = assembler.ingest(language: .zhHans, text: "好的啊啊", isFinal: false)
        #expect(next?.id != live?.id)
    }

    @Test("English speech ignores a Chinese hallucination from the other transcriber")
    func englishSpeechIgnoresChineseHallucination() {
        var assembler = UtteranceAssembler()
        let first = assembler.ingest(language: .english, text: "you are right", isFinal: false)
        let leaked = assembler.ingest(language: .zhHans, text: "你是对的", isFinal: true)
        #expect(first?.language == .english)
        #expect(first?.text == "you are right")
        #expect(leaked == nil || leaked?.language == .english)
        if let leaked {
            #expect(leaked.text == "you are right")
        }
    }

    @Test("Chinese speech ignores English fragments from the other transcriber")
    func chineseSpeechIgnoresEnglishHallucination() {
        var assembler = UtteranceAssembler()
        let first = assembler.ingest(
            language: .zhHans,
            text: "然后我给你介绍一下北京有哪些好玩的",
            isFinal: false
        )
        let leaked = assembler.ingest(language: .english, text: "Yes and", isFinal: true)
        #expect(first?.language == .zhHans)
        #expect(leaked == nil || leaked?.language == .zhHans)
    }

    @Test("Delayed other-language final after a commit is dropped")
    func delayedOtherLanguageAfterFinalIsDropped() {
        var assembler = UtteranceAssembler()
        _ = assembler.ingest(language: .english, text: "you are right", isFinal: true)
        assembler.acknowledgeFinal(language: .english)
        let leaked = assembler.ingest(language: .zhHans, text: "你是对的", isFinal: true)
        #expect(leaked == nil)
    }

    @Test("A later longer hypothesis after a premature final keeps the same utterance id")
    func continuationAfterFinalKeepsIdentity() {
        var assembler = UtteranceAssembler()
        let first = assembler.ingest(
            language: .english,
            text: "The more inference added to the database",
            isFinal: true
        )
        assembler.acknowledgeFinal(language: .english)
        let second = assembler.ingest(
            language: .english,
            text: "The more inference added to the database of media from plot TV to games the better the prediction model",
            isFinal: false
        )
        #expect(first?.id == second?.id)
        #expect(second?.isFinal == false)
    }

    @Test("A rewritten movie title after a premature final keeps the same utterance id")
    func refinementAfterFinalKeepsIdentity() {
        var assembler = UtteranceAssembler()
        let first = assembler.ingest(
            language: .english,
            text: "Well we missed a movie called Lucky",
            isFinal: true
        )
        assembler.acknowledgeFinal(language: .english)
        let second = assembler.ingest(
            language: .english,
            text: "Well we missed a movie called Lucky Days I want to see but another movie called The Ship is out this week",
            isFinal: false
        )
        #expect(first?.id == second?.id)
        #expect(second?.text.contains("Lucky Days") == true)
    }

    @Test("A greeting name swap after a final gets a new utterance id")
    func greetingNameSwapAfterFinalGetsNewIdentity() {
        var assembler = UtteranceAssembler()
        let first = assembler.ingest(language: .english, text: "Hi, Jack", isFinal: true)
        assembler.acknowledgeFinal(language: .english)
        let second = assembler.ingest(language: .english, text: "Hi, Lucy", isFinal: false)
        #expect(second?.id != first?.id)
        #expect(second?.text == "Hi, Lucy")
    }

    @Test("A greeting name swap after silence gets a new utterance id")
    func greetingNameSwapAfterSilenceGetsNewIdentity() throws {
        var assembler = UtteranceAssembler()
        _ = assembler.ingest(language: .zhHans, text: "你好，王刚", isFinal: false)
        let finalizedValue = assembler.silenceTimedOut()
        let finalized = try #require(finalizedValue)

        let nextValue = assembler.ingest(language: .zhHans, text: "你好，王强", isFinal: true)
        let next = try #require(nextValue)
        #expect(next.id != finalized.id)
        #expect(next.text == "你好，王强")
    }

    @Test("A greeting name swap volatile after silence gets a new utterance id")
    func greetingNameSwapVolatileAfterSilenceGetsNewIdentity() throws {
        var assembler = UtteranceAssembler()
        _ = assembler.ingest(language: .zhHans, text: "你好，王刚", isFinal: false)
        let finalizedValue = assembler.silenceTimedOut()
        let finalized = try #require(finalizedValue)

        let nextValue = assembler.ingest(language: .zhHans, text: "你好，王强", isFinal: false)
        let next = try #require(nextValue)
        #expect(next.id != finalized.id)
        #expect(next.text == "你好，王强")
    }

    @Test("A greeting name swap while still volatile gets a new utterance id")
    func greetingNameSwapWhileVolatileGetsNewIdentity() throws {
        var assembler = UtteranceAssembler()
        let firstValue = assembler.ingest(language: .english, text: "Hi, Jack", isFinal: false)
        let first = try #require(firstValue)
        let secondValue = assembler.ingest(language: .english, text: "Hi, Lucy", isFinal: false)
        let second = try #require(secondValue)

        #expect(second.id != first.id)
        #expect(second.text == "Hi, Lucy")
    }

    @Test("A new sentence after a final gets a new utterance id")
    func unrelatedSentenceAfterFinalGetsNewIdentity() {
        var assembler = UtteranceAssembler()
        let first = assembler.ingest(language: .english, text: "See you at three in the lobby", isFinal: true)
        assembler.acknowledgeFinal(language: .english)
        let second = assembler.ingest(language: .english, text: "I'd like a cup of coffee please", isFinal: false)
        #expect(second?.id != first?.id)
    }

    @Test("Japanese kana is accepted as Japanese, not Chinese")
    func japaneseKanaIsNotChinese() {
        var assembler = UtteranceAssembler()
        #expect(assembler.ingest(language: .zhHans, text: "コーヒーをください", isFinal: false) == nil)
        let result = assembler.ingest(language: .japanese, text: "コーヒーをください", isFinal: false)
        #expect(result?.language == .japanese)
    }

    @Test("Korean hangul is accepted as Korean")
    func koreanHangulMatches() {
        var assembler = UtteranceAssembler()
        let result = assembler.ingest(language: .korean, text: "커피 주세요", isFinal: false)
        #expect(result?.language == .korean)
    }

    @Test("Thai script is accepted as Thai")
    func thaiScriptMatches() {
        var assembler = UtteranceAssembler()
        let result = assembler.ingest(language: .thai, text: "กาแฟหน่อย", isFinal: false)
        #expect(result?.language == .thai)
    }

    @Test("Vietnamese diacritics are not treated as English")
    func vietnameseDiacriticsAreNotEnglish() {
        var assembler = UtteranceAssembler()
        #expect(assembler.ingest(language: .english, text: "Tôi muốn cà phê", isFinal: false) == nil)
        let result = assembler.ingest(language: .vietnamese, text: "Tôi muốn cà phê", isFinal: false)
        #expect(result?.language == .vietnamese)
    }

    @Test("A long Chinese hypothesis preempts English hallucination")
    func longChinesePreemptsEnglishHallucination() {
        var assembler = UtteranceAssembler()
        _ = assembler.ingest(
            language: .english,
            text: "Then I want you to imagine a picture",
            isFinal: false
        )
        let result = assembler.ingest(
            language: .zhHans,
            text: "在那时开始之前呢我想请大家想象一个画面假如你是一个穿着校服的高中生",
            isFinal: false
        )
        #expect(result?.language == .zhHans)
        #expect(result?.text.contains("想象") == true)
    }

    @Test("Han script is resolved as Chinese even if claimed English")
    func resolvedLanguagePrefersMatchingScript() {
        let language = UtteranceAssembler.resolvedLanguage(
            claimed: .english,
            text: "在那时开始之前呢，我想请大家想象一个画面"
        )
        #expect(language == .zhHans)
    }

    @Test("A prefix-extension final after silence reuses the finalized utterance")
    func prefixExtensionAfterSilenceKeepsIdentity() throws {
        var assembler = UtteranceAssembler()
        _ = assembler.ingest(language: .english, text: "They also cause us", isFinal: false)
        let finalizedValue = assembler.silenceTimedOut()
        let finalized = try #require(finalizedValue)

        let revisedValue = assembler.ingest(
            language: .english,
            text: "They also cause us to bump into each other.",
            isFinal: true
        )
        let revised = try #require(revisedValue)

        #expect(revised.id == finalized.id)
        #expect(revised.text == "They also cause us to bump into each other.")
        #expect(revised.isFinal == true)
        #expect(revised.isRevision == true)
    }

    @Test("A late prefix-extension final does not revise the closed row while a new row is live")
    func latePrefixExtensionDoesNotReviseClosedRowWhileNewRowIsLive() throws {
        var assembler = UtteranceAssembler()
        _ = assembler.ingest(language: .english, text: "They also cause us", isFinal: false)
        let finalizedValue = assembler.silenceTimedOut()
        let finalized = try #require(finalizedValue)
        let nextValue = assembler.ingest(
            language: .english,
            text: "And then something else entirely",
            isFinal: false
        )
        let next = try #require(nextValue)
        #expect(next.id != finalized.id)

        // Without audio ranges the late final may belong to either row; while
        // a new row is in progress, keep the previous (new-row) behavior.
        let lateValue = assembler.ingest(
            language: .english,
            text: "They also cause us to bump into each other.",
            isFinal: true
        )
        let late = try #require(lateValue)
        #expect(late.id != finalized.id)
        #expect(late.id == next.id)
    }

    @Test("A prefix-extension final outside the reconciliation window gets a new id")
    func prefixExtensionOutsideWindowGetsNewIdentity() throws {
        var assembler = UtteranceAssembler(reconciliationWindow: 0)
        _ = assembler.ingest(language: .english, text: "They also cause us", isFinal: false)
        let finalizedValue = assembler.silenceTimedOut()
        let finalized = try #require(finalizedValue)

        let lateValue = assembler.ingest(
            language: .english,
            text: "They also cause us to bump into each other.",
            isFinal: true
        )
        let late = try #require(lateValue)
        #expect(late.id != finalized.id)
        #expect(late.text == "They also cause us to bump into each other.")
    }

    @Test("A non-overlapping final after silence gets a new id")
    func unrelatedFinalAfterSilenceGetsNewIdentity() throws {
        var assembler = UtteranceAssembler()
        _ = assembler.ingest(language: .english, text: "See you at three in the lobby", isFinal: false)
        let finalizedValue = assembler.silenceTimedOut()
        let finalized = try #require(finalizedValue)

        let nextValue = assembler.ingest(
            language: .english,
            text: "I'd like a cup of coffee please",
            isFinal: true
        )
        let next = try #require(nextValue)
        #expect(next.id != finalized.id)
        #expect(next.text == "I'd like a cup of coffee please")
    }

    @Test("A reset clears the reconciliation record")
    func resetClearsReconciliation() throws {
        var assembler = UtteranceAssembler()
        _ = assembler.ingest(language: .english, text: "They also cause us", isFinal: false)
        let finalizedValue = assembler.silenceTimedOut()
        let finalized = try #require(finalizedValue)

        assembler.reset()

        let nextValue = assembler.ingest(
            language: .english,
            text: "They also cause us to bump into each other.",
            isFinal: true
        )
        let next = try #require(nextValue)
        #expect(next.id != finalized.id)
    }

    @Test("The reconciliation window includes its boundary")
    func reconciliationWindowIncludesBoundary() throws {
        let clock = TestClock()
        var assembler = UtteranceAssembler(reconciliationWindow: 3, now: { clock.now })
        _ = assembler.ingest(language: .english, text: "They also cause us", isFinal: false)
        let finalizedValue = assembler.silenceTimedOut()
        let finalized = try #require(finalizedValue)

        clock.now.addTimeInterval(3)

        let revisedValue = assembler.ingest(
            language: .english,
            text: "They also cause us to bump into each other.",
            isFinal: true
        )
        let revised = try #require(revisedValue)
        #expect(revised.id == finalized.id)
    }

    @Test("A final after the reconciliation window gets a new id")
    func reconciliationWindowExcludesLaterFinals() throws {
        let clock = TestClock()
        var assembler = UtteranceAssembler(reconciliationWindow: 3, now: { clock.now })
        _ = assembler.ingest(language: .english, text: "They also cause us", isFinal: false)
        let finalizedValue = assembler.silenceTimedOut()
        let finalized = try #require(finalizedValue)

        clock.now.addTimeInterval(3.001)

        let lateValue = assembler.ingest(
            language: .english,
            text: "They also cause us to bump into each other.",
            isFinal: true
        )
        let late = try #require(lateValue)
        #expect(late.id != finalized.id)
    }

    @Test("A replay volatile after silence stays on the closed utterance")
    func replayVolatileAfterSilenceKeepsIdentity() throws {
        var assembler = UtteranceAssembler()
        _ = assembler.ingest(language: .english, text: "Thank you", isFinal: false)
        let finalizedValue = assembler.silenceTimedOut()
        let finalized = try #require(finalizedValue)

        let volatileValue = assembler.ingest(
            language: .english,
            text: "Thank you very much",
            isFinal: false
        )
        let volatile = try #require(volatileValue)
        #expect(volatile.id == finalized.id)
        #expect(volatile.isFinal == false)
        #expect(volatile.isRevision)

        let finalValue = assembler.ingest(
            language: .english,
            text: "Thank you very much",
            isFinal: true
        )
        let final = try #require(finalValue)
        #expect(final.id == finalized.id)
        #expect(final.text == "Thank you very much")
        #expect(final.isFinal)
        #expect(final.isRevision)
    }

    @Test("A late final in one language leaves the other language's live utterance intact")
    func lateFinalDoesNotDisturbOtherLanguageUtterance() throws {
        let clock = TestClock()
        var assembler = UtteranceAssembler(now: { clock.now })
        _ = assembler.ingest(language: .english, text: "They also cause us", isFinal: false)
        let finalizedValue = assembler.silenceTimedOut()
        let finalized = try #require(finalizedValue)

        clock.now.addTimeInterval(0.9)
        let liveValue = assembler.ingest(language: .zhHans, text: "我想点一杯咖啡", isFinal: false)
        let live = try #require(liveValue)
        #expect(live.id != finalized.id)

        let lateValue = assembler.ingest(
            language: .english,
            text: "They also cause us to bump into each other.",
            isFinal: true
        )
        #expect(lateValue == nil)

        clock.now.addTimeInterval(0.2)
        let grownValue = assembler.ingest(language: .zhHans, text: "我想点一杯咖啡带走", isFinal: false)
        let grown = try #require(grownValue)
        #expect(grown.id == live.id)
        #expect(grown.text == "我想点一杯咖啡带走")
    }

    @Test(
        "Trusted single-locale mode keeps English with embedded Han text",
        arguments: [false, true]
    )
    func trustedSingleLocaleKeepsMixedScriptEnglish(isFinal: Bool) throws {
        var assembler = UtteranceAssembler(languagePurity: .trustedLocale)
        let value = assembler.ingest(
            language: .english,
            text: "I studied 中文 at Tsinghua.",
            isFinal: isFinal
        )
        let utterance = try #require(value)
        #expect(utterance.language == .english)
        #expect(utterance.text == "I studied 中文 at Tsinghua.")
        #expect(utterance.isFinal == isFinal)
    }

    @Test(
        "Trusted single-locale mode keeps short and numeric results",
        arguments: [("OK", false), ("OK", true), ("2024", false), ("2024", true)]
    )
    func trustedSingleLocaleKeepsShortResults(text: String, isFinal: Bool) throws {
        var assembler = UtteranceAssembler(languagePurity: .trustedLocale)
        let value = assembler.ingest(language: .english, text: text, isFinal: isFinal)
        let utterance = try #require(value)
        #expect(utterance.language == .english)
        #expect(utterance.text == text)
        #expect(utterance.isFinal == isFinal)
    }

    @Test("Strict dual-locale mode still rejects mixed-script English")
    func strictDualLocaleRejectsMixedScriptEnglish() {
        var assembler = UtteranceAssembler()
        #expect(
            assembler.ingest(
                language: .english,
                text: "I studied 中文 at Tsinghua.",
                isFinal: false
            ) == nil
        )
    }
}
