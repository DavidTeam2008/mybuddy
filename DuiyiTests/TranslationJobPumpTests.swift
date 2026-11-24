import Foundation
import Testing
@testable import Duiyi

/// Lock-protected record of everything the pump's injected closures observed.
private final class PumpRecorder: @unchecked Sendable {
    struct Success: Equatable {
        let job: TranslationJob
        let text: String
    }

    struct Failure {
        let job: TranslationJob
        let error: any Error
    }

    private let lock = NSLock()
    private var translatedStorage: [String] = []
    private var succeededStorage: [Success] = []
    private var failedStorage: [Failure] = []

    var translatedTexts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return translatedStorage
    }

    var successes: [Success] {
        lock.lock()
        defer { lock.unlock() }
        return succeededStorage
    }

    var failures: [Failure] {
        lock.lock()
        defer { lock.unlock() }
        return failedStorage
    }

    func record(translated text: String) {
        lock.lock()
        defer { lock.unlock() }
        translatedStorage.append(text)
    }

    func record(success job: TranslationJob, text: String) {
        lock.lock()
        defer { lock.unlock() }
        succeededStorage.append(Success(job: job, text: text))
    }

    func record(failure job: TranslationJob, error: any Error) {
        lock.lock()
        defer { lock.unlock() }
        failedStorage.append(Failure(job: job, error: error))
    }
}

private struct TranslationFailure: Error {}

@MainActor
struct TranslationJobPumpTests {
    @Test("A job is translated once and reported through onSuccess")
    func jobTranslationSucceeds() async {
        let recorder = PumpRecorder()
        let job = TranslationJob(
            utteranceID: UUID(),
            source: .english,
            target: .zhHans,
            text: "  hello  ",
            isFinal: true
        )

        let pump = TranslationJobPump(
            translate: { @Sendable text in
                recorder.record(translated: text)
                return "你好"
            },
            onSuccess: { job, text in
                recorder.record(success: job, text: text)
            },
            onFailure: { job, error in
                recorder.record(failure: job, error: error)
            }
        )

        await pump.run(Self.consumer(of: [job]))

        #expect(recorder.translatedTexts == ["hello"])
        #expect(recorder.successes == [PumpRecorder.Success(job: job, text: "你好")])
        #expect(recorder.failures.isEmpty)
    }

    @Test("One wakeup drains every job the consumer still holds")
    func oneWakeupDrainsEveryQueuedJob() async {
        let recorder = PumpRecorder()
        let first = TranslationJob(
            utteranceID: UUID(),
            source: .english,
            target: .zhHans,
            text: "first",
            isFinal: false
        )
        let second = TranslationJob(
            utteranceID: UUID(),
            source: .english,
            target: .zhHans,
            text: "second",
            isFinal: true
        )

        let pump = TranslationJobPump(
            translate: { @Sendable text in
                recorder.record(translated: text)
                return text.uppercased()
            },
            onSuccess: { job, text in
                recorder.record(success: job, text: text)
            },
            onFailure: { job, error in
                recorder.record(failure: job, error: error)
            }
        )

        await pump.run(Self.consumer(of: [first, second]))

        #expect(recorder.translatedTexts == ["first", "second"])
        #expect(
            recorder.successes == [
                PumpRecorder.Success(job: first, text: "FIRST"),
                PumpRecorder.Success(job: second, text: "SECOND"),
            ]
        )
        #expect(recorder.failures.isEmpty)
    }

    @Test("Whitespace-only text is not translated and triggers no callback")
    func whitespaceOnlyTextIsSkipped() async {
        let recorder = PumpRecorder()
        let job = TranslationJob(
            utteranceID: UUID(),
            source: .english,
            target: .zhHans,
            text: " \n\t ",
            isFinal: true
        )

        let pump = TranslationJobPump(
            translate: { @Sendable text in
                recorder.record(translated: text)
                return "unused"
            },
            onSuccess: { job, text in
                recorder.record(success: job, text: text)
            },
            onFailure: { job, error in
                recorder.record(failure: job, error: error)
            }
        )

        await pump.run(Self.consumer(of: [job]))

        #expect(recorder.translatedTexts.isEmpty)
        #expect(recorder.successes.isEmpty)
        #expect(recorder.failures.isEmpty)
    }

    @Test("A failed translation is reported through onFailure and not onSuccess")
    func translationFailureIsReported() async {
        let recorder = PumpRecorder()
        let job = TranslationJob(
            utteranceID: UUID(),
            source: .english,
            target: .zhHans,
            text: "hello",
            isFinal: false
        )

        let pump = TranslationJobPump(
            translate: { @Sendable text in
                recorder.record(translated: text)
                throw TranslationFailure()
            },
            onSuccess: { job, text in
                recorder.record(success: job, text: text)
            },
            onFailure: { job, error in
                recorder.record(failure: job, error: error)
            }
        )

        await pump.run(Self.consumer(of: [job]))

        #expect(recorder.translatedTexts == ["hello"])
        #expect(recorder.successes.isEmpty)
        #expect(recorder.failures.count == 1)
        #expect(recorder.failures.first?.job == job)
        #expect(recorder.failures.first?.error is TranslationFailure)
    }

    /// A consumer with a scripted queue and a stream that finishes after one
    /// wakeup, so the pump returns once the queue is drained.
    private static func consumer(of jobs: [TranslationJob]) -> TranslationJobBridge.Consumer {
        var remaining = jobs
        let (wakeups, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation.yield(())
        continuation.finish()
        return TranslationJobBridge.Consumer(wakeups: wakeups) {
            guard !remaining.isEmpty else { return nil }
            return remaining.removeFirst()
        }
    }
}
