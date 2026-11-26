import Foundation
import Testing
@testable import Duiyi

private final class DiagnosticsTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.date = date
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        date = date.addingTimeInterval(seconds)
        lock.unlock()
    }
}

struct DiagnosticsRecorderTests {
    private func makeASR(
        utteranceID: UUID = UUID(),
        isFinal: Bool = true,
        accepted: Bool = true,
        published: Bool = true,
        textLength: Int = 24
    ) -> ASRDiagnosticsRecord {
        ASRDiagnosticsRecord(
            language: .english,
            textLength: textLength,
            isFinal: isFinal,
            synthetic: false,
            scriptMismatch: false,
            accepted: accepted,
            published: published,
            utteranceID: utteranceID,
            revision: false,
            rangeStartSeconds: 12.5,
            rangeDurationSeconds: 1.25,
            resultsFinalizationTimeSeconds: 13.9,
            style: "liveCaptions"
        )
    }

    @Test("ASR counters count distinct settled utterances and keep the language")
    func summaryCountsASR() throws {
        let recorder = DiagnosticsRecorder()
        recorder.beginSession(feature: .simultaneous, taskID: UUID())
        let utteranceID = UUID()

        recorder.record(makeASR(utteranceID: utteranceID))
        // A revision of the same utterance must not settle it twice.
        recorder.record(makeASR(utteranceID: utteranceID))
        // A volatile or rejected result never counts as settled.
        recorder.record(makeASR(isFinal: false, textLength: 12))
        recorder.record(makeASR(accepted: false, published: false))

        let snapshot = recorder.snapshot()
        #expect(snapshot.summary.settledUtterances == 1)
        #expect(snapshot.summary.asrResultCount == 4)
        let event = try #require(snapshot.events.first)
        #expect(event.language == AppLanguage.english.rawValue)
        #expect(event.rangeStart == 12.5)
        #expect(event.resultsFinalizationTime == 13.9)
    }

    @Test("Translation counters count final jobs, applications, and failures")
    func summaryCountsTranslation() {
        let recorder = DiagnosticsRecorder()
        recorder.beginSession(feature: .simultaneous, taskID: UUID())
        let utteranceID = UUID()
        let jobID = UUID()

        recorder.recordSubmit(
            TranslationSubmitRecord(
                jobID: jobID,
                utteranceID: utteranceID,
                sequence: 1,
                isFinal: true,
                source: .english,
                target: .zhHans,
                sourceLength: 24,
                strategy: "lowLatency",
                sourceHash: DiagnosticsHash.fnv1a("hello world")
            )
        )
        recorder.recordResponse(
            TranslationResponseRecord(
                jobID: jobID,
                utteranceID: utteranceID,
                sequence: 1,
                isFinal: true,
                translatedLength: 20,
                replacementCharacterCount: 0,
                responseSourceLanguage: "en",
                responseTargetLanguage: "zh-Hans",
                retryCount: 0
            )
        )
        recorder.recordApply(
            TranslationApplyRecord(
                jobID: jobID,
                utteranceID: utteranceID,
                sequence: 1,
                isFinal: true,
                applied: true,
                reason: nil,
                translatedLength: 20,
                replacementCharacterCount: 0
            )
        )
        recorder.recordFailure(
            TranslationFailureRecord(
                jobID: UUID(),
                utteranceID: utteranceID,
                sequence: 2,
                isFinal: true,
                failure: "corruptedOutput",
                retryCount: 1
            )
        )

        let snapshot = recorder.snapshot()
        #expect(snapshot.summary.finalJobCount == 1)
        #expect(snapshot.summary.finalAppliedCount == 1)
        #expect(snapshot.summary.permanentFailureCount == 1)
        #expect(snapshot.summary.rejectedCorruptionCount == 1)
        #expect(snapshot.summary.translationSubmitCount == 1)
        #expect(snapshot.summary.translationResponseCount == 1)
        #expect(snapshot.events.map(\.kind) == [
            "translation.submit", "translation.result", "translation.apply",
            "translation.failure"
        ])
        #expect(snapshot.events.first?.sourceHash == DiagnosticsHash.fnv1a("hello world"))
    }

    @Test("The ring buffer keeps the newest events and counts the evicted ones")
    func ringBufferEvictsOldest() {
        let recorder = DiagnosticsRecorder(eventLimit: 3)
        recorder.beginSession(feature: .meeting, taskID: nil)

        for length in 1...5 {
            recorder.record(makeASR(isFinal: false, textLength: length))
        }

        let snapshot = recorder.snapshot()
        #expect(snapshot.events.map(\.textLength) == [3, 4, 5])
        #expect(snapshot.summary.asrResultCount == 5)
        #expect(snapshot.summary.droppedEventCount == 2)
    }

    @Test("Beginning the same active task again keeps its events")
    func beginSessionIsIdempotentForActiveTask() {
        let recorder = DiagnosticsRecorder()
        let taskID = UUID()
        recorder.beginSession(feature: .simultaneous, taskID: taskID)
        recorder.record(makeASR())

        // Module re-entry bootstraps and restores the same active task.
        recorder.beginSession(feature: .simultaneous, taskID: taskID)

        #expect(recorder.snapshot().events.count == 1)
        #expect(recorder.snapshot().summary.asrResultCount == 1)
    }

    @Test("A closed session keeps its events until a new task begins")
    func endSessionRetainsEventsUntilNextSession() throws {
        let recorder = DiagnosticsRecorder()
        let taskID = UUID()
        recorder.beginSession(feature: .faceToFace, taskID: taskID)
        recorder.record(makeASR())
        recorder.record(makeASR())

        recorder.endSession(taskID: taskID)

        let closed = recorder.snapshot()
        let session = try #require(closed.session)
        #expect(session.endedAt != nil)
        #expect(closed.events.count == 2)

        recorder.beginSession(feature: .meeting, taskID: UUID())
        #expect(recorder.snapshot().events.isEmpty)
        #expect(recorder.snapshot().summary.asrResultCount == 0)
    }

    @Test("Ending a session with a different task id is ignored")
    func endSessionIgnoresStaleTaskID() {
        let recorder = DiagnosticsRecorder()
        let taskID = UUID()
        recorder.beginSession(feature: .simultaneous, taskID: taskID)

        recorder.endSession(taskID: UUID())

        #expect(recorder.snapshot().session?.endedAt == nil)
        recorder.endSession(taskID: taskID)
        #expect(recorder.snapshot().session?.endedAt != nil)
    }

    @Test("Submit-to-apply latency is measured for the applied job")
    func applyLatencyIsMeasuredFromSubmit() throws {
        let clock = DiagnosticsTestClock()
        let recorder = DiagnosticsRecorder(now: { clock.now })
        recorder.beginSession(feature: .simultaneous, taskID: UUID())
        let jobID = UUID()
        let utteranceID = UUID()

        recorder.recordSubmit(
            TranslationSubmitRecord(
                jobID: jobID,
                utteranceID: utteranceID,
                sequence: 4,
                isFinal: true,
                source: .english,
                target: .zhHans,
                sourceLength: 30,
                strategy: "lowLatency"
            )
        )
        clock.advance(by: 0.75)
        recorder.recordApply(
            TranslationApplyRecord(
                jobID: jobID,
                utteranceID: utteranceID,
                sequence: 4,
                isFinal: true,
                applied: true,
                reason: nil,
                translatedLength: 22,
                replacementCharacterCount: 0
            )
        )

        let event = try #require(recorder.snapshot().events.last)
        #expect(event.kind == "translation.apply")
        let latency = try #require(event.latencyMilliseconds)
        #expect(abs(latency - 750) < 1)
    }

    @Test("A rejected apply is recorded with its reason and does not count as applied")
    func rejectedApplyIsRecorded() throws {
        let recorder = DiagnosticsRecorder()
        recorder.beginSession(feature: .faceToFace, taskID: UUID())
        let jobID = UUID()
        let utteranceID = UUID()
        recorder.recordSubmit(
            TranslationSubmitRecord(
                jobID: jobID,
                utteranceID: utteranceID,
                sequence: 2,
                isFinal: false,
                source: .english,
                target: .zhHans,
                sourceLength: 30,
                strategy: "lowLatency"
            )
        )
        recorder.recordApply(
            TranslationApplyRecord(
                jobID: jobID,
                utteranceID: utteranceID,
                sequence: 2,
                isFinal: false,
                applied: false,
                reason: "staleSequence",
                translatedLength: 18,
                replacementCharacterCount: 0
            )
        )

        let event = try #require(recorder.snapshot().events.last)
        #expect(event.accepted == false)
        #expect(event.reason == "staleSequence")
        #expect(recorder.snapshot().summary.finalAppliedCount == 0)
    }

    @Test("Export JSON decodes and carries no caption text")
    func exportJSONDecodes() throws {
        let recorder = DiagnosticsRecorder()
        recorder.beginSession(feature: .simultaneous, taskID: UUID())
        recorder.record(makeASR(textLength: 42))

        let data = try #require(recorder.makeExportJSON())
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["schemaVersion"] as? Int == DiagnosticsRecorder.schemaVersion)
        #expect(object["session"] != nil)
        #expect((object["events"] as? [[String: Any]])?.count == 1)
        #expect(object["summary"] != nil)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("\"text\""))
        #expect(text.contains("\"asr.result\""))
    }

    @Test("Export is nil until a session exists")
    func exportRequiresSession() {
        let recorder = DiagnosticsRecorder()
        #expect(recorder.makeExportJSON() == nil)
    }
}
