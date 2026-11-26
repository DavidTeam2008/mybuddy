import Foundation
import Testing
@testable import Duiyi

private final class RangeTestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_700_000_000)
}

struct UtteranceAssemblerRangeTests {
    private func range(_ start: Double, _ end: Double) -> SpeechRange {
        SpeechRange(start: start, end: end)
    }

    private func requireIngest(
        _ assembler: inout UtteranceAssembler,
        _ text: String,
        _ range: SpeechRange,
        isFinal: Bool = false,
        language: AppLanguage = .english
    ) throws -> Utterance {
        let value = assembler.ingest(
            language: language,
            text: text,
            isFinal: isFinal,
            range: range
        )
        return try #require(value)
    }

    private func requireSilenceFinal(
        _ assembler: inout UtteranceAssembler
    ) throws -> Utterance {
        let value = assembler.silenceTimedOut()
        return try #require(value)
    }

    @Test("A growing volatile phrase updates one row in place")
    func volatilePhraseGrowsInPlace() throws {
        var assembler = UtteranceAssembler()
        let first = try requireIngest(&assembler, "They also cause us", range(0, 1.5))
        let second = try requireIngest(&assembler, "They also cause us to bump", range(0, 2.2))

        #expect(first.id == second.id)
        #expect(second.text == "They also cause us to bump")
        #expect(second.isFinal == false)
    }

    @Test("Contiguous final phrases join until a sentence terminator")
    func contiguousFinalsJoinUntilPunctuation() throws {
        var assembler = UtteranceAssembler()
        let first = try requireIngest(
            &assembler, "The best designs came", range(0, 2), isFinal: true
        )
        let second = try requireIngest(
            &assembler,
            "only after multiple failed attempts.",
            range(2, 5),
            isFinal: true
        )

        #expect(first.id == second.id)
        #expect(second.text == "The best designs came only after multiple failed attempts.")
        #expect(second.isFinal == true)
        #expect(second.isRevision == true)

        let next = try requireIngest(&assembler, "Thank you.", range(5.5, 7), isFinal: true)
        #expect(next.id != second.id)
        #expect(next.text == "Thank you.")
    }

    @Test("A sentence-terminator final closes the row before the next final")
    func punctuationFinalClosesRow() throws {
        var assembler = UtteranceAssembler()
        let first = try requireIngest(
            &assembler, "Hello there.", range(0, 2), isFinal: true
        )
        let second = try requireIngest(
            &assembler, "How are you?", range(2, 4), isFinal: true
        )

        #expect(first.id != second.id)
        #expect(second.text == "How are you?")
    }

    @Test("A volatile revision of the same range keeps one row and id")
    func volatileRevisionKeepsRow() throws {
        var assembler = UtteranceAssembler()
        let first = try requireIngest(&assembler, "Helo", range(0, 1))
        let second = try requireIngest(&assembler, "Hello", range(0, 1))
        let final = try requireIngest(
            &assembler, "Hello.", range(0, 1), isFinal: true
        )

        #expect(first.id == second.id)
        #expect(first.id == final.id)
        #expect(final.text == "Hello.")
        #expect(final.isFinal)
    }

    @Test("An empty volatile revokes the open tail but keeps the finalized prefix")
    func emptyVolatileRevokesTail() throws {
        var assembler = UtteranceAssembler()
        let finalized = try requireIngest(
            &assembler, "I was astounded", range(0, 2), isFinal: true
        )
        let withTail = try requireIngest(&assembler, "proud", range(2, 3))
        #expect(withTail.text == "I was astounded proud")

        let retracted = try requireIngest(&assembler, "", range(2, 3))
        #expect(retracted.id == finalized.id)
        #expect(retracted.text == "I was astounded")
        #expect(retracted.isFinal == true)
        #expect(retracted.isRevision == true)
    }

    @Test("A late final for a silence-closed range revises the same row")
    func lateFinalAfterSilenceReusesRow() throws {
        var assembler = UtteranceAssembler()
        let live = try requireIngest(&assembler, "They also cause us", range(0, 1.5))
        let synthetic = try requireSilenceFinal(&assembler)
        #expect(synthetic.id == live.id)
        #expect(synthetic.isFinal)

        let late = try requireIngest(
            &assembler,
            "They also cause us to bump into each other.",
            range(0, 2.5),
            isFinal: true
        )
        #expect(late.id == synthetic.id)
        #expect(late.text == "They also cause us to bump into each other.")
        #expect(late.isFinal)
        #expect(late.isRevision)
    }

    @Test("A late volatile for a closed range does not reopen the row")
    func lateVolatileForClosedRangeIsIgnored() throws {
        var assembler = UtteranceAssembler()
        _ = try requireIngest(&assembler, "They also cause us", range(0, 1.5))
        _ = try requireSilenceFinal(&assembler)

        let stale = assembler.ingest(
            language: .english,
            text: "They also",
            isFinal: false,
            range: range(0, 1.5)
        )
        #expect(stale == nil)

        let next = try requireIngest(&assembler, "And then", range(2, 3))
        #expect(next.text == "And then")
    }

    @Test("A late final long after silence still reuses the closed row")
    func lateFinalLongAfterSilenceStillReusesRow() throws {
        let clock = RangeTestClock()
        var assembler = UtteranceAssembler(now: { clock.now })
        _ = try requireIngest(&assembler, "See you at three", range(0, 2))
        let synthetic = try requireSilenceFinal(&assembler)

        clock.now.addTimeInterval(13)

        let late = try requireIngest(
            &assembler, "See you at three.", range(0, 2), isFinal: true
        )
        #expect(late.id == synthetic.id)
        #expect(late.text == "See you at three.")
    }

    @Test("A late final replaces a longer synthetic guess even when shorter")
    func lateFinalIsAuthoritativeWhenShorter() throws {
        var assembler = UtteranceAssembler()
        _ = try requireIngest(
            &assembler,
            "They also cause us to bump into each other maybe",
            range(0, 3)
        )
        let synthetic = try requireSilenceFinal(&assembler)

        let late = try requireIngest(
            &assembler,
            "They also cause us to bump into each other.",
            range(0, 3),
            isFinal: true
        )
        #expect(late.id == synthetic.id)
        #expect(late.text == "They also cause us to bump into each other.")
    }

    @Test("A volatile after an audio gap starts a new row")
    func volatileAfterGapStartsNewRow() throws {
        var assembler = UtteranceAssembler()
        let first = try requireIngest(&assembler, "First phrase", range(0, 2))
        let second = try requireIngest(&assembler, "Second phrase", range(3, 5))

        #expect(first.id != second.id)
        #expect(second.text == "Second phrase")
    }

    @Test("A final after an audio gap starts a new row")
    func gapStartsNewRow() throws {
        var assembler = UtteranceAssembler()
        let first = try requireIngest(
            &assembler, "First phrase", range(0, 2), isFinal: true
        )
        let second = try requireIngest(
            &assembler, "Second phrase", range(3, 5), isFinal: true
        )

        #expect(first.id != second.id)
        #expect(second.text == "Second phrase")
    }

    @Test("Contiguous final phrases join with a space in Latin text")
    func contiguousLatinPhrasesJoinWithSpace() throws {
        var assembler = UtteranceAssembler()
        let first = try requireIngest(
            &assembler, "We need to", range(0, 1), isFinal: true
        )
        let second = try requireIngest(
            &assembler, "go now", range(1, 2), isFinal: true
        )

        #expect(first.id == second.id)
        #expect(second.text == "We need to go now")
    }

    @Test("Contiguous Chinese phrases join without a space")
    func contiguousChinesePhrasesJoinWithoutSpace() throws {
        var assembler = UtteranceAssembler()
        _ = try requireIngest(
            &assembler, "我们先去", range(0, 1), isFinal: true, language: .zhHans
        )
        let second = try requireIngest(
            &assembler, "吃饭吧", range(1, 2), isFinal: true, language: .zhHans
        )

        #expect(second.text == "我们先去吃饭吧")
    }

    @Test("A transcriber final means the silence timer has nothing to synthesize")
    func silenceAfterTranscriberFinalIsNoOp() throws {
        var assembler = UtteranceAssembler()
        _ = try requireIngest(&assembler, "Hello there", range(0, 2), isFinal: true)
        #expect(assembler.hasOpenRange == false)
        let silence = assembler.silenceTimedOut()
        #expect(silence == nil)
    }

    @Test("A silence final closes the row so the next phrase gets a new id")
    func silenceFinalClosesRow() throws {
        var assembler = UtteranceAssembler()
        let live = try requireIngest(
            &assembler, "明天见吧", range(0, 2), language: .zhHans
        )
        let finalized = try requireSilenceFinal(&assembler)
        #expect(finalized.id == live.id)
        #expect(finalized.isFinal)

        let next = try requireIngest(
            &assembler, "好的", range(2.2, 3), language: .zhHans
        )
        #expect(next.id != finalized.id)
    }

    @Test("Strict dual-locale mode still drops a hallucination with a range")
    func strictDualLocaleDropsHallucination() throws {
        var assembler = UtteranceAssembler()
        let english = try requireIngest(&assembler, "you are right", range(0, 2))
        let leaked = assembler.ingest(
            language: .zhHans,
            text: "你是对的",
            isFinal: true,
            range: range(0, 2)
        )

        #expect(english.language == .english)
        #expect(leaked == nil || leaked?.language == .english)
        if let leaked {
            #expect(leaked.text == "you are right")
        }
    }

    @Test("A greeting name swap within a range starts a new row")
    func greetingNameSwapStartsNewRow() throws {
        var assembler = UtteranceAssembler()
        let first = try requireIngest(&assembler, "Hi, Jack", range(0, 1))
        let second = try requireIngest(&assembler, "Hi, Lucy", range(0, 1))

        #expect(first.id != second.id)
        #expect(second.text == "Hi, Lucy")

        // The final for this audio belongs to the new greeting's row; it must
        // not revise the old name.
        let final = try requireIngest(
            &assembler, "Hi, Lucy.", range(0, 1), isFinal: true
        )
        #expect(final.id == second.id)
        #expect(final.text == "Hi, Lucy.")
    }

    @Test("An empty final for a range that never had text is ignored")
    func emptyFinalForUnseenRangeIsIgnored() {
        var assembler = UtteranceAssembler()
        #expect(
            assembler.ingest(
                language: .english,
                text: "   ",
                isFinal: true,
                range: range(0, 1)
            ) == nil
        )
    }
}
