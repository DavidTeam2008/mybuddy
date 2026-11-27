import Testing
@testable import Duiyi

struct TextNormalizationTests {
    @Test("A continuation phrase loses its leading punctuation")
    func leadingContinuationMarksAreStripped() {
        #expect(
            TextNormalization.sourcePhrase(",.. she didn't follow up")
                == "she didn't follow up"
        )
        #expect(TextNormalization.sourcePhrase("... and then") == "and then")
        #expect(TextNormalization.sourcePhrase("…and then") == "and then")
    }

    @Test("A punctuation-only phrase is left for the revoke path")
    func punctuationOnlyPhraseIsKept() {
        #expect(TextNormalization.sourcePhrase("...") == "...")
    }

    @Test("A decimal keeps its single period")
    func decimalKeepsPeriod() {
        #expect(TextNormalization.sourcePhrase("3.14") == "3.14")
        #expect(TextNormalization.sourcePhrase(".5 million") == ".5 million")
    }

    @Test("Overlong English dot runs collapse to three")
    func englishDotRunsCollapse() {
        #expect(TextNormalization.sourcePhrase("what you.........") == "what you...")
        #expect(TextNormalization.translation("wait....", language: .english) == "wait...")
        #expect(TextNormalization.translation("wait...", language: .english) == "wait...")
    }

    @Test("Chinese ellipses use two ellipsis characters")
    func chineseEllipsisWidth() {
        #expect(TextNormalization.translation("会影响......", language: .zhHans) == "会影响……")
        #expect(TextNormalization.translation("会影响……", language: .zhHans) == "会影响……")
        #expect(TextNormalization.translation("3.14", language: .zhHans) == "3.14")
    }
}
