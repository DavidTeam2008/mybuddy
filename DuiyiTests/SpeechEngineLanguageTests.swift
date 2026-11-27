import Foundation
import Testing
@testable import Duiyi

struct SpeechEngineLanguageTests {
    @Test("Meeting multilingual keeps every requested locale")
    func keepsAllRequestedLanguages() {
        let languages = BilingualSpeechEngine.normalizedLanguages(
            languages: [.japanese, .korean, .thai, .vietnamese],
            fallback: .zhHans
        )
        #expect(languages.prefix(2).count == 2)
        #expect(languages == [.japanese, .korean, .thai, .vietnamese])
    }

    @Test("Empty request falls back to the display language")
    func emptyUsesFallback() {
        let languages = BilingualSpeechEngine.normalizedLanguages(languages: [], fallback: .english)
        #expect(languages == [.english])
    }

    @Test("Only non-revision finals are acknowledged as the current final")
    func acknowledgesOnlyNonRevisionFinals() {
        #expect(
            BilingualSpeechEngine.shouldAcknowledgeFinal(
                Utterance(language: .english, text: "Hello", isFinal: true)
            )
        )
        #expect(
            !BilingualSpeechEngine.shouldAcknowledgeFinal(
                Utterance(language: .english, text: "Hello", isFinal: false)
            )
        )
        #expect(
            !BilingualSpeechEngine.shouldAcknowledgeFinal(
                Utterance(language: .english, text: "Hello", isFinal: true, isRevision: true)
            )
        )
    }

    @Test("A dual transcriber failure plans a single-locale fallback without ending the stream")
    func dualFailurePlansSingleFallback() {
        let plan = BilingualSpeechEngine.transcriberFailurePlan(
            usingDual: true,
            isStopping: false,
            isRecovering: false
        )

        #expect(plan.recovery == .singleFallback)
        #expect(!plan.failStream)
    }

    @Test("A single-locale or stopping transcriber failure ends the stream")
    func singleOrStoppingFailureEndsStream() {
        let single = BilingualSpeechEngine.transcriberFailurePlan(
            usingDual: false,
            isStopping: false,
            isRecovering: false
        )
        #expect(single.recovery == .none)
        #expect(single.failStream)

        let stopping = BilingualSpeechEngine.transcriberFailurePlan(
            usingDual: true,
            isStopping: true,
            isRecovering: false
        )
        #expect(stopping.recovery == .none)
        #expect(stopping.failStream)
    }

    @Test("A second failure during an in-flight fallback does not end the stream")
    func failureDuringFallbackIsDeferred() {
        let plan = BilingualSpeechEngine.transcriberFailurePlan(
            usingDual: true,
            isStopping: false,
            isRecovering: true
        )

        #expect(plan.recovery == .none)
        #expect(!plan.failStream)
    }

    @Test("The explicit failure fallback forces trusted locale")
    func fallbackForcesTrustedLocale() {
        #expect(
            BilingualSpeechEngine.singleLocalePurity(
                forceTrustedLocale: true,
                requestedLanguageCount: 2,
                style: .meetingNotes
            ) == .trustedLocale
        )
    }

    @Test("Single-locale purity keeps the existing request and style rules")
    func purityKeepsExistingRules() {
        #expect(
            BilingualSpeechEngine.singleLocalePurity(
                forceTrustedLocale: false,
                requestedLanguageCount: 1,
                style: .liveCaptions
            ) == .trustedLocale
        )
        #expect(
            BilingualSpeechEngine.singleLocalePurity(
                forceTrustedLocale: false,
                requestedLanguageCount: 2,
                style: .liveCaptions
            ) == .strict
        )
        #expect(
            BilingualSpeechEngine.singleLocalePurity(
                forceTrustedLocale: false,
                requestedLanguageCount: 1,
                style: .meetingNotes
            ) == .strict
        )
    }
}
