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

    @Test("Contiguous final phrases join until a real audio gap")
    func contiguousFinalsJoinUntilRealGap() throws {
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

        // 0.8 s is past the row gap limit; punctuation is not the boundary.
        let next = try requireIngest(&assembler, "Thank you.", range(5.8, 7), isFinal: true)
        #expect(next.id != second.id)
        #expect(next.text == "Thank you.")
    }

    @Test("A period does not close a contiguous punctuated final")
    func punctuationFinalKeepsContiguousRow() throws {
        var assembler = UtteranceAssembler()
        let first = try requireIngest(
            &assembler, "Hello there.", range(0, 2), isFinal: true
        )
        let second = try requireIngest(
            &assembler, "How are you?", range(2, 4), isFinal: true
        )

        #expect(first.id == second.id)
        #expect(second.text == "Hello there. How are you?")
        #expect(second.isFinal == true)
        #expect(second.isRevision == true)
    }

    @Test("A period followed by a real gap starts a new row")
    func punctuatedFinalThenGapStartsNextRow() throws {
        var assembler = UtteranceAssembler()
        let first = try requireIngest(
            &assembler, "Hello there.", range(0, 2), isFinal: true
        )
        let second = try requireIngest(
            &assembler, "How are you?", range(2.8, 4.8), isFinal: true
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

    @Test("A late final that extends a closed range starts the next row")
    func lateFinalExtendingClosedRangeStartsNextRow() throws {
        var assembler = UtteranceAssembler()
        _ = try requireIngest(&assembler, "They also cause us", range(0, 2))
        let synthetic = try requireSilenceFinal(&assembler)

        let next = try requireIngest(
            &assembler, "into each other.", range(1.5, 4), isFinal: true
        )
        #expect(next.id != synthetic.id)
        #expect(next.text == "into each other.")
    }

    @Test("A late final revises the next row started by its volatile")
    func lateFinalRevisesLateVolatileRow() throws {
        var assembler = UtteranceAssembler()
        _ = try requireIngest(&assembler, "They also cause us", range(0, 2))
        let synthetic = try requireSilenceFinal(&assembler)
        let revived = try requireIngest(
            &assembler, "into each other.", range(1.5, 4)
        )
        let final = try requireIngest(
            &assembler, "into each other.", range(1.5, 4), isFinal: true
        )
        #expect(revived.id != synthetic.id)
        #expect(final.id == revived.id)
        #expect(final.text == "into each other.")
    }

    @Test("A late volatile that extends a closed range starts the next row")
    func lateVolatileExtendingClosedRangeStartsNextRow() throws {
        var assembler = UtteranceAssembler()
        _ = try requireIngest(&assembler, "They also cause us", range(0, 2))
        let synthetic = try requireSilenceFinal(&assembler)

        let revived = try requireIngest(
            &assembler, "bump into each other", range(1.5, 4)
        )
        #expect(revived.id != synthetic.id)
        #expect(revived.text == "bump into each other")
        #expect(revived.isFinal == false)
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

    @Test("Short final phrases between long contiguous phrases survive")
    func shortFinalBetweenLongPhrasesSurvives() throws {
        var assembler = UtteranceAssembler()
        let intro = "Highlight an Asian woman's Asian identity before a math test."
        let better = "She'll perform better."
        let identity = "Highlight her female identity."
        let worse = "She'll perform worse."
        let lead = "Lead a group of men to believe an athletic task is diagnostic of sports intelligence."

        _ = try requireIngest(&assembler, intro, range(0, 4.949), isFinal: false)
        _ = try requireIngest(&assembler, intro, range(0.18, 3.96), isFinal: true)
        _ = try requireIngest(&assembler, "she", range(3.96, 5.226), isFinal: false)
        _ = try requireIngest(&assembler, better, range(3.96, 5.226), isFinal: false)
        _ = try requireIngest(&assembler, better, range(4.14, 5.88), isFinal: true)
        _ = try requireIngest(&assembler, identity, range(5.88, 9.749), isFinal: false)
        _ = try requireIngest(&assembler, identity, range(6.24, 8.76), isFinal: true)
        _ = try requireIngest(&assembler, "she", range(8.76, 10.78), isFinal: false)
        _ = try requireIngest(&assembler, worse, range(8.76, 10.78), isFinal: false)
        _ = try requireIngest(&assembler, worse, range(8.76, 9.78), isFinal: true)
        _ = try requireIngest(&assembler, lead, range(9.78, 16.6), isFinal: false)
        let last = try requireIngest(&assembler, lead, range(11.04, 16.44), isFinal: true)

        #expect(last.text == "\(intro) \(better) \(identity) \(worse) \(lead)")
    }

    @Test("Disjoint finals with overlapping padded ranges both survive")
    func disjointFinalsWithOverlappingRangesSurvive() throws {
        var assembler = UtteranceAssembler()
        _ = try requireIngest(
            &assembler,
            "The best designs came",
            range(0, 4),
            isFinal: true
        )
        let second = try requireIngest(
            &assembler,
            "only after multiple failed attempts.",
            range(3.8, 6),
            isFinal: true
        )

        #expect(second.text == "The best designs came only after multiple failed attempts.")
    }

    @Test("Similar consecutive finals with padded overlap both survive")
    func similarConsecutiveFinalsWithPaddedOverlapSurvive() throws {
        var assembler = UtteranceAssembler()
        _ = try requireIngest(
            &assembler,
            "It's the shame of wanting something good.",
            range(0, 4),
            isFinal: true
        )
        let second = try requireIngest(
            &assembler,
            "It's the shame of feeling something good.",
            range(3.5, 7),
            isFinal: true
        )

        #expect(
            second.text
                == "It's the shame of wanting something good. "
                + "It's the shame of feeling something good."
        )
    }

    @Test("A distinct final inside a partial volatile's text keeps both")
    func distinctFinalInsidePartialVolatileKeepsBoth() throws {
        var assembler = UtteranceAssembler()
        _ = try requireIngest(
            &assembler,
            "She'll perform better today.",
            range(3.96, 5.6)
        )
        _ = try requireIngest(
            &assembler,
            "She'll perform better.",
            range(4.14, 4.9),
            isFinal: true
        )
        let last = try requireIngest(
            &assembler,
            "Headset off.",
            range(5.0, 5.5),
            isFinal: true
        )

        #expect(last.text == "She'll perform better today. Headset off.")
    }

    @Test("A late distinct final inside a finalized phrase keeps both")
    func lateDistinctFinalInsideFinalizedPhraseKeepsBoth() throws {
        var assembler = UtteranceAssembler()
        _ = try requireIngest(
            &assembler,
            "She'll perform better today.",
            range(3.96, 5.6),
            isFinal: true
        )
        let final = try requireIngest(
            &assembler,
            "Headset off.",
            range(5.0, 5.5),
            isFinal: true
        )

        #expect(final.text == "She'll perform better today. Headset off.")
    }

    @Test("A late distinct final inside an open volatile keeps both")
    func lateDistinctFinalInsideVolatileKeepsBoth() throws {
        var assembler = UtteranceAssembler()
        _ = try requireIngest(
            &assembler,
            "She'll perform better today.",
            range(3.96, 5.6)
        )
        let final = try requireIngest(
            &assembler,
            "Headset off.",
            range(5.0, 5.5),
            isFinal: true
        )

        #expect(final.text == "She'll perform better today. Headset off.")
    }

    @Test("A same-audio mishearing is replaced, not duplicated")
    func sameAudioMishearingReplaced() throws {
        var assembler = UtteranceAssembler()
        _ = try requireIngest(&assembler, "I scream", range(0, 3))
        let final = try requireIngest(
            &assembler, "ice cream", range(0.5, 2), isFinal: true
        )

        #expect(final.text == "ice cream")
    }

    @Test("A short same-audio correction replaces the preview")
    func shortSameAudioCorrectionReplacesPreview() throws {
        var assembler = UtteranceAssembler()
        _ = try requireIngest(&assembler, "oh", range(0, 2))
        let final = try requireIngest(
            &assembler, "Okay.", range(1, 1.5), isFinal: true
        )

        #expect(final.text == "Okay.")
    }

    @Test("A volatile padding overlap does not replace the next phrase's final")
    func volatilePaddingDoesNotReplaceNextFinal() throws {
        var assembler = UtteranceAssembler()
        _ = try requireIngest(&assembler, "First phrase", range(0, 4))
        let second = try requireIngest(
            &assembler,
            "Second phrase",
            range(3.8, 6),
            isFinal: true
        )

        #expect(second.text == "First phrase Second phrase")
    }

    @Test("A final before an existing phrase keeps audio order")
    func outOfOrderFinalKeepsAudioOrder() throws {
        var assembler = UtteranceAssembler()
        _ = try requireIngest(
            &assembler,
            "Second phrase",
            range(2, 4),
            isFinal: true
        )
        let first = try requireIngest(
            &assembler,
            "First phrase",
            range(0, 2),
            isFinal: true
        )

        #expect(first.text == "First phrase Second phrase")
    }

    @Test("A final that re-transcribes the same audio is authoritative")
    func containedDisjointFinalIsAuthoritative() throws {
        var assembler = UtteranceAssembler()
        _ = try requireIngest(
            &assembler,
            "Their house",
            range(0, 3),
            isFinal: true
        )
        let corrected = try requireIngest(
            &assembler,
            "There house",
            range(0.2, 2.8),
            isFinal: true
        )

        #expect(corrected.text == "There house")
    }

    @Test("A drastically truncated final keeps the fuller volatile text")
    func truncatedFinalKeepsFullerVolatile() throws {
        var assembler = UtteranceAssembler()
        let full = "Highlight an Asian woman's Asian identity before a math test? "
            + "She'll perform better."
        _ = try requireIngest(&assembler, full, range(0, 3))

        let final = try requireIngest(
            &assembler, "She'll perform better.", range(0, 3), isFinal: true
        )
        #expect(final.text == full)
    }

    @Test("A narrower final keeps the open phrase's full text")
    func narrowFinalKeepsOpenPhrase() throws {
        var assembler = UtteranceAssembler()
        let full = "Highlight an Asian woman's Asian identity before a math test? "
            + "She'll perform better."
        _ = try requireIngest(&assembler, full, range(0, 3))

        let final = try requireIngest(
            &assembler, "She'll perform better.", range(1.5, 3), isFinal: true
        )
        #expect(final.text == full)
        #expect(final.isFinal)
    }

    @Test("A narrow final does not truncate an already-finalized phrase")
    func narrowFinalKeepsFinalizedPhrase() throws {
        var assembler = UtteranceAssembler()
        let full = "They also cause us to bump into each other"
        _ = try requireIngest(&assembler, full, range(0, 3), isFinal: true)

        let final = try requireIngest(
            &assembler, "into each other", range(2, 3), isFinal: true
        )
        #expect(final.text == full)
    }

    @Test("A punctuation-only result is ignored")
    func punctuationOnlyResultIsIgnored() {
        var assembler = UtteranceAssembler(languagePurity: .trustedLocale)
        #expect(
            assembler.ingest(
                language: .english, text: ".", isFinal: true, range: range(0, 1)
            ) == nil
        )
        #expect(
            assembler.ingest(
                language: .english, text: "...", isFinal: false, range: range(0, 1)
            ) == nil
        )
    }

    @Test("A punctuation-only result does not replace the open phrase")
    func punctuationOnlyResultKeepsOpenPhrase() throws {
        var assembler = UtteranceAssembler(languagePurity: .trustedLocale)
        _ = try requireIngest(
            &assembler, "They also cause us to bump", range(0, 2)
        )
        #expect(
            assembler.ingest(
                language: .english, text: ".", isFinal: true, range: range(0, 2)
            ) == nil
        )

        let final = try requireIngest(
            &assembler, "into each other.", range(2, 4), isFinal: true
        )
        #expect(final.text == "They also cause us to bump into each other.")
    }

    @Test("An open volatile survives the next phrase's final")
    func openVolatileSurvivesNextFinal() throws {
        var assembler = UtteranceAssembler()
        let first = try requireIngest(
            &assembler, "It's the shame we carry.", range(0, 2)
        )
        let second = try requireIngest(
            &assembler,
            "It's the shame of wanting something good.",
            range(2, 4),
            isFinal: true
        )

        #expect(second.id == first.id)
        #expect(
            second.text
                == "It's the shame we carry. It's the shame of wanting something good."
        )
    }

    @Test("Consecutive volatile sentences all survive the last final")
    func consecutiveVolatilesSurviveLastFinal() throws {
        var assembler = UtteranceAssembler()
        _ = try requireIngest(
            &assembler, "It's the shame we carry.", range(0, 1)
        )
        _ = try requireIngest(
            &assembler, "It's the shame of wanting something good.", range(1, 2)
        )
        _ = try requireIngest(
            &assembler, "It's the shame of feeling something good.", range(2, 3)
        )
        let last = try requireIngest(
            &assembler,
            "The shame of not believing we deserve it.",
            range(3, 4),
            isFinal: true
        )

        #expect(
            last.text
                == "It's the shame we carry. It's the shame of wanting something good. "
                + "It's the shame of feeling something good. "
                + "The shame of not believing we deserve it."
        )
    }

    @Test("An open volatile survives the next phrase's volatile")
    func openVolatileSurvivesNextVolatile() throws {
        var assembler = UtteranceAssembler()
        _ = try requireIngest(
            &assembler, "It's the shame we carry.", range(0, 2)
        )
        let second = try requireIngest(
            &assembler,
            "It's the shame of wanting something good.",
            range(2, 4)
        )

        #expect(second.isFinal == false)
        #expect(
            second.text
                == "It's the shame we carry. It's the shame of wanting something good."
        )
    }

    @Test("A continuation phrase loses its leading punctuation")
    func continuationPhraseLeadingPunctuationIsStripped() throws {
        var assembler = UtteranceAssembler()
        _ = try requireIngest(
            &assembler,
            "An award winning author, Lydia Yuknovich.",
            range(0, 2),
            isFinal: true
        )
        let second = try requireIngest(
            &assembler,
            ",.. she didn't follow up on it.",
            range(2.8, 4.8),
            isFinal: true
        )

        #expect(second.text == "she didn't follow up on it.")
    }

    @Test("A phrase ending in punctuation joins the next phrase with a space")
    func punctuationPhraseJoinsWithSpace() throws {
        var assembler = UtteranceAssembler()
        let first = try requireIngest(
            &assembler, "Hello,", range(0, 1), isFinal: true
        )
        let second = try requireIngest(
            &assembler, "world", range(1, 2), isFinal: true
        )

        #expect(first.id == second.id)
        #expect(second.text == "Hello, world")
    }

    @Test("A Chinese phrase ending in punctuation joins without a space")
    func chinesePunctuationPhraseJoinsWithoutSpace() throws {
        var assembler = UtteranceAssembler()
        _ = try requireIngest(
            &assembler, "我们先去，", range(0, 1), isFinal: true, language: .zhHans
        )
        let second = try requireIngest(
            &assembler, "吃饭吧", range(1, 2), isFinal: true, language: .zhHans
        )

        #expect(second.text == "我们先去，吃饭吧")
    }

    @Test("A trailing ellipsis keeps a contiguous phrase in the same row")
    func trailingEllipsisKeepsContiguousPhrase() throws {
        var assembler = UtteranceAssembler()
        let first = try requireIngest(
            &assembler,
            "Lead a group of men to believe an athletic task is di...",
            range(20.44, 22.90),
            isFinal: true
        )
        let second = try requireIngest(
            &assembler,
            "nostic of sports intelligence.",
            range(22.90, 25.06)
        )

        #expect(first.id == second.id)
        #expect(
            second.text
                == "Lead a group of men to believe an athletic task is di nostic of sports intelligence."
        )
        #expect(second.isFinal == false)
    }

    @Test("A trailing ellipsis is removed when a contiguous final continues the row")
    func trailingEllipsisIsStrippedOnContinuation() throws {
        var assembler = UtteranceAssembler()
        _ = try requireIngest(
            &assembler, "I was going to say...", range(0, 2), isFinal: true
        )
        let second = try requireIngest(
            &assembler, "hello.", range(2, 4), isFinal: true
        )

        #expect(second.text == "I was going to say hello.")
    }

    @Test("A trailing ellipsis does not merge a phrase across a real pause")
    func trailingEllipsisDoesNotMergeAcrossGap() throws {
        var assembler = UtteranceAssembler()
        let first = try requireIngest(
            &assembler, "I don't know...", range(0, 2), isFinal: true
        )
        let second = try requireIngest(
            &assembler, "Maybe tomorrow.", range(3, 5)
        )

        #expect(first.id != second.id)
        #expect(second.text == "Maybe tomorrow.")
    }

    @Test("Contiguous punctuated finals stay one row")
    func contiguousPunctuatedFinalsStayOneRow() throws {
        var assembler = UtteranceAssembler()
        let first = try requireIngest(
            &assembler,
            "The shame of not believing.",
            range(139.64, 142.10),
            isFinal: true
        )
        let second = try requireIngest(
            &assembler,
            "We deserve it.",
            range(142.10, 143.12),
            isFinal: true
        )

        #expect(first.id == second.id)
        #expect(second.text == "The shame of not believing. We deserve it.")
        #expect(second.isFinal == true)
        #expect(second.isRevision == true)
    }

    @Test("A final-only row is closed by silence for the next phrase")
    func silenceClosesFinalOnlyRow() throws {
        var assembler = UtteranceAssembler()
        let first = try requireIngest(
            &assembler, "Hello there.", range(0, 2), isFinal: true
        )

        let silence = assembler.silenceTimedOut()
        #expect(silence == nil)
        #expect(assembler.hasOpenRow == false)

        // No 0.75 s gap: only the silence close can give this a new id.
        let next = try requireIngest(
            &assembler, "How are you?", range(2.2, 4.2), isFinal: true
        )
        #expect(next.id != first.id)
        #expect(next.text == "How are you?")
    }

    @Test("Three contiguous punctuated sentences stay one row")
    func threeContiguousPunctuatedSentencesStayOneRow() throws {
        var assembler = UtteranceAssembler()
        let first = try requireIngest(
            &assembler, "We don't always know how to hope.", range(10, 12), isFinal: true
        )
        _ = try requireIngest(
            &assembler, "Or say yes, or choose.", range(12, 13.5), isFinal: true
        )
        let third = try requireIngest(
            &assembler,
            "big thing. Even when it's right in front of us.",
            range(13.5, 16),
            isFinal: true
        )

        #expect(first.id == third.id)
        #expect(
            third.text
                == "We don't always know how to hope. Or say yes, or choose. big thing. Even when it's right in front of us."
        )
    }

    @Test("A row longer than the duration cap closes at a phrase boundary")
    func maxDurationCapClosesAtPhraseBoundary() throws {
        var assembler = UtteranceAssembler()
        var ids: [UUID] = []
        for index in 0..<7 {
            let start = Double(index) * 2.2
            let value = try requireIngest(
                &assembler,
                "Sentence number \(index + 1).",
                range(start, start + 2.2),
                isFinal: true
            )
            ids.append(value.id)
        }

        #expect(ids[0] == ids[5])
        #expect(ids[6] != ids[5])
    }

    @Test("A row longer than the character cap closes at a phrase boundary")
    func maxCharacterCapClosesAtPhraseBoundary() throws {
        var assembler = UtteranceAssembler()
        var ids: [UUID] = []
        for index in 0..<6 {
            let start = Double(index)
            let value = try requireIngest(
                &assembler,
                "This is a deliberately long sentence number \(index + 1).",
                range(start, start + 1),
                isFinal: true
            )
            ids.append(value.id)
        }

        #expect(Set(ids).count > 1)
    }

    @Test("The cap does not close a row with a volatile tail")
    func capDoesNotCloseVolatileRow() throws {
        var assembler = UtteranceAssembler()
        var first: Utterance?
        var last: Utterance?
        for index in 0..<7 {
            let start = Double(index) * 2.2
            let value = try requireIngest(
                &assembler,
                "volatile phrase number \(index + 1)",
                range(start, start + 2.2)
            )
            first = first ?? value
            last = value
        }

        #expect(first?.id == last?.id)
        #expect(last?.isFinal == false)
    }

    @Test("A late final for the silence-closed tail keeps the finalized prefix")
    func lateFinalForClosedTailKeepsPrefix() throws {
        var assembler = UtteranceAssembler()
        _ = try requireIngest(
            &assembler, "They also cause us", range(0, 2), isFinal: true
        )
        _ = try requireIngest(
            &assembler, "to bump into each other", range(2, 4)
        )
        let synthetic = try requireSilenceFinal(&assembler)
        #expect(synthetic.text == "They also cause us to bump into each other")

        // The transcriber's own final covers only the tail range. It must
        // replace the tail, not the whole row text.
        let late = try requireIngest(
            &assembler,
            "to bump into each other.",
            range(2, 4),
            isFinal: true
        )
        #expect(late.id == synthetic.id)
        #expect(late.text == "They also cause us to bump into each other.")
    }

    @Test("A late final after a language-change close keeps the old prefix")
    func lateFinalAfterLanguageCloseKeepsPrefix() throws {
        let clock = RangeTestClock()
        var assembler = UtteranceAssembler(now: { clock.now })
        _ = try requireIngest(
            &assembler, "They also cause us", range(0, 2), isFinal: true
        )
        let live = try requireIngest(
            &assembler, "to bump into each other", range(2, 4)
        )
        // A confident other-language result closes the English row (the
        // utterance-identity fix) while its tail is still volatile.
        clock.now.addTimeInterval(1.5)
        _ = assembler.ingest(
            language: .zhHans,
            text: "他们互相碰撞",
            isFinal: true,
            range: range(2.1, 4)
        )

        let late = try requireIngest(
            &assembler,
            "to bump into each other.",
            range(2, 4),
            isFinal: true
        )
        #expect(late.id == live.id)
        #expect(late.text == "They also cause us to bump into each other.")
    }

    @Test("A late tail final keeps every finalized phrase of the row")
    func lateTailFinalKeepsAllFinalizedPhrases() throws {
        var assembler = UtteranceAssembler()
        _ = try requireIngest(
            &assembler, "They also cause us", range(0, 2), isFinal: true
        )
        _ = try requireIngest(
            &assembler, "to bump into each other", range(2, 4), isFinal: true
        )
        _ = try requireIngest(&assembler, "and then", range(4, 5))
        _ = try requireSilenceFinal(&assembler)

        let late = try requireIngest(
            &assembler, "and then.", range(4, 5), isFinal: true
        )
        #expect(
            late.text == "They also cause us to bump into each other and then."
        )
    }

    @Test("A late final after a gap close keeps the finalized prefix")
    func lateFinalAfterGapCloseKeepsPrefix() throws {
        var assembler = UtteranceAssembler()
        _ = try requireIngest(
            &assembler, "They also cause us", range(0, 2), isFinal: true
        )
        _ = try requireIngest(
            &assembler, "to bump into each other", range(2, 4)
        )
        // A phrase after a >0.75 s gap closes the row with its volatile tail.
        _ = try requireIngest(&assembler, "and then", range(5, 6))

        let late = try requireIngest(
            &assembler,
            "to bump into each other.",
            range(2, 4),
            isFinal: true
        )
        #expect(late.text == "They also cause us to bump into each other.")
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

    @Test("A gap close publishes the open volatile as a final")
    func gapClosePublishesOpenVolatile() throws {
        var assembler = UtteranceAssembler()
        let first = try requireIngest(&assembler, "First phrase", range(0, 2))
        _ = try requireIngest(&assembler, "Second phrase", range(3, 5))

        let pending = assembler.takePendingFinals()
        #expect(pending.count == 1)
        #expect(pending.first?.id == first.id)
        #expect(pending.first?.text == "First phrase")
        #expect(pending.first?.isFinal == true)
        #expect(pending.first?.isRevision == false)
        #expect(assembler.takePendingFinals().isEmpty)
    }

    @Test("A gap close publishes the finalized prefix plus the open volatile")
    func gapClosePublishesPrefixAndVolatile() throws {
        var assembler = UtteranceAssembler()
        _ = try requireIngest(
            &assembler, "Hello.", range(0, 2), isFinal: true
        )
        _ = try requireIngest(&assembler, "there", range(2, 3))
        let next = try requireIngest(
            &assembler, "Next.", range(4, 6), isFinal: true
        )

        let pending = assembler.takePendingFinals()
        #expect(pending.count == 1)
        #expect(pending.first?.text == "Hello. there")
        #expect(pending.first?.isRevision == true)
        #expect(next.text == "Next.")
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

    @Test("A different language after a published final starts a new id")
    func differentLanguageAfterFinalStartsNewID() throws {
        let clock = RangeTestClock()
        var assembler = UtteranceAssembler(now: { clock.now })
        let first = try requireIngest(
            &assembler, "Hello there", range(0, 1), isFinal: true
        )
        assembler.acknowledgeFinal(language: .english)
        clock.now.addTimeInterval(1.5)
        let second = try requireIngest(
            &assembler,
            "谢谢你的服务。",
            range(1.1, 2),
            isFinal: true,
            language: .zhHans
        )

        #expect(second.id != first.id)
        #expect(second.language == .zhHans)
    }

    @Test("A late final for the old range revises the old row after a language change")
    func lateFinalAfterLanguageChangeRevisesOldRow() throws {
        let clock = RangeTestClock()
        var assembler = UtteranceAssembler(now: { clock.now })
        let first = try requireIngest(
            &assembler, "Hello there", range(0, 1), isFinal: true
        )
        assembler.acknowledgeFinal(language: .english)
        clock.now.addTimeInterval(1.5)
        _ = try requireIngest(
            &assembler,
            "谢谢你的服务。",
            range(1.1, 2),
            isFinal: true,
            language: .zhHans
        )
        // The Chinese final ends a sentence and holds other languages for 0.8 s.
        clock.now.addTimeInterval(1.0)
        let late = try requireIngest(
            &assembler, "Hello there!", range(0, 1), isFinal: true
        )

        #expect(late.id == first.id)
        #expect(late.language == .english)
        #expect(late.isRevision == true)
    }
}
