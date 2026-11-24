import Foundation
import Testing
@testable import Duiyi

@MainActor
private func makeSubmission(
    id: UUID = UUID(),
    text: String,
    language: AppLanguage = .english,
    isFinal: Bool = false,
    target: AppLanguage = .zhHans,
    firstDelay: Duration = .milliseconds(40),
    subsequentDelay: Duration = .milliseconds(90)
) -> TranslationSubmission {
    TranslationSubmission(
        line: CaptionLine(id: id, side: .user, source: language, sourceText: text),
        isFinal: isFinal,
        target: target,
        firstDelay: firstDelay,
        subsequentDelay: subsequentDelay
    )
}

@MainActor
struct TranslationPipelineTests {
    private func makePipeline(
        _ stalePolicy: StalePolicy = .dropShorterNonFinal
    ) -> (TranslationPipeline, ManualTranslationScheduler) {
        let scheduler = ManualTranslationScheduler()
        let pipeline = TranslationPipeline(stalePolicy: stalePolicy, scheduler: scheduler)
        return (pipeline, scheduler)
    }

    @Test("The first volatile packet uses the first delay, later packets use the subsequent delay")
    func firstAndSubsequentDelays() {
        let (pipeline, scheduler) = makePipeline()
        let id = UUID()

        pipeline.submit(makeSubmission(id: id, text: "hello"))
        #expect(pipeline.outboundJob == nil)
        #expect(scheduler.pendingDelays == [.milliseconds(40)])

        scheduler.advance(by: .milliseconds(40))
        #expect(pipeline.outboundJob?.utteranceID == id)
        #expect(pipeline.outboundJob?.text == "hello")
        #expect(pipeline.outboundJob?.target == .zhHans)
        #expect(pipeline.outboundJob?.isFinal == false)

        pipeline.submit(makeSubmission(id: id, text: "helloo"))
        #expect(scheduler.pendingDelays == [.milliseconds(90)])

        scheduler.advance(by: .milliseconds(90))
        #expect(pipeline.outboundJob?.utteranceID == id)
        #expect(pipeline.outboundJob?.text == "helloo")
    }

    @Test("Interpretation 25/50 ms delays pass through unchanged")
    func interpretationDelays() {
        let (pipeline, scheduler) = makePipeline(.dropShorterAny)
        let id = UUID()

        pipeline.submit(
            makeSubmission(
                id: id,
                text: "你",
                language: .zhHans,
                firstDelay: .milliseconds(25),
                subsequentDelay: .milliseconds(50)
            )
        )
        #expect(scheduler.pendingDelays == [.milliseconds(25)])
        scheduler.advance(by: .milliseconds(25))
        #expect(pipeline.outboundJob?.text == "你")

        pipeline.submit(
            makeSubmission(
                id: id,
                text: "你好",
                language: .zhHans,
                firstDelay: .milliseconds(25),
                subsequentDelay: .milliseconds(50)
            )
        )
        #expect(scheduler.pendingDelays == [.milliseconds(50)])
        scheduler.advance(by: .milliseconds(50))
        #expect(pipeline.outboundJob?.text == "你好")
    }

    @Test("A new line cancels the previous line's debounce")
    func newLineCancelsPreviousDebounce() {
        let (pipeline, scheduler) = makePipeline()
        let first = UUID()
        let second = UUID()

        pipeline.submit(makeSubmission(id: first, text: "hello"))
        pipeline.submit(makeSubmission(id: second, text: "world"))
        #expect(scheduler.pendingDelays == [.milliseconds(40)])

        scheduler.advance(by: .milliseconds(40))
        #expect(pipeline.outboundJob?.utteranceID == second)
        #expect(pipeline.outboundJob?.text == "world")
    }

    @Test("Clause-terminating text bypasses the debounce")
    func clauseTerminatorBypassesDebounce() {
        let (pipeline, scheduler) = makePipeline()

        pipeline.submit(makeSubmission(text: "你好。", language: .zhHans))
        #expect(scheduler.pendingDelays.isEmpty)
        #expect(pipeline.outboundJob?.text == "你好。")
    }

    @Test("A final packet bypasses the debounce")
    func finalPacketBypassesDebounce() {
        let (pipeline, scheduler) = makePipeline()

        pipeline.submit(makeSubmission(text: "hey", isFinal: true))
        #expect(scheduler.pendingDelays.isEmpty)
        #expect(pipeline.outboundJob?.text == "hey")
        #expect(pipeline.outboundJob?.isFinal == true)
    }

    @Test("A final packet wins over a pending volatile packet")
    func finalPacketWinsOverPendingVolatile() {
        let (pipeline, scheduler) = makePipeline()
        let volatile = UUID()
        let final = UUID()

        pipeline.submit(makeSubmission(id: volatile, text: "hello"))
        pipeline.submit(makeSubmission(id: final, text: "hey", isFinal: true))
        #expect(scheduler.pendingDelays.isEmpty)
        #expect(pipeline.outboundJob?.utteranceID == final)

        scheduler.advance(by: .milliseconds(100))
        #expect(pipeline.outboundJob?.utteranceID == final)
    }

    @Test("The outbound job is a single slot that new jobs replace")
    func outboundJobIsASingleSlot() {
        let (pipeline, scheduler) = makePipeline()
        let first = UUID()
        let second = UUID()

        pipeline.submit(makeSubmission(id: first, text: "你好。", language: .zhHans))
        let firstJobID = pipeline.outboundJob?.id
        pipeline.submit(makeSubmission(id: second, text: "你好！", language: .zhHans))

        #expect(pipeline.outboundJob?.utteranceID == second)
        #expect(pipeline.outboundJob?.id != firstJobID)
        #expect(scheduler.pendingDelays.isEmpty)
    }

    @Test("Duplicate non-final text is not resubmitted")
    func duplicateNonFinalIsSuppressed() {
        let (pipeline, scheduler) = makePipeline()
        let id = UUID()

        pipeline.submit(makeSubmission(id: id, text: "你好。", language: .zhHans))
        let jobID = pipeline.outboundJob?.id
        pipeline.submit(makeSubmission(id: id, text: "你好。", language: .zhHans))

        #expect(pipeline.outboundJob?.id == jobID)
        #expect(scheduler.pendingDelays.isEmpty)
    }

    @Test("Duplicate non-final text already sent is not resubmitted")
    func duplicateNonFinalAfterSendingIsSuppressed() {
        let (pipeline, scheduler) = makePipeline()
        let id = UUID()

        pipeline.submit(makeSubmission(id: id, text: "hello"))
        scheduler.advance(by: .milliseconds(40))
        let jobID = pipeline.outboundJob?.id

        pipeline.submit(makeSubmission(id: id, text: "hello"))
        #expect(pipeline.outboundJob?.id == jobID)
        #expect(scheduler.pendingDelays.isEmpty)
    }

    @Test("Duplicate final text is still submitted")
    func duplicateFinalIsStillSubmitted() {
        let (pipeline, scheduler) = makePipeline()
        let id = UUID()

        pipeline.submit(makeSubmission(id: id, text: "你好。", language: .zhHans))
        let firstJobID = pipeline.outboundJob?.id
        pipeline.submit(makeSubmission(id: id, text: "你好。", language: .zhHans, isFinal: true))

        #expect(pipeline.outboundJob?.id != firstJobID)
        #expect(pipeline.outboundJob?.isFinal == true)
        #expect(scheduler.pendingDelays.isEmpty)
    }

    @Test("Empty text neither creates nor clears an outbound job")
    func emptyTextDoesNotCreateOrClearJob() {
        let (pipeline, scheduler) = makePipeline()
        let id = UUID()

        pipeline.submit(makeSubmission(text: "   ", isFinal: true))
        #expect(pipeline.outboundJob == nil)
        #expect(scheduler.pendingDelays.isEmpty)

        pipeline.submit(makeSubmission(id: id, text: "你好。", language: .zhHans))
        let job = pipeline.outboundJob
        pipeline.submit(makeSubmission(text: "", isFinal: true))
        #expect(pipeline.outboundJob?.id == job?.id)
    }

    @Test("Empty text does not cancel a pending debounce")
    func emptyTextDoesNotCancelDebounce() {
        let (pipeline, scheduler) = makePipeline()
        let id = UUID()

        pipeline.submit(makeSubmission(id: id, text: "hello"))
        scheduler.advance(by: .milliseconds(20))
        pipeline.submit(makeSubmission(text: "  ", isFinal: true))
        scheduler.advance(by: .milliseconds(20))

        #expect(pipeline.outboundJob?.utteranceID == id)
    }

    @Test("An accepted result carries the job, canonical utterance ID, and trimmed text")
    func acceptedUpdateContents() throws {
        let (pipeline, _) = makePipeline()
        let id = UUID()
        pipeline.submit(makeSubmission(id: id, text: "你好。", language: .zhHans))
        let job = try #require(pipeline.outboundJob)

        let update = try #require(pipeline.accept(job: job, text: "  Hello.  "))
        #expect(update.job == job)
        #expect(update.utteranceID == id)
        #expect(update.translatedText == "Hello.")
        #expect(pipeline.outboundJob == nil)
    }

    @Test("Empty translation text is not accepted and leaves the outbound job alone")
    func emptyTranslationIsDropped() throws {
        let (pipeline, _) = makePipeline()
        pipeline.submit(makeSubmission(text: "你好。", language: .zhHans))
        let job = try #require(pipeline.outboundJob)

        #expect(pipeline.accept(job: job, text: "  \n ") == nil)
        #expect(pipeline.outboundJob?.id == job.id)
    }

    @Test("accept clears only the matching outbound job")
    func acceptClearsOnlyMatchingJob() throws {
        let (pipeline, _) = makePipeline()
        pipeline.submit(makeSubmission(text: "你好。", language: .zhHans))
        let first = try #require(pipeline.outboundJob)
        pipeline.submit(makeSubmission(text: "你好！", language: .zhHans))
        let second = try #require(pipeline.outboundJob)

        #expect(pipeline.accept(job: first, text: "Hi.") != nil)
        #expect(pipeline.outboundJob?.id == second.id)

        #expect(pipeline.accept(job: second, text: "Hello!") != nil)
        #expect(pipeline.outboundJob == nil)
    }

    @Test("fail clears only the matching outbound job")
    func failClearsOnlyMatchingJob() throws {
        let (pipeline, _) = makePipeline()
        pipeline.submit(makeSubmission(text: "你好。", language: .zhHans))
        let first = try #require(pipeline.outboundJob)
        pipeline.submit(makeSubmission(text: "你好！", language: .zhHans))
        let second = try #require(pipeline.outboundJob)

        pipeline.fail(job: first)
        #expect(pipeline.outboundJob?.id == second.id)

        pipeline.fail(job: second)
        #expect(pipeline.outboundJob == nil)
    }

    @Test("Face-to-face keeps a shorter final result but drops a shorter volatile one")
    func dropShorterNonFinalPolicy() {
        let (pipeline, _) = makePipeline(.dropShorterNonFinal)
        let id = UUID()

        let long = TranslationJob(
            utteranceID: id, source: .english, target: .zhHans, text: "hello world", isFinal: false
        )
        #expect(pipeline.accept(job: long, text: "你好世界") != nil)

        let shorterFinal = TranslationJob(
            utteranceID: id, source: .english, target: .zhHans, text: "hello", isFinal: true
        )
        #expect(pipeline.accept(job: shorterFinal, text: "你好") != nil)

        let shorterVolatile = TranslationJob(
            utteranceID: id, source: .english, target: .zhHans, text: "hell", isFinal: false
        )
        #expect(pipeline.accept(job: shorterVolatile, text: "你") == nil)

        let equalVolatile = TranslationJob(
            utteranceID: id, source: .english, target: .zhHans, text: "hello world", isFinal: false
        )
        #expect(pipeline.accept(job: equalVolatile, text: "你好世界") != nil)
    }

    @Test("Interpretation drops any shorter result, including a final one")
    func dropShorterAnyPolicy() {
        let (pipeline, _) = makePipeline(.dropShorterAny)
        let id = UUID()

        let long = TranslationJob(
            utteranceID: id, source: .english, target: .zhHans, text: "hello world", isFinal: true
        )
        #expect(pipeline.accept(job: long, text: "你好世界") != nil)

        let shorterFinal = TranslationJob(
            utteranceID: id, source: .english, target: .zhHans, text: "hello", isFinal: true
        )
        #expect(pipeline.accept(job: shorterFinal, text: "你好") == nil)

        let shorterVolatile = TranslationJob(
            utteranceID: id, source: .english, target: .zhHans, text: "hell", isFinal: false
        )
        #expect(pipeline.accept(job: shorterVolatile, text: "你") == nil)

        let equalVolatile = TranslationJob(
            utteranceID: id, source: .english, target: .zhHans, text: "hello world", isFinal: false
        )
        #expect(pipeline.accept(job: equalVolatile, text: "你好世界") != nil)

        let longerFinal = TranslationJob(
            utteranceID: id, source: .english, target: .zhHans, text: "hello world!!", isFinal: true
        )
        #expect(pipeline.accept(job: longerFinal, text: "你好，世界！！") != nil)
    }

    @Test("A stale result is not accepted and leaves the outbound job alone")
    func staleDoesNotClearOutboundJob() throws {
        let (pipeline, _) = makePipeline(.dropShorterAny)
        let id = UUID()

        let long = TranslationJob(
            utteranceID: id, source: .english, target: .zhHans, text: "hello world", isFinal: false
        )
        #expect(pipeline.accept(job: long, text: "你好世界") != nil)

        pipeline.submit(makeSubmission(id: id, text: "你好。", language: .zhHans))
        let outbound = try #require(pipeline.outboundJob)

        let stale = TranslationJob(
            utteranceID: id, source: .english, target: .zhHans, text: "hello", isFinal: true
        )
        #expect(pipeline.accept(job: stale, text: "你好") == nil)
        #expect(pipeline.outboundJob?.id == outbound.id)
    }

    @Test("An accepted update keeps the job's utterance id")
    func updateKeepsJobID() throws {
        let (pipeline, _) = makePipeline()
        let id = UUID()
        let job = TranslationJob(
            utteranceID: id, source: .english, target: .zhHans, text: "hello", isFinal: true
        )

        let update = try #require(pipeline.accept(job: job, text: "你好"))
        #expect(update.utteranceID == id)
        #expect(update.job == job)
    }

    @Test("reset cancels the debounce and clears the outbound job and sent text")
    func resetClearsSubmissionState() {
        let (pipeline, scheduler) = makePipeline()
        let id = UUID()

        pipeline.submit(makeSubmission(id: id, text: "hello"))
        pipeline.reset()
        #expect(pipeline.outboundJob == nil)
        #expect(scheduler.pendingDelays.isEmpty)

        scheduler.advance(by: .milliseconds(100))
        #expect(pipeline.outboundJob == nil)

        pipeline.submit(makeSubmission(id: id, text: "你好。", language: .zhHans))
        #expect(pipeline.outboundJob?.text == "你好。")
        pipeline.reset()

        pipeline.submit(makeSubmission(id: id, text: "你好。", language: .zhHans))
        #expect(pipeline.outboundJob?.text == "你好。")
    }

    @Test("reset clears stale counts")
    func resetClearsStaleCounts() {
        let (pipeline, _) = makePipeline(.dropShorterAny)
        let id = UUID()
        let long = TranslationJob(
            utteranceID: id, source: .english, target: .zhHans, text: "hello world", isFinal: true
        )
        #expect(pipeline.accept(job: long, text: "你好世界") != nil)

        pipeline.reset()

        let shorter = TranslationJob(
            utteranceID: id, source: .english, target: .zhHans, text: "hello", isFinal: true
        )
        #expect(pipeline.accept(job: shorter, text: "你好") != nil)
    }
}
