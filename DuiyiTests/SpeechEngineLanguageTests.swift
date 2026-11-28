import Foundation
import Speech
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

    @Test("The explicit failure fallback forces trusted locale for live captions only")
    func fallbackForcesTrustedLocale() {
        #expect(
            BilingualSpeechEngine.singleLocalePurity(
                forceTrustedLocale: true,
                requestedLanguageCount: 2,
                style: .liveCaptions
            ) == .trustedLocale
        )
        #expect(
            BilingualSpeechEngine.singleLocalePurity(
                forceTrustedLocale: true,
                requestedLanguageCount: 2,
                style: .meetingNotes
            ) == .strict
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

    @Test("ASR experiment flags parse fast results and contextual terms")
    func asrExperimentFlagsParse() {
        let options = ASRExperimentOptions.parse(arguments: [
            "-duiyi.asrFastResults", "NO",
            "-duiyi.asrContextTerms", "Cameron Russell, Lidia Yuknavitch, Fernando",
        ])

        #expect(options.fastResults == false)
        #expect(
            options.contextualStrings
                == ["Cameron Russell", "Lidia Yuknavitch", "Fernando"]
        )
    }

    @Test("ASR experiments default to fast results and no contextual bias")
    func asrExperimentDefaults() {
        let options = ASRExperimentOptions.parse(arguments: [])

        #expect(options.fastResults)
        #expect(options.contextualStrings.isEmpty)
    }

    @Test("Preemption publish defaults on and parses the rollback flag")
    func preemptionExperimentFlagParses() {
        #expect(UtteranceAssemblerExperimentOptions.parse(arguments: []).publishesPreemptedIncumbent)
        #expect(
            UtteranceAssemblerExperimentOptions.parse(arguments: [
                "-duiyi.assemblerPreemptionPublish", "YES",
            ]).publishesPreemptedIncumbent
        )
        #expect(
            UtteranceAssemblerExperimentOptions.parse(arguments: [
                "-duiyi.assemblerPreemptionPublish", "NO",
            ]).publishesPreemptedIncumbent == false
        )
    }

    @Test("ASR confidence aggregates runs by character weight")
    func asrConfidenceAggregates() {
        var text = AttributedString("hello world")
        if let hello = text.range(of: "hello") {
            text[hello].transcriptionConfidence = 0.8
        }
        if let world = text.range(of: "world") {
            text[world].transcriptionConfidence = 0.4
        }

        let stats = ASRConfidenceStats.from(text)

        #expect(stats?.runCount == 2)
        #expect(abs((stats?.minimum ?? 0) - 0.4) < 0.0001)
        #expect(abs((stats?.mean ?? 0) - 0.6) < 0.0001)
        #expect(stats?.buckets[4] == 5)
        #expect(stats?.buckets[8] == 5)
    }

    @Test("ASR confidence is nil when the framework omits the attribute")
    func asrConfidenceMissing() {
        #expect(ASRConfidenceStats.from(AttributedString("plain")) == nil)
    }
}
