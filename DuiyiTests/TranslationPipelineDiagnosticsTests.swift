import Foundation
import Testing
@testable import Duiyi

@MainActor
struct TranslationPipelineDiagnosticsTests {
    private func makeSubmission(
        id: UUID,
        text: String,
        isFinal: Bool,
        language: AppLanguage = .english
    ) -> TranslationSubmission {
        TranslationSubmission(
            line: CaptionLine(id: id, side: .user, source: language, sourceText: text),
            isFinal: isFinal,
            target: .zhHans,
            firstDelay: .milliseconds(40),
            subsequentDelay: .milliseconds(90)
        )
    }

    @Test("A submitted final and its accepted result are counted in the summary")
    func submitAndApplyAreRecorded() throws {
        let recorder = DiagnosticsRecorder()
        recorder.beginSession(feature: .simultaneous, taskID: UUID())
        let pipeline = TranslationPipeline(diagnostics: recorder)
        let utteranceID = UUID()

        pipeline.submit(makeSubmission(id: utteranceID, text: "Hello there.", isFinal: true))
        let job = try #require(pipeline.takeNextOutboundJob())
        let update = try #require(pipeline.accept(job: job, text: "你好。"))

        #expect(update.utteranceID == utteranceID)
        let snapshot = recorder.snapshot()
        #expect(snapshot.summary.translationSubmitCount == 1)
        #expect(snapshot.summary.finalJobCount == 1)
        #expect(snapshot.summary.finalAppliedCount == 1)
        #expect(snapshot.events.map(\.kind) == ["translation.submit", "translation.apply"])
        #expect(snapshot.events.last?.accepted == true)
    }

    @Test("A stale result is recorded as a rejected apply, not a second application")
    func staleResultIsRecordedAsRejected() throws {
        let recorder = DiagnosticsRecorder()
        recorder.beginSession(feature: .faceToFace, taskID: UUID())
        let pipeline = TranslationPipeline(diagnostics: recorder)
        let utteranceID = UUID()

        pipeline.submit(makeSubmission(id: utteranceID, text: "First final.", isFinal: true))
        let first = try #require(pipeline.takeNextOutboundJob())
        pipeline.submit(makeSubmission(id: utteranceID, text: "Second final.", isFinal: true))
        let second = try #require(pipeline.takeNextOutboundJob())

        #expect(pipeline.accept(job: second, text: "第二句。") != nil)
        #expect(pipeline.accept(job: first, text: "第一句。") == nil)

        let snapshot = recorder.snapshot()
        #expect(snapshot.summary.finalAppliedCount == 1)
        let rejected = try #require(snapshot.events.last)
        #expect(rejected.kind == "translation.apply")
        #expect(rejected.accepted == false)
        #expect(rejected.reason == "staleSequence")
    }

    @Test("A short preview never forms a job, so it is not recorded as submitted")
    func droppedPreviewIsNotRecorded() {
        let recorder = DiagnosticsRecorder()
        recorder.beginSession(feature: .simultaneous, taskID: UUID())
        let pipeline = TranslationPipeline(diagnostics: recorder)

        pipeline.submit(makeSubmission(id: UUID(), text: "hi", isFinal: false))

        let snapshot = recorder.snapshot()
        #expect(snapshot.summary.translationSubmitCount == 0)
        #expect(snapshot.events.isEmpty)
    }
}
