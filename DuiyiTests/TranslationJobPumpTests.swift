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

/// Deterministic gate for an in-flight translation: the test waits until
/// `translate` has started, then resumes it with a chosen result.
private actor TranslateGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingResult: Result<String, any Error>?
    private var resultWaiter: CheckedContinuation<Result<String, any Error>, Never>?

    func waitForTranslationToStart() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func translate() async -> Result<String, any Error> {
        started = true
        let waiters = startWaiters
        startWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
        return await withCheckedContinuation { continuation in
            if let pendingResult {
                self.pendingResult = nil
                continuation.resume(returning: pendingResult)
            } else {
                resultWaiter = continuation
            }
        }
    }

    func resume(with result: Result<String, any Error>) {
        if let waiter = resultWaiter {
            resultWaiter = nil
            waiter.resume(returning: result)
        } else {
            pendingResult = result
        }
    }
}

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

    @Test("Cancellation between jobs requeues the remaining job and exits")
    func cancellationBetweenJobsRequeuesRemaining() async {
        let recorder = PumpRecorder()
        let bridge = TranslationJobBridge()
        let first = TranslationJob(
            utteranceID: UUID(),
            source: .english,
            target: .zhHans,
            text: "first",
            isFinal: true
        )
        let second = TranslationJob(
            utteranceID: UUID(),
            source: .english,
            target: .zhHans,
            text: "second",
            isFinal: true
        )
        bridge.submit(first)
        bridge.submit(second)

        let task = Task { @MainActor in
            let pump = TranslationJobPump(
                translate: { @Sendable text in
                    recorder.record(translated: text)
                    return text.uppercased()
                },
                onSuccess: { job, text in
                    recorder.record(success: job, text: text)
                    if recorder.successes.count == 1 {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                },
                onFailure: { job, error in
                    recorder.record(failure: job, error: error)
                }
            )
            await pump.run(bridge.makeConsumer())
        }
        await task.value

        #expect(recorder.translatedTexts == ["first"])
        #expect(recorder.successes.map(\.job) == [first])
        #expect(recorder.failures.isEmpty)

        let nextConsumer = bridge.makeConsumer()
        #expect(nextConsumer.takeNext() == second)
        #expect(nextConsumer.takeNext() == nil)
    }

    @Test("Cancellation during an in-flight translation requeues it without onFailure")
    func cancellationDuringTranslationRequeuesWithoutFailure() async {
        let recorder = PumpRecorder()
        let bridge = TranslationJobBridge()
        let job = TranslationJob(
            utteranceID: UUID(),
            source: .english,
            target: .zhHans,
            text: "hello",
            isFinal: true
        )
        bridge.submit(job)
        let gate = TranslateGate()

        let task = Task { @MainActor in
            let pump = TranslationJobPump(
                translate: { @Sendable text in
                    recorder.record(translated: text)
                    return try await gate.translate().get()
                },
                onSuccess: { job, text in
                    recorder.record(success: job, text: text)
                },
                onFailure: { job, error in
                    recorder.record(failure: job, error: error)
                }
            )
            await pump.run(bridge.makeConsumer())
        }

        await gate.waitForTranslationToStart()
        task.cancel()
        await gate.resume(with: .failure(CancellationError()))
        await task.value

        #expect(recorder.translatedTexts == ["hello"])
        #expect(recorder.successes.isEmpty)
        #expect(recorder.failures.isEmpty)

        let nextConsumer = bridge.makeConsumer()
        #expect(nextConsumer.takeNext() == job)
        #expect(nextConsumer.takeNext() == nil)
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
        let queue = ScriptedJobQueue(jobs)
        let (wakeups, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation.yield(())
        continuation.finish()
        return TranslationJobBridge.Consumer(
            wakeups: wakeups,
            takeNext: { queue.takeNext() },
            requeue: { queue.requeue($0) }
        )
    }
}

private final class ScriptedJobQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [TranslationJob]

    init(_ jobs: [TranslationJob]) {
        self.jobs = jobs
    }

    func takeNext() -> TranslationJob? {
        lock.lock()
        defer { lock.unlock() }
        guard !jobs.isEmpty else { return nil }
        return jobs.removeFirst()
    }

    func requeue(_ job: TranslationJob) {
        lock.lock()
        defer { lock.unlock() }
        guard !jobs.contains(where: { $0.utteranceID == job.utteranceID }) else { return }
        jobs.insert(job, at: 0)
    }
}
