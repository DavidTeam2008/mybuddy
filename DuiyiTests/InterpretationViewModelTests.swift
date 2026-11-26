import Foundation
import Testing
@testable import Duiyi

actor MockAudioSession: AudioSessionConfiguring {
    var snapshot = AudioRouteSnapshot(outputs: [.headphones])
    private var continuation: AsyncStream<AudioRouteSnapshot>.Continuation?

    init(outputs: [AudioRouteKind] = [.headphones]) {
        snapshot = AudioRouteSnapshot(outputs: outputs)
    }

    func activate(_ useCase: AudioUseCase) async throws {
        _ = useCase
    }

    func deactivate() async {}

    func currentRoute() async -> AudioRouteSnapshot {
        snapshot
    }

    func routeChanges() async -> AsyncStream<AudioRouteSnapshot> {
        AsyncStream { continuation in
            Task { await self.setContinuation(continuation) }
        }
    }

    func emit(_ snapshot: AudioRouteSnapshot) {
        self.snapshot = snapshot
        continuation?.yield(snapshot)
    }

    private func setContinuation(_ continuation: AsyncStream<AudioRouteSnapshot>.Continuation) {
        self.continuation = continuation
    }
}

@MainActor
final class MockSpeechSynthesizer: SpeechSynthesizing {
    var spoken: [String] = []
    var hasVoiceResult = true
    var holdsUntilReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func hasVoice(for language: AppLanguage) async -> Bool {
        _ = language
        return hasVoiceResult
    }

    func speak(_ job: SynthesisJob) async {
        spoken.append(job.text)
        guard holdsUntilReleased else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func stopAndClear() async {
        continuation?.resume()
        continuation = nil
    }
}

actor RecordingSpeechEngine: SpeechRecognizing {
    var startedLanguages: [AppLanguage] = []
    var startedFallback: AppLanguage?
    var startedStyle: SpeechRecognitionStyle = .liveCaptions
    private var continuation: AsyncStream<Utterance>.Continuation?

    func start(
        languages: [AppLanguage],
        fallbackLanguage: AppLanguage,
        style: SpeechRecognitionStyle
    ) async throws -> AsyncStream<Utterance> {
        startedLanguages = languages
        startedFallback = fallbackLanguage
        startedStyle = style
        let (stream, continuation) = AsyncStream<Utterance>.makeStream()
        self.continuation = continuation
        return stream
    }

    func stop() async {
        continuation?.finish()
        continuation = nil
    }
}

@MainActor
struct InterpretationViewModelTests {
    @Test("Swap archives live and keeps history")
    func swapDropsLiveKeepsHistory() async {
        let viewModel = makeViewModel()
        let first = Utterance(language: .english, text: "Please silence your phones.", isFinal: true)
        viewModel.accept(first)
        viewModel.fulfill(
            job: TranslationJob(
                utteranceID: first.id,
                source: .english,
                target: .zhHans,
                text: first.text,
                isFinal: true
            ),
            text: "请把手机调成静音。"
        )
        await viewModel.swapDirection()

        #expect(viewModel.sourceLanguage == .zhHans)
        #expect(viewModel.targetLanguage == .english)
        #expect(viewModel.pane.live == nil)
        #expect(viewModel.pane.history.count == 1)
        #expect(viewModel.pane.history.first?.translatedText == "请把手机调成静音。")
    }

    @Test("Voice-out interpretation submits 25/50 ms delays and the current target")
    func voiceOutSubmitsVoiceOutDelaysAndTarget() async {
        let scheduler = ManualTranslationScheduler()
        let viewModel = makeViewModel(targetLanguage: .korean, scheduler: scheduler)
        await viewModel.setVoiceOutEnabled(true)
        let id = UUID()

        viewModel.accept(Utterance(id: id, language: .english, text: "hello world my friend", isFinal: false))
        #expect(scheduler.scheduledDelays == [.milliseconds(25)])

        // Complete the first submission so the next one is a subsequent packet
        // rather than another first packet.
        scheduler.advance(by: .milliseconds(25))

        viewModel.accept(Utterance(id: id, language: .english, text: "hello world my friend again", isFinal: false))
        #expect(scheduler.scheduledDelays == [.milliseconds(25), .milliseconds(50)])

        // The pipeline owns debounce firing; here the submitted job proves the
        // ViewModel passed through the selected target.
        scheduler.advance(by: .milliseconds(50))
        #expect(viewModel.outboundJob?.utteranceID == id)
        #expect(viewModel.outboundJob?.target == .korean)
        #expect(viewModel.outboundJob?.text == "hello world my friend again")
    }

    @Test("Caption-only interpretation submits 40/90 ms delays and the current target")
    func captionsSubmitStandardDelaysAndTarget() {
        let scheduler = ManualTranslationScheduler()
        let viewModel = makeViewModel(targetLanguage: .korean, scheduler: scheduler)
        let id = UUID()

        viewModel.accept(Utterance(id: id, language: .english, text: "hello world my friend", isFinal: false))
        #expect(scheduler.scheduledDelays == [.milliseconds(40)])

        // Complete the first submission so the next one is a subsequent packet
        // rather than another first packet.
        scheduler.advance(by: .milliseconds(40))

        viewModel.accept(Utterance(id: id, language: .english, text: "hello world my friend again", isFinal: false))
        #expect(scheduler.scheduledDelays == [.milliseconds(40), .milliseconds(90)])

        scheduler.advance(by: .milliseconds(90))
        #expect(viewModel.outboundJob?.utteranceID == id)
        #expect(viewModel.outboundJob?.target == .korean)
        #expect(viewModel.outboundJob?.text == "hello world my friend again")
    }

    @Test("Enqueuing a final bumps the host revision")
    func enqueuingFinalBumpsRevision() {
        let viewModel = makeViewModel(scheduler: ManualTranslationScheduler())
        let startRevision = viewModel.outboundRevision

        viewModel.accept(Utterance(language: .english, text: "First line.", isFinal: true))

        #expect(viewModel.outboundRevision > startRevision)
    }

    @Test("Every queued final is handed to the host in order")
    func everyQueuedFinalIsHandedToHost() {
        let viewModel = makeViewModel(scheduler: ManualTranslationScheduler())
        let first = Utterance(language: .english, text: "First line.", isFinal: true)
        let second = Utterance(language: .english, text: "Second line.", isFinal: true)

        viewModel.accept(first)
        viewModel.accept(second)

        #expect(viewModel.takeNextOutboundJob()?.utteranceID == first.id)
        #expect(viewModel.takeNextOutboundJob()?.utteranceID == second.id)
        #expect(viewModel.takeNextOutboundJob() == nil)
    }

    @Test("outboundJob is exposed from the pipeline")
    func outboundJobIsExposedFromPipeline() throws {
        let viewModel = makeViewModel()
        let utterance = Utterance(language: .english, text: "Hello there.", isFinal: false)

        viewModel.accept(utterance)

        let job = try #require(viewModel.outboundJob)
        #expect(job.utteranceID == utterance.id)
        #expect(job.target == .zhHans)
        #expect(job.text == "Hello there.")
    }

    @Test("A late revision final updates one row and re-submits the full text")
    func revisionFinalUpdatesSameRow() {
        let viewModel = makeViewModel()
        let id = UUID()
        viewModel.accept(
            Utterance(id: id, language: .english, text: "They also cause us", isFinal: true)
        )
        #expect(viewModel.transcript.count == 1)

        viewModel.accept(
            Utterance(
                id: id,
                language: .english,
                text: "They also cause us to bump into each other.",
                isFinal: true,
                isRevision: true
            )
        )

        #expect(viewModel.transcript.count == 1)
        #expect(
            viewModel.transcript.first?.sourceText
                == "They also cause us to bump into each other."
        )
        #expect(viewModel.outboundJob?.text == "They also cause us to bump into each other.")
    }

    @Test("A shorter final submission uses the authoritative final text")
    func shorterFinalSubmissionUsesAuthoritativeText() {
        let scheduler = ManualTranslationScheduler()
        let viewModel = makeViewModel(scheduler: scheduler)
        let id = UUID()
        viewModel.accept(
            Utterance(
                id: id,
                language: .english,
                text: "they also cause us to bump into each other",
                isFinal: false
            )
        )
        viewModel.accept(
            Utterance(
                id: id,
                language: .english,
                text: "they also cause us",
                isFinal: true
            )
        )

        #expect(viewModel.outboundJob?.text == "they also cause us")
        #expect(viewModel.transcript.first?.sourceText == "they also cause us")
    }

    @Test("resetCaptions clears the pipeline's pending and outbound work")
    func resetCaptionsClearsPipeline() {
        let scheduler = ManualTranslationScheduler()
        let viewModel = makeViewModel(scheduler: scheduler)

        viewModel.accept(Utterance(language: .english, text: "hello world my friend", isFinal: false))
        #expect(scheduler.pendingDelays == [.milliseconds(40)])

        viewModel.resetCaptions()

        #expect(scheduler.pendingDelays.isEmpty)
        #expect(viewModel.outboundJob == nil)
        scheduler.advance(by: .milliseconds(200))
        #expect(viewModel.outboundJob == nil)
    }

    @Test("A direction change clears the pipeline's pending and outbound work")
    func directionChangeClearsPipeline() async {
        let scheduler = ManualTranslationScheduler()
        let viewModel = makeViewModel(scheduler: scheduler)

        viewModel.accept(Utterance(language: .english, text: "hello world my friend", isFinal: false))
        #expect(scheduler.pendingDelays == [.milliseconds(40)])

        await viewModel.swapDirection()

        #expect(scheduler.pendingDelays.isEmpty)
        #expect(viewModel.outboundJob == nil)
        scheduler.advance(by: .milliseconds(200))
        #expect(viewModel.outboundJob == nil)
    }

    @Test("A new final continuation keeps its own source text and translation job")
    func newFinalContinuationKeepsOwnText() {
        let viewModel = makeViewModel()
        let first = Utterance(
            language: .english,
            text: "Calibration. The Quarterly Engineering Review covered the migration plan.",
            isFinal: true
        )
        viewModel.accept(first)
        let second = Utterance(
            language: .english,
            text: "The translation pipeline, the speech session gate, the storage degradation policy, and the accessibility audit in considerable detail.",
            isFinal: true
        )
        viewModel.accept(second)
        let thirdID = UUID()
        viewModel.accept(Utterance(id: thirdID, language: .english, text: "And", isFinal: false))
        viewModel.accept(Utterance(id: thirdID, language: .english, text: "And the team", isFinal: false))
        let third = Utterance(
            id: thirdID,
            language: .english,
            text: "And the team agreed to revisit the remaining items next week.",
            isFinal: true
        )
        viewModel.accept(third)

        #expect(viewModel.pane.live?.sourceText.contains("And the team agreed") == true)
        #expect(viewModel.outboundJob?.text.contains("And the team agreed") == true)
    }

    @Test("A growing sentence on one utterance id keeps one line")
    func growingSentenceKeepsOneLine() {
        let viewModel = makeViewModel(scheduler: ManualTranslationScheduler())
        let id = UUID()
        viewModel.accept(Utterance(id: id, language: .english, text: "Like everyone else", isFinal: false))
        let grown = Utterance(
            id: id,
            language: .english,
            text: "Like everyone else, when I started out",
            isFinal: false
        )
        viewModel.accept(grown)

        #expect(viewModel.pane.live?.id == id)
        #expect(viewModel.pane.history.isEmpty)
        #expect(viewModel.transcript.count == 1)

        viewModel.fulfill(
            job: TranslationJob(
                utteranceID: id,
                source: .english,
                target: .zhHans,
                text: grown.text,
                isFinal: false
            ),
            text: "和其他人一样，当我开始"
        )

        #expect(viewModel.pane.live?.translatedText == "和其他人一样，当我开始")
        #expect(viewModel.transcript.first?.translatedText == "和其他人一样，当我开始")
    }

    @Test("A new utterance id gets its own line and its own translation")
    func newIDGetsItsOwnLineAndTranslation() {
        let viewModel = makeViewModel(scheduler: ManualTranslationScheduler())
        let first = Utterance(language: .english, text: "Like everyone else", isFinal: true)
        viewModel.accept(first)
        #expect(viewModel.outboundJob?.utteranceID == first.id)
        let second = Utterance(
            language: .english,
            text: "Like everyone else, when I started out",
            isFinal: true
        )
        viewModel.accept(second)
        #expect(viewModel.outboundJob?.utteranceID == second.id)

        #expect(viewModel.pane.live?.id == second.id)
        #expect(viewModel.pane.history.map(\.id) == [first.id])
        #expect(viewModel.transcript.map(\.id) == [first.id, second.id])

        viewModel.fulfill(
            job: TranslationJob(
                utteranceID: second.id,
                source: .english,
                target: .zhHans,
                text: second.text,
                isFinal: true
            ),
            text: "和其他人一样，当我开始"
        )

        #expect(viewModel.pane.live?.translatedText == "和其他人一样，当我开始")
        #expect(viewModel.pane.history.first?.translatedText.isEmpty == true)
        #expect(
            viewModel.transcript.first(where: { $0.id == second.id })?.translatedText
                == "和其他人一样，当我开始"
        )
    }

    @Test("Voice out cannot enable on speaker-only routes")
    func noHeadphonesCannotEnableVoiceOut() async {
        let audio = MockAudioSession(outputs: [.builtInSpeaker])
        let viewModel = makeViewModel(audioSession: audio)
        await viewModel.setVoiceOutEnabled(true)
        #expect(viewModel.voiceOutEnabled == false)
        #expect(viewModel.isVoiceOutBlocked)
        #expect(viewModel.voiceOutBlockedMessage != nil)
    }

    @Test("Speech queue keeps every settled sentence in order")
    func speechQueueKeepsAllSettledSentences() async throws {
        let synthesizer = MockSpeechSynthesizer()
        synthesizer.holdsUntilReleased = true
        let viewModel = makeViewModel(synthesizer: synthesizer)
        await viewModel.setVoiceOutEnabled(true)

        for text in ["一。", "二。", "三。", "四。"] {
            let utterance = Utterance(language: .english, text: text, isFinal: true)
            viewModel.accept(utterance)
            viewModel.fulfill(
                job: TranslationJob(
                    utteranceID: utterance.id,
                    source: .english,
                    target: .zhHans,
                    text: text,
                    isFinal: true
                ),
                text: text
            )
        }

        try await Task.sleep(for: .milliseconds(30))
        #expect(synthesizer.spoken.first == "一。")
        #expect(viewModel.pendingSpeechCount == 3)

        synthesizer.release()
        try await Task.sleep(for: .milliseconds(30))
        synthesizer.release()
        try await Task.sleep(for: .milliseconds(30))
        synthesizer.release()
        try await Task.sleep(for: .milliseconds(30))
        #expect(synthesizer.spoken == ["一。", "二。", "三。", "四。"])
    }

    @Test("A short follow-up does not drop a longer sentence still waiting to be spoken")
    func shortFollowUpDoesNotDropLongSpeech() async throws {
        let synthesizer = MockSpeechSynthesizer()
        synthesizer.holdsUntilReleased = true
        let viewModel = makeViewModel(synthesizer: synthesizer)
        await viewModel.setVoiceOutEnabled(true)

        let cafe = Utterance(language: .english, text: "Okay I agree to wait at the station", isFinal: true)
        viewModel.accept(cafe)
        viewModel.fulfill(
            job: TranslationJob(
                utteranceID: cafe.id,
                source: .english,
                target: .zhHans,
                text: cafe.text,
                isFinal: true
            ),
            text: "好吧，我同意在车站等大家，然后我们都会在电影前去一家咖啡馆。"
        )
        let okay = Utterance(language: .english, text: "Okay.", isFinal: true)
        viewModel.accept(okay)
        viewModel.fulfill(
            job: TranslationJob(
                utteranceID: okay.id,
                source: .english,
                target: .zhHans,
                text: okay.text,
                isFinal: true
            ),
            text: "好的。"
        )

        try await Task.sleep(for: .milliseconds(30))
        #expect(synthesizer.spoken == ["好吧，我同意在车站等大家，然后我们都会在电影前去一家咖啡馆。"])
        #expect(viewModel.pendingSpeechCount == 1)

        synthesizer.release()
        try await Task.sleep(for: .milliseconds(30))
        #expect(synthesizer.spoken.contains("好的。"))
    }

    @Test("A short follow-up on the same utterance id still speaks the longer sentence")
    func shortRewriteOnSameIDDoesNotCancelLongSpeech() async throws {
        let synthesizer = MockSpeechSynthesizer()
        let viewModel = makeViewModel(synthesizer: synthesizer, speechSettleDelay: .milliseconds(80))
        await viewModel.setVoiceOutEnabled(true)

        let id = UUID()
        viewModel.accept(Utterance(id: id, language: .english, text: "Okay I agree to wait at the station", isFinal: true))
        viewModel.fulfill(
            job: TranslationJob(
                utteranceID: id,
                source: .english,
                target: .zhHans,
                text: "Okay I agree to wait at the station",
                isFinal: true
            ),
            text: "好吧，我同意在车站等大家，然后我们都会在电影前去一家咖啡馆。"
        )
        viewModel.fulfill(
            job: TranslationJob(
                utteranceID: id,
                source: .english,
                target: .zhHans,
                text: "Okay.",
                isFinal: true
            ),
            text: "好的。"
        )

        try await Task.sleep(for: .milliseconds(160))
        #expect(synthesizer.spoken.contains { $0.contains("车站等大家") })
    }

    @Test("A fuller translation does not re-speak the already-read head")
    func growingTranslationSpeaksSuffixOnly() async throws {
        let synthesizer = MockSpeechSynthesizer()
        let viewModel = makeViewModel(synthesizer: synthesizer)
        await viewModel.setVoiceOutEnabled(true)

        let first = Utterance(language: .english, text: "Like everyone else", isFinal: true)
        viewModel.accept(first)
        viewModel.fulfill(
            job: TranslationJob(
                utteranceID: first.id,
                source: .english,
                target: .zhHans,
                text: first.text,
                isFinal: true
            ),
            text: "和其他人一样"
        )
        try await Task.sleep(for: .milliseconds(30))
        #expect(synthesizer.spoken == ["和其他人一样"])

        viewModel.fulfill(
            job: TranslationJob(
                utteranceID: first.id,
                source: .english,
                target: .zhHans,
                text: "Like everyone else, when I started out in this work, I had to examine and understand my own feelings about wealth and money.",
                isFinal: true
            ),
            text: "和其他人一样，当我开始这份工作时，我必须审视和理解自己对财富和金钱的感受。"
        )
        try await Task.sleep(for: .milliseconds(40))
        #expect(synthesizer.spoken.filter { $0.contains("和其他人一样") }.count == 1)
        #expect(synthesizer.spoken.joined().contains("当我开始这份工作时"))
    }

    @Test("A restated sentence on a new utterance id still skips the spoken head")
    func growingTranslationAcrossUtteranceIDsSkipsHead() async throws {
        let synthesizer = MockSpeechSynthesizer()
        let viewModel = makeViewModel(synthesizer: synthesizer)
        await viewModel.setVoiceOutEnabled(true)

        let first = Utterance(language: .english, text: "Like everyone else", isFinal: true)
        viewModel.accept(first)
        viewModel.fulfill(
            job: TranslationJob(
                utteranceID: first.id,
                source: .english,
                target: .zhHans,
                text: first.text,
                isFinal: true
            ),
            text: "和其他人一样"
        )
        try await Task.sleep(for: .milliseconds(30))

        let second = Utterance(
            language: .english,
            text: "Like everyone else, when I started out in this work I had to examine money.",
            isFinal: true
        )
        viewModel.accept(second)
        viewModel.fulfill(
            job: TranslationJob(
                utteranceID: second.id,
                source: .english,
                target: .zhHans,
                text: second.text,
                isFinal: true
            ),
            text: "和其他人一样，当我开始这份工作时，我必须审视金钱。"
        )
        try await Task.sleep(for: .milliseconds(40))
        #expect(synthesizer.spoken.filter { $0.contains("和其他人一样") }.count == 1)
        #expect(synthesizer.spoken.joined().contains("当我开始这份工作时"))
    }

    @Test("Prepended words do not cause the already-read date clause to be spoken again")
    func prependedTranslationSkipsAlreadyReadClause() async throws {
        let synthesizer = MockSpeechSynthesizer()
        let viewModel = makeViewModel(synthesizer: synthesizer)
        await viewModel.setVoiceOutEnabled(true)

        let first = Utterance(language: .english, text: "that was March 18th", isFinal: true)
        viewModel.accept(first)
        viewModel.fulfill(
            job: TranslationJob(
                utteranceID: first.id,
                source: .english,
                target: .zhHans,
                text: first.text,
                isFinal: true
            ),
            text: "那是3月18日"
        )
        try await Task.sleep(for: .milliseconds(30))
        #expect(synthesizer.spoken == ["那是3月18日"])

        let second = Utterance(
            language: .english,
            text: "Yes, that was March 18th, but they changed it to the 15th.",
            isFinal: true
        )
        viewModel.accept(second)
        viewModel.fulfill(
            job: TranslationJob(
                utteranceID: second.id,
                source: .english,
                target: .zhHans,
                text: second.text,
                isFinal: true
            ),
            text: "是的，那是 3月18日，但他们把它改成了 15日。"
        )
        try await Task.sleep(for: .milliseconds(40))
        #expect(synthesizer.spoken.filter { $0.contains("3月18日") }.count == 1)
        #expect(synthesizer.spoken.joined().contains("改成了"))
    }

    @Test("An unmatched partial on a new id does not make the next sentence re-read the head")
    func unmatchedPartialDoesNotWipeSpokenPrefix() async throws {
        let synthesizer = MockSpeechSynthesizer()
        let viewModel = makeViewModel(synthesizer: synthesizer)
        await viewModel.setVoiceOutEnabled(true)

        let first = Utterance(language: .english, text: "Like everyone else", isFinal: true)
        viewModel.accept(first)
        viewModel.fulfill(
            job: TranslationJob(
                utteranceID: first.id,
                source: .english,
                target: .zhHans,
                text: first.text,
                isFinal: true
            ),
            text: "和其他人一样"
        )
        try await Task.sleep(for: .milliseconds(30))

        let second = Utterance(language: .english, text: "when I started out in this work", isFinal: false)
        viewModel.accept(second)
        viewModel.fulfill(
            job: TranslationJob(
                utteranceID: second.id,
                source: .english,
                target: .zhHans,
                text: second.text,
                isFinal: false
            ),
            text: "当我开始这份工作"
        )

        viewModel.fulfill(
            job: TranslationJob(
                utteranceID: second.id,
                source: .english,
                target: .zhHans,
                text: "Like everyone else, when I started out in this work, I had to examine money.",
                isFinal: true
            ),
            text: "和其他人一样，当我开始这份工作时，我必须审视金钱。"
        )
        try await Task.sleep(for: .milliseconds(40))
        #expect(synthesizer.spoken.filter { $0.contains("和其他人一样") }.count == 1)
        #expect(synthesizer.spoken.joined().contains("当我开始这份工作时"))
    }

    @Test("Pause clears the speech queue")
    func pauseClearsSpeechQueue() async {
        let synthesizer = MockSpeechSynthesizer()
        synthesizer.holdsUntilReleased = true
        let viewModel = makeViewModel(synthesizer: synthesizer)
        await viewModel.setVoiceOutEnabled(true)
        let utterance = Utterance(language: .english, text: "Hello.", isFinal: true)
        viewModel.accept(utterance)
        viewModel.fulfill(
            job: TranslationJob(
                utteranceID: utterance.id,
                source: .english,
                target: .zhHans,
                text: utterance.text,
                isFinal: true
            ),
            text: "你好。"
        )
        let second = Utterance(language: .english, text: "Goodbye.", isFinal: true)
        viewModel.accept(second)
        viewModel.fulfill(
            job: TranslationJob(
                utteranceID: second.id,
                source: .english,
                target: .zhHans,
                text: second.text,
                isFinal: true
            ),
            text: "再见。"
        )
        #expect(viewModel.pendingSpeechCount == 1)
        await viewModel.stop()
        #expect(viewModel.pendingSpeechCount == 0)
    }

    @Test("Changing language returns to ready instead of listening")
    func languageChangeReturnsToReady() async {
        let viewModel = makeViewModel()
        viewModel.sessionState = .listening
        await viewModel.setSourceLanguage(.japanese)
        #expect(viewModel.sourceLanguage == .japanese)
        #expect(viewModel.targetLanguage == .zhHans)
        #expect(viewModel.sessionState == .ready)
        #expect(viewModel.pane.live == nil)
    }

    @Test("Utterances that are not the source language are ignored")
    func nonSourceLanguageIsIgnored() {
        let viewModel = makeViewModel()
        viewModel.accept(Utterance(language: .japanese, text: "こんにちは", isFinal: true))
        #expect(viewModel.pane.live == nil)
        viewModel.accept(Utterance(language: .english, text: "Hello there", isFinal: true))
        #expect(viewModel.pane.live?.sourceText == "Hello there")
    }

    @Test("Bootstrap never auto-starts listening")
    func bootstrapDoesNotAutostart() async {
        let viewModel = makeViewModel()
        await viewModel.bootstrap()
        #expect(viewModel.sessionState == .ready)
    }

    @Test("Start asks the speech engine for a single source locale")
    func startUsesSingleSourceLocale() async {
        let speech = RecordingSpeechEngine()
        let viewModel = makeViewModel(speech: speech)
        await viewModel.setSourceLanguage(.japanese)
        await viewModel.beginTask()
        await viewModel.start()
        let languages = await speech.startedLanguages
        let fallback = await speech.startedFallback
        #expect(languages == [.japanese])
        #expect(fallback == .japanese)
        #expect(viewModel.sessionState == .listening)
    }

    @Test("Unplugging headphones turns voice out off")
    func unplugDisablesVoiceOut() async throws {
        let audio = MockAudioSession()
        let viewModel = makeViewModel(audioSession: audio)
        await viewModel.bootstrap()
        await viewModel.setVoiceOutEnabled(true)
        #expect(viewModel.voiceOutEnabled)
        try await Task.sleep(for: .milliseconds(20))
        await audio.emit(AudioRouteSnapshot(outputs: [.builtInSpeaker]))
        try await Task.sleep(for: .milliseconds(400))
        #expect(viewModel.voiceOutEnabled == false)
        #expect(viewModel.isVoiceOutBlocked)
    }

    @Test("Missing synthesis voice leaves captions running")
    func missingVoiceDisablesOnlySpeech() async {
        let synthesizer = MockSpeechSynthesizer()
        synthesizer.hasVoiceResult = false
        let viewModel = makeViewModel(synthesizer: synthesizer)
        await viewModel.setVoiceOutEnabled(true)
        #expect(viewModel.voiceOutEnabled == false)
        #expect(viewModel.voiceOutBlockedMessage != nil)
        viewModel.accept(Utterance(language: .english, text: "Hello", isFinal: true))
        #expect(viewModel.pane.live?.sourceText == "Hello")
    }

    @Test("Growing translations of the same sentence do not stack duplicate captions")
    func growingMovieCaptionDoesNotStackDuplicates() {
        let viewModel = makeViewModel()
        let fragments = [
            "好吧，我们已经",
            "好吧，我们错过了一部叫《幸运》的电影",
            "好吧，我们错过了一部叫《幸运日》的电影，它",
            "好吧，我们错过了一部叫《幸运的日子》的电影，我想看",
            "好吧，我们错过了一部叫《幸运的日子》的电影，我想看，但另一部叫《船》的电影本周上映。"
        ]
        let id = UUID()
        for (index, chinese) in fragments.enumerated() {
            let source = String(repeating: "Well we missed a movie ", count: index + 1)
            viewModel.accept(
                Utterance(id: id, language: .english, text: source, isFinal: index == fragments.count - 1)
            )
            viewModel.fulfill(
                job: TranslationJob(
                    utteranceID: id,
                    source: .english,
                    target: .zhHans,
                    text: source,
                    isFinal: index == fragments.count - 1
                ),
                text: chinese
            )
        }
        #expect(viewModel.pane.history.isEmpty)
        #expect(viewModel.pane.live?.translatedText.contains("幸运的日子") == true)
        #expect(viewModel.pane.live?.translatedText.contains("船") == true)
        let movieMentions = ([viewModel.pane.live?.translatedText].compactMap { $0 } + viewModel.pane.history.map(\.translatedText))
            .filter { $0.contains("幸运") }
        #expect(movieMentions.count == 1)
    }

    @Test("Movie-title revisions on new utterance ids keep separate lines")
    func movieRevisionsOnNewIDsKeepSeparateLines() {
        let viewModel = makeViewModel()
        let fragments = [
            "好吧，我们已经",
            "好吧，我们错过了一部叫《幸运》的电影",
            "好吧，我们错过了一部叫《幸运日》的电影，它",
            "好吧，我们错过了一部叫《幸运的日子》的电影，我想看",
            "好吧，我们错过了一部叫《幸运的日子》的电影，我想看，但另一部叫《船》的电影就在这上面",
            "好吧，我们错过了一部叫《幸运的日子》的电影，我想看，但另一部叫《船》的电影本周上映。"
        ]
        var utterances: [Utterance] = []
        for (index, chinese) in fragments.enumerated() {
            let source: String
            switch index {
            case 0:
                source = "Well we already"
            case 1:
                source = "Well we missed a movie called Lucky"
            case 2:
                source = "Okay we missed a film called Lucky Day it"
            case 3:
                source = "Well we missed a movie called Lucky Days I want to see"
            case 4:
                source = "Well we missed a movie called Lucky Days I want to see but another movie called The Ship is just on top"
            default:
                source = "Well we missed a movie called Lucky Days I want to see but another movie called The Ship is released this week"
            }
            let utterance = Utterance(language: .english, text: source, isFinal: index == fragments.count - 1)
            utterances.append(utterance)
            viewModel.accept(utterance)
            viewModel.fulfill(
                job: TranslationJob(
                    utteranceID: utterance.id,
                    source: .english,
                    target: .zhHans,
                    text: source,
                    isFinal: index == fragments.count - 1
                ),
                text: chinese
            )
        }
        let shown = viewModel.pane.history.map(\.translatedText)
            + [viewModel.pane.live?.translatedText].compactMap { $0 }
        #expect(shown == fragments)
        #expect(viewModel.pane.live?.id == utterances.last?.id)
        #expect(viewModel.pane.history.count == fragments.count - 1)
        #expect(viewModel.transcript.count == fragments.count)
    }

    @Test("Settled refinements wait and are spoken once")
    func settledRefinementsSpeakOnce() async throws {
        let synthesizer = MockSpeechSynthesizer()
        let viewModel = makeViewModel(synthesizer: synthesizer, speechSettleDelay: .milliseconds(80))
        await viewModel.setVoiceOutEnabled(true)

        let fragments = [
            "好吧，我们错过了一部叫《幸运》的电影",
            "好吧，我们错过了一部叫《幸运的日子》的电影，我想看",
            "好吧，我们错过了一部叫《幸运的日子》的电影，我想看，但另一部叫《船》的电影本周上映。"
        ]
        let id = UUID()
        for (index, chinese) in fragments.enumerated() {
            let source = String(repeating: "Well we missed a movie ", count: index + 1)
            viewModel.accept(Utterance(id: id, language: .english, text: source, isFinal: true))
            viewModel.fulfill(
                job: TranslationJob(
                    utteranceID: id,
                    source: .english,
                    target: .zhHans,
                    text: source,
                    isFinal: true
                ),
                text: chinese
            )
        }

        try await Task.sleep(for: .milliseconds(140))
        #expect(synthesizer.spoken.count == 1)
        #expect(synthesizer.spoken[0].contains("幸运的日子"))
        #expect(synthesizer.spoken[0].contains("船"))
        #expect(synthesizer.spoken.filter { $0.contains("我们错过了一部叫") }.count == 1)
    }

    @Test("A second greeting is not dropped from captions")
    func secondGreetingStaysVisible() {
        let viewModel = makeViewModel()
        let jack = Utterance(language: .english, text: "Hi, Jack", isFinal: true)
        viewModel.accept(jack)
        viewModel.fulfill(
            job: TranslationJob(
                utteranceID: jack.id,
                source: .english,
                target: .zhHans,
                text: jack.text,
                isFinal: true
            ),
            text: "嗨，Jack"
        )
        let lucy = Utterance(language: .english, text: "Hi, Lucy", isFinal: true)
        viewModel.accept(lucy)
        viewModel.fulfill(
            job: TranslationJob(
                utteranceID: lucy.id,
                source: .english,
                target: .zhHans,
                text: lucy.text,
                isFinal: true
            ),
            text: "嗨，Lucy"
        )
        let captions = ([viewModel.pane.live?.translatedText].compactMap { $0 } + viewModel.pane.history.map(\.translatedText))
            .joined(separator: " ")
        #expect(captions.contains("Jack"))
        #expect(captions.contains("Lucy"))
    }

    @Test("A longer restatement of the same greeting keeps one caption")
    func concatenatedGreetingsStayOneCaption() {
        let viewModel = makeViewModel()
        let id = UUID()
        viewModel.accept(Utterance(id: id, language: .english, text: "Hi, Jack", isFinal: false))
        viewModel.fulfill(
            job: TranslationJob(
                utteranceID: id,
                source: .english,
                target: .zhHans,
                text: "Hi, Jack",
                isFinal: false
            ),
            text: "嗨，Jack"
        )
        viewModel.accept(Utterance(id: id, language: .english, text: "Hi, Jack Hi, Lucy", isFinal: true))
        viewModel.fulfill(
            job: TranslationJob(
                utteranceID: id,
                source: .english,
                target: .zhHans,
                text: "Hi, Jack Hi, Lucy",
                isFinal: true
            ),
            text: "嗨，Jack。嗨，Lucy"
        )
        #expect(viewModel.pane.history.isEmpty)
        #expect(viewModel.pane.live?.translatedText.contains("Jack") == true)
        #expect(viewModel.pane.live?.translatedText.contains("Lucy") == true)
    }

    @Test("A greeting name swap gets its own row and both names stay visible")
    func greetingNameSwapKeepsBothNames() {
        let viewModel = makeViewModel()
        let first = UUID()
        let second = UUID()
        viewModel.accept(Utterance(id: first, language: .english, text: "Hi, Jack", isFinal: true))
        viewModel.fulfill(
            job: TranslationJob(
                utteranceID: first,
                source: .english,
                target: .zhHans,
                text: "Hi, Jack",
                isFinal: true
            ),
            text: "嗨，Jack"
        )
        // The assembler starts a new id for a name swap; the projection must
        // keep both rows (a same-id final would be a correction, not a swap).
        viewModel.accept(Utterance(id: second, language: .english, text: "Hi, Lucy", isFinal: true))
        viewModel.fulfill(
            job: TranslationJob(
                utteranceID: second,
                source: .english,
                target: .zhHans,
                text: "Hi, Lucy",
                isFinal: true
            ),
            text: "嗨，Lucy"
        )
        let captions = ([viewModel.pane.live?.translatedText].compactMap { $0 } + viewModel.pane.history.map(\.translatedText))
            .joined(separator: " ")
        #expect(captions.contains("Jack"))
        #expect(captions.contains("Lucy"))
    }

    @Test("Ending a task drains a final emitted when the stream stops")
    func endTaskDrainsFinalEmittedOnStop() async throws {
        let store = InMemoryTaskStore()
        let gate = InterpretationFakeGate(log: InterpretationEventLog())
        gate.finalOnStop = Utterance(language: .english, text: "最后一句", isFinal: true)
        let viewModel = makeViewModel(store: store, gate: gate)

        await viewModel.beginTask()
        await viewModel.start()
        let ended = try #require(await viewModel.endTask())

        #expect(ended.entries.contains { $0.sourceText == "最后一句" })
    }

    @Test("A final translation that arrives after endTask is backfilled into the ended task")
    func lateFinalTranslationIsBackfilled() async throws {
        let store = InMemoryTaskStore()
        let viewModel = makeViewModel(store: store)
        await viewModel.beginTask()
        let utterance = Utterance(language: .english, text: "See you at three.", isFinal: true)
        viewModel.accept(utterance)
        let job = try #require(viewModel.outboundJob)
        let ended = try #require(await viewModel.endTask())
        #expect(ended.entries.first?.translatedText == "")

        viewModel.fulfill(job: job, text: "三点见。")
        await viewModel.waitForTranslationBackfill()

        guard case let .value(stored?) = await store.readTask(id: ended.id) else {
            Issue.record("Expected the ended task in the store")
            return
        }
        #expect(stored.entries.first?.translatedText == "三点见。")
    }

    @Test("A final arriving while the end write is in flight is backfilled")
    func finalDuringEndWriteIsBackfilled() async throws {
        let store = ScriptedTaskStore()
        let viewModel = makeViewModel(store: store)
        await viewModel.beginTask()
        viewModel.accept(Utterance(language: .english, text: "See you at three.", isFinal: true))
        let job = try #require(viewModel.outboundJob)
        var fulfilled = false
        store.endHook = {
            guard !fulfilled else { return }
            fulfilled = true
            viewModel.fulfill(job: job, text: "三点见。")
        }

        let ended = try #require(await viewModel.endTask())

        #expect(fulfilled)
        let stored = try #require(await store.task(id: ended.id))
        #expect(stored.entries.first?.translatedText == "三点见。")
    }

    @Test("A preview arriving while the end write is in flight is not backfilled")
    func previewDuringEndWriteIsNotBackfilled() async throws {
        let scheduler = ManualTranslationScheduler()
        let store = ScriptedTaskStore()
        let viewModel = makeViewModel(store: store, scheduler: scheduler)
        await viewModel.beginTask()
        viewModel.accept(
            Utterance(language: .english, text: "hello world my friend", isFinal: false)
        )
        scheduler.advance(by: .milliseconds(40))
        let job = try #require(viewModel.outboundJob)
        #expect(!job.isFinal)
        var fulfilled = false
        store.endHook = {
            guard !fulfilled else { return }
            fulfilled = true
            viewModel.fulfill(job: job, text: "你好世界我的朋友")
        }

        let ended = try #require(await viewModel.endTask())

        #expect(fulfilled)
        let stored = try #require(await store.task(id: ended.id))
        #expect(stored.entries.first?.translatedText == "")
    }

    @Test("A preview translation that arrives after endTask is not backfilled")
    func latePreviewTranslationIsNotBackfilled() async throws {
        let scheduler = ManualTranslationScheduler()
        let store = InMemoryTaskStore()
        let viewModel = makeViewModel(store: store, scheduler: scheduler)
        await viewModel.beginTask()
        viewModel.accept(
            Utterance(language: .english, text: "hello world my friend", isFinal: false)
        )
        scheduler.advance(by: .milliseconds(40))
        let job = try #require(viewModel.outboundJob)
        #expect(!job.isFinal)
        let ended = try #require(await viewModel.endTask())

        viewModel.fulfill(job: job, text: "你好世界我的朋友")
        await viewModel.waitForTranslationBackfill()

        guard case let .value(stored?) = await store.readTask(id: ended.id) else {
            Issue.record("Expected the ended task in the store")
            return
        }
        #expect(stored.entries.first?.translatedText == "")
    }

    @Test("Stopping listening drains a final emitted when the stream stops")
    func stopDrainsFinalEmittedOnStop() async {
        let gate = InterpretationFakeGate(log: InterpretationEventLog())
        gate.finalOnStop = Utterance(language: .english, text: "暂停最后一句", isFinal: true)
        let viewModel = makeViewModel(store: InMemoryTaskStore(), gate: gate)

        await viewModel.beginTask()
        await viewModel.start()
        await viewModel.stop(restoreIdleTimerAfterDelay: false)

        #expect(viewModel.transcript.contains { $0.sourceText == "暂停最后一句" })
    }

    @Test("Beginning a new task drains a final emitted when the old stream stops")
    func beginTaskDrainsFinalEmittedOnStop() async {
        let store = InMemoryTaskStore()
        let gate = InterpretationFakeGate(log: InterpretationEventLog())
        gate.finalOnStop = Utterance(language: .english, text: "旧任务最后一句", isFinal: true)
        let viewModel = makeViewModel(store: store, gate: gate)

        await viewModel.beginTask()
        await viewModel.start()
        await viewModel.beginTask()

        let ended = await store.list(filter: .simultaneous)
        #expect(ended.first?.entries.contains { $0.sourceText == "旧任务最后一句" } == true)
    }

    @Test("Beginning a new task stops the old stream before ending it")
    func beginStopsOldStreamBeforeEnding() async {
        let log = InterpretationEventLog()
        let store = ScriptedTaskStore()
        store.eventSink = { log.record($0) }
        let gate = InterpretationFakeGate(log: log)
        let viewModel = makeViewModel(store: store, gate: gate)

        await viewModel.beginTask()
        await viewModel.start()
        #expect(viewModel.sessionState == .listening)
        viewModel.accept(Utterance(language: .english, text: "旧任务最后一句", isFinal: true))

        await viewModel.beginTask()

        #expect(log.contains("gate-stop"))
        #expect(log.contains("store-end"))
        let stopIndex = log.firstIndex(of: "gate-stop")
        let endIndex = log.firstIndex(of: "store-end")
        #expect(stopIndex != nil && endIndex != nil && stopIndex! < endIndex!)
        #expect(viewModel.transcript.isEmpty)
        let active = await store.base.activeTask(for: .simultaneous)
        #expect(active?.entries.isEmpty == true)
        let ended = await store.base.list(filter: .simultaneous)
        #expect(ended.first?.entries.contains { $0.sourceText == "旧任务最后一句" } == true)
    }

    @Test("An end that cannot be saved keeps the transcript, banner, and out of history")
    func notSavedEndKeepsTranscript() async {
        let store = ScriptedTaskStore()
        let viewModel = makeViewModel(store: store)
        await viewModel.beginTask()
        viewModel.accept(Utterance(language: .english, text: "还没保存的内容", isFinal: true))
        store.endFailure = .saveFailed

        let ended = await viewModel.endTask()

        #expect(ended == nil)
        #expect(viewModel.transcript.map(\.sourceText) == ["还没保存的内容"])
        #expect(viewModel.hasActiveTask)
        #expect(viewModel.isNotSaved)
        #expect(viewModel.sessionState == .paused)
        #expect(viewModel.exportableSession.entries.map(\.sourceText) == ["还没保存的内容"])
        #expect(await store.base.list(filter: .simultaneous).isEmpty)
        #expect(store.endCalls == 1)
    }

    @Test("A failed transcript write raises the not-saved banner")
    func failedWriteShowsNotSavedBanner() async {
        let store = ScriptedTaskStore()
        let viewModel = makeViewModel(store: store)
        await viewModel.beginTask()
        await viewModel.start()
        store.appendFailure = .saveFailed
        viewModel.accept(Utterance(language: .english, text: "写不进存储的一句", isFinal: true))

        await viewModel.stop(restoreIdleTimerAfterDelay: false)

        #expect(viewModel.isNotSaved)
        #expect(viewModel.transcript.map(\.sourceText) == ["写不进存储的一句"])
    }

    @Test("Restoring applies the recorded language pair and shows the continue prompt")
    func restoreAppliesLanguagePairAndPrompt() async throws {
        let store = InMemoryTaskStore()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let title = TaskTitle.make(
            feature: .simultaneous,
            source: .english,
            target: .zhHans,
            startedAt: startedAt,
            language: .zhHans
        )
        let draft = TaskDraft(
            feature: .simultaneous,
            sourceLanguage: .english,
            targetLanguage: .zhHans,
            multilingual: false,
            startedAt: startedAt,
            title: title
        )
        guard case let .persisted(seeded) = await store.startNew(draft) else {
            Issue.record("Could not seed the running task")
            return
        }
        let entry = TranscriptEntry(
            id: UUID(),
            speaker: .peer,
            source: .english,
            sourceText: "Restored line",
            translatedText: "恢复的一句",
            isFinal: true
        )
        _ = await store.append([entry], to: seeded.id)
        _ = await store.setStatus(.pausedListening, for: seeded.id)

        let viewModel = makeViewModel(
            store: store,
            sourceLanguage: .japanese,
            targetLanguage: .korean
        )
        await viewModel.bootstrap()

        #expect(viewModel.sourceLanguage == .english)
        #expect(viewModel.targetLanguage == .zhHans)
        #expect(viewModel.hasActiveTask)
        #expect(viewModel.transcript.map(\.sourceText) == ["Restored line"])
        #expect(viewModel.pane.history.count == 1)
        #expect(viewModel.resumePromptText?.contains("继续任务") == true)
        #expect(viewModel.resumePromptText?.contains(title) == true)
        #expect(viewModel.sessionState == .ready)
    }

    @Test("Changing direction stops the stream before clearing the live caption")
    func directionChangeStopsStreamBeforeClearing() async {
        let log = InterpretationEventLog()
        let gate = InterpretationFakeGate(log: log)
        let viewModel = makeViewModel(gate: gate)
        await viewModel.beginTask()
        await viewModel.start()
        viewModel.accept(Utterance(language: .english, text: "Please silence your phones", isFinal: false))
        #expect(viewModel.pane.live != nil)

        await viewModel.swapDirection()

        #expect(gate.stopCount == 1)
        #expect(viewModel.pane.live == nil)
        #expect(viewModel.sessionState == .ready)
        #expect(gate.starts.count == 1)

        viewModel.accept(Utterance(language: .english, text: "old direction line", isFinal: true))
        #expect(viewModel.pane.live == nil)
    }

    @Test("A new interpretation task title follows the interface language")
    func taskTitleUsesInterfaceLanguage() async {
        let englishStore = InMemoryTaskStore()
        let englishViewModel = makeViewModel(
            store: englishStore,
            sourceLanguage: .english,
            targetLanguage: .zhHans,
            userLanguage: .english
        )
        await englishViewModel.beginTask()

        let englishTask = await englishStore.activeTask(for: .simultaneous)
        #expect(englishTask?.title.contains("Simultaneous") == true)
        #expect(englishTask?.title.contains("同声传译") == false)
        #expect(englishTask?.sourceLanguage == .english)
        #expect(englishTask?.targetLanguage == .zhHans)

        let chineseStore = InMemoryTaskStore()
        let chineseViewModel = makeViewModel(
            store: chineseStore,
            sourceLanguage: .zhHans,
            targetLanguage: .english,
            userLanguage: .zhHans
        )
        await chineseViewModel.beginTask()

        let chineseTask = await chineseStore.activeTask(for: .simultaneous)
        #expect(chineseTask?.title.contains("同声传译") == true)
    }

    @Test("Interpretation banner and resume copy follow the interface language, not the target")
    func interfaceCopyUsesInterfaceLanguage() async throws {
        let store = InMemoryTaskStore()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let title = "Restored task"
        let draft = TaskDraft(
            feature: .simultaneous,
            sourceLanguage: .english,
            targetLanguage: .zhHans,
            multilingual: false,
            startedAt: startedAt,
            title: title
        )
        guard case let .persisted(seeded) = await store.startNew(draft) else {
            Issue.record("Could not seed the running task")
            return
        }
        _ = await store.append(
            [
                TranscriptEntry(
                    id: UUID(),
                    speaker: .peer,
                    source: .english,
                    sourceText: "Restored line",
                    translatedText: "恢复的一句",
                    isFinal: true
                )
            ],
            to: seeded.id
        )
        _ = await store.setStatus(.pausedListening, for: seeded.id)

        let viewModel = makeViewModel(
            store: store,
            sourceLanguage: .english,
            targetLanguage: .zhHans,
            userLanguage: .english
        )
        await viewModel.bootstrap()

        #expect(viewModel.interfaceLanguage == .english)
        #expect(viewModel.resumePromptText == "Continue task: \(title)")
        #expect(viewModel.controlLabel == "Tap to start")
        #expect(Copy.notSavedBanner(for: viewModel.interfaceLanguage).contains("won't be saved"))
        #expect(!Copy.notSavedBanner(for: viewModel.interfaceLanguage).contains("不会保存"))
    }

    @Test("A memory-only task with content blocks a new task until the user discards it")
    func unsavedTaskBlocksNewTask() async {
        let store = ScriptedTaskStore()
        store.startNewFailure = .saveFailed
        let viewModel = makeViewModel(store: store)
        await viewModel.beginTask()
        #expect(viewModel.isMemoryOnly)
        #expect(viewModel.isNotSaved)
        viewModel.accept(Utterance(language: .english, text: "唯一的副本", isFinal: true))

        await viewModel.beginTask()

        #expect(viewModel.isUnsavedTaskPromptPresented)
        #expect(viewModel.hasActiveTask)
        #expect(viewModel.transcript.map(\.sourceText) == ["唯一的副本"])
        #expect(store.startNewCalls == 1)

        await viewModel.discardUnsavedTaskAndBegin()

        #expect(!viewModel.isUnsavedTaskPromptPresented)
        #expect(viewModel.transcript.isEmpty)
        #expect(viewModel.hasActiveTask)
        #expect(store.startNewCalls == 2)
    }

    @Test("Export and continue starts a new task after the user continues")
    func exportThenContinueStartsNewTask() async {
        let store = ScriptedTaskStore()
        store.startNewFailure = .saveFailed
        let viewModel = makeViewModel(store: store)
        await viewModel.beginTask()
        viewModel.accept(Utterance(language: .english, text: "唯一的副本", isFinal: true))
        await viewModel.beginTask()
        #expect(viewModel.isUnsavedTaskPromptPresented)

        viewModel.beginExportThenContinue()

        #expect(viewModel.isSummaryPresented)
        #expect(viewModel.isExportThenContinuePending)
        #expect(!viewModel.isUnsavedTaskPromptPresented)

        await viewModel.continueAfterExport()

        #expect(!viewModel.isSummaryPresented)
        #expect(!viewModel.isExportThenContinuePending)
        #expect(viewModel.transcript.isEmpty)
        #expect(viewModel.hasActiveTask)
        #expect(store.startNewCalls == 2)
    }

    @Test("Closing the export summary keeps the memory-only task intact")
    func closingExportSummaryKeepsTask() async {
        let store = ScriptedTaskStore()
        store.startNewFailure = .saveFailed
        let viewModel = makeViewModel(store: store)
        await viewModel.beginTask()
        viewModel.accept(Utterance(language: .english, text: "唯一的副本", isFinal: true))
        await viewModel.beginTask()
        viewModel.beginExportThenContinue()

        viewModel.dismissSummary()

        #expect(!viewModel.isSummaryPresented)
        #expect(!viewModel.isExportThenContinuePending)
        #expect(viewModel.hasActiveTask)
        #expect(viewModel.isMemoryOnly)
        #expect(viewModel.transcript.map(\.sourceText) == ["唯一的副本"])
        #expect(store.startNewCalls == 1)
    }

    @Test("Sixty settled lines stay in the transcript and export while the pane shows the last fifty")
    func longTranscriptKeepsAllSettledLines() async {
        let viewModel = makeViewModel()
        await viewModel.beginTask()
        let utterances = makeUtterances(count: 60)
        for utterance in utterances {
            viewModel.accept(utterance)
        }
        let ids = utterances.map(\.id)

        #expect(viewModel.pane.history.count == InterpretationLayout.historyLimit)
        #expect(viewModel.pane.live?.id == ids.last)
        #expect(viewModel.pane.history.map(\.id) == Array(ids.dropLast().suffix(InterpretationLayout.historyLimit)))
        #expect(viewModel.transcript.count == 60)
        #expect(viewModel.transcript.map(\.id) == ids)
        #expect(viewModel.exportableSession.entries.count == 60)
        #expect(viewModel.exportableSession.entries.first?.sourceText == utterances.first?.text)
        #expect(viewModel.exportableSession.entries.last?.sourceText == utterances.last?.text)
    }

    @Test("Restoring a long task fills the pane with the last fifty entries and keeps the full transcript")
    func restoredLongTaskFillsPaneWindow() async {
        let store = InMemoryTaskStore()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let draft = TaskDraft(
            feature: .simultaneous,
            sourceLanguage: .english,
            targetLanguage: .zhHans,
            multilingual: false,
            startedAt: startedAt,
            title: TaskTitle.make(
                feature: .simultaneous,
                source: .english,
                target: .zhHans,
                startedAt: startedAt,
                language: .zhHans
            )
        )
        guard case let .persisted(seeded) = await store.startNew(draft) else {
            Issue.record("Could not seed the running task")
            return
        }
        let entries = makeUtterances(count: 60).map { utterance in
            TranscriptEntry(
                id: utterance.id,
                speaker: .peer,
                source: .english,
                sourceText: utterance.text,
                translatedText: "",
                isFinal: true
            )
        }
        _ = await store.append(entries, to: seeded.id)
        _ = await store.setStatus(.pausedListening, for: seeded.id)

        let viewModel = makeViewModel(store: store)
        await viewModel.bootstrap()

        #expect(viewModel.transcript.count == 60)
        #expect(viewModel.pane.live == nil)
        #expect(viewModel.pane.history.count == InterpretationLayout.historyLimit)
        #expect(viewModel.pane.history.map(\.id) == Array(entries.suffix(InterpretationLayout.historyLimit).map(\.id)))
        #expect(viewModel.exportableSession.entries.count == 60)
    }

    @Test("Clearing the display flushes pending captions and keeps the task, transcript, and summary")
    func clearDisplayFlushesAndKeepsTaskData() async {
        let store = ScriptedTaskStore()
        let gate = InterpretationFakeGate(log: InterpretationEventLog())
        let viewModel = makeViewModel(store: store, gate: gate)
        await viewModel.beginTask()
        await viewModel.start()
        let utterance = Utterance(
            language: .english,
            text: "Clear me from the screen but keep me in the transcript",
            isFinal: true
        )
        viewModel.accept(utterance)
        #expect(store.appendCalls == 0)
        let summary = ConversationSummary(text: "已保存的总结", usedAppleIntelligence: true)
        viewModel.summary = summary
        viewModel.isSummaryPresented = true

        await viewModel.clearDisplay()

        #expect(store.appendCalls == 1)
        let active = await store.base.activeTask(for: .simultaneous)
        #expect(active?.entries.map(\.sourceText) == [utterance.text])
        #expect(viewModel.pane.history.isEmpty)
        #expect(viewModel.pane.live == nil)
        #expect(viewModel.pane.speakingHint == nil)
        #expect(viewModel.isSummaryPresented == false)
        #expect(viewModel.summary == summary)
        #expect(viewModel.transcript.map(\.sourceText) == [utterance.text])
        #expect(viewModel.exportableSession.entries.count == 1)
        #expect(viewModel.hasActiveTask)
        #expect(viewModel.sessionState == .listening)
        #expect(gate.stopCount == 0)
        #expect(store.endCalls == 0)
    }

    @Test("A translation after a display clear updates the transcript without speaking")
    func translationAfterClearUpdatesTranscriptWithoutSpeech() async {
        let synthesizer = MockSpeechSynthesizer()
        let viewModel = makeViewModel(synthesizer: synthesizer, speechSettleDelay: .milliseconds(0))
        await viewModel.setVoiceOutEnabled(true)
        let utterance = Utterance(language: .english, text: "Clear me now", isFinal: true)
        viewModel.accept(utterance)

        await viewModel.clearDisplay()
        viewModel.fulfill(
            job: TranslationJob(
                utteranceID: utterance.id,
                source: .english,
                target: .zhHans,
                text: utterance.text,
                isFinal: true
            ),
            text: "现在清屏"
        )

        #expect(viewModel.pane.live == nil)
        #expect(viewModel.transcript.first?.translatedText == "现在清屏")
        #expect(synthesizer.spoken.isEmpty)
    }

    @Test("A translation outside the display window updates the transcript without speaking")
    func translationOutsideWindowUpdatesTranscriptWithoutSpeech() async {
        let synthesizer = MockSpeechSynthesizer()
        let viewModel = makeViewModel(synthesizer: synthesizer, speechSettleDelay: .milliseconds(0))
        await viewModel.setVoiceOutEnabled(true)
        let utterances = makeUtterances(count: 60)
        for utterance in utterances {
            viewModel.accept(utterance)
        }
        let evicted = utterances[0]

        viewModel.fulfill(
            job: TranslationJob(
                utteranceID: evicted.id,
                source: .english,
                target: .zhHans,
                text: evicted.text,
                isFinal: true
            ),
            text: "被窗口淘汰的译文"
        )

        #expect(
            viewModel.transcript.first(where: { $0.id == evicted.id })?.translatedText
                == "被窗口淘汰的译文"
        )
        #expect(synthesizer.spoken.isEmpty)
    }

    private func makeUtterances(count: Int) -> [Utterance] {
        (0..<count).map { _ in
            Utterance(
                language: .english,
                text: "\(UUID().uuidString) \(UUID().uuidString)",
                isFinal: true
            )
        }
    }

    private func makeViewModel(
        speech: any SpeechRecognizing = MockSpeechEngine(),
        audioSession: MockAudioSession = MockAudioSession(),
        synthesizer: MockSpeechSynthesizer = MockSpeechSynthesizer(),
        speechSettleDelay: Duration = .milliseconds(0),
        store: any TaskStoreV2 = InMemoryTaskStore(),
        gate: (any SpeechSessionGating)? = nil,
        sourceLanguage: AppLanguage = .english,
        targetLanguage: AppLanguage = .zhHans,
        userLanguage: AppLanguage? = nil,
        scheduler: (any TranslationScheduler)? = nil
    ) -> InterpretationViewModel {
        let preferences = PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString) ?? .standard)
        if let userLanguage {
            preferences.userLanguage = userLanguage
        }
        preferences.sourceLanguage = sourceLanguage
        preferences.targetLanguage = targetLanguage
        preferences.voiceOutEnabled = false
        if let scheduler {
            return InterpretationViewModel(
                gate: gate ?? InterpretationFakeGate(log: InterpretationEventLog()),
                permissions: MockPermissions(),
                preferences: preferences,
                summarizer: MockSummarizer(),
                audioSession: audioSession,
                synthesizer: synthesizer,
                taskStore: store,
                speechSettleDelay: speechSettleDelay,
                scheduler: scheduler
            )
        }
        if let gate {
            return InterpretationViewModel(
                gate: gate,
                permissions: MockPermissions(),
                preferences: preferences,
                summarizer: MockSummarizer(),
                audioSession: audioSession,
                synthesizer: synthesizer,
                taskStore: store,
                speechSettleDelay: speechSettleDelay
            )
        }
        return InterpretationViewModel(
            speech: speech,
            permissions: MockPermissions(),
            preferences: preferences,
            summarizer: MockSummarizer(),
            audioSession: audioSession,
            synthesizer: synthesizer,
            taskStore: store,
            speechSettleDelay: speechSettleDelay
        )
    }
}

@MainActor
private final class InterpretationEventLog {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func contains(_ event: String) -> Bool {
        events.contains(event)
    }

    func firstIndex(of event: String) -> Int? {
        events.firstIndex(of: event)
    }
}

@MainActor
private final class InterpretationFakeGate: SpeechSessionGating {
    private let log: InterpretationEventLog
    private var generation: UInt64 = 0
    private var currentGeneration: UInt64?
    private var continuation: AsyncStream<Utterance>.Continuation?
    private(set) var starts: [FeatureID] = []
    private(set) var stopCount = 0
    var finalOnStop: Utterance?

    init(log: InterpretationEventLog) {
        self.log = log
    }

    func start(
        owner: FeatureID,
        languages: [AppLanguage],
        fallbackLanguage: AppLanguage,
        style: SpeechRecognitionStyle
    ) async throws -> SpeechSessionHandle {
        generation += 1
        let next = generation
        currentGeneration = next
        let (stream, continuation) = AsyncStream<Utterance>.makeStream()
        self.continuation = continuation
        starts.append(owner)
        log.record("gate-start")
        return SpeechSessionHandle(owner: owner, generation: next, stream: stream)
    }

    func stop(_ handle: SpeechSessionHandle) async {
        stopCount += 1
        log.record("gate-stop")
        guard currentGeneration == handle.generation else { return }
        currentGeneration = nil
        if let final = finalOnStop {
            finalOnStop = nil
            continuation?.yield(final)
        }
        continuation?.finish()
        continuation = nil
    }

    func isCurrent(_ handle: SpeechSessionHandle) async -> Bool {
        currentGeneration == handle.generation
    }
}
