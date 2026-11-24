import Foundation
import Testing
@testable import Duiyi

/// Lock-protected record of everything the pump's injected closures observed.
private final class FakePumpRecorder: @unchecked Sendable {
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

private struct FakeTranslationFailure: Error {}

/// Deterministic gate for an in-flight translation: the test waits until
/// `translate` has started, then resumes it with a chosen result.
private actor FakeTranslateGate {
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

/// Builds a pump whose injected closures record into `recorder`; the optional
/// callbacks run after the record is appended, so tests can observe and then
/// cancel the pump task from its own callback. Call it inside the task that
/// runs the pump: the pump holds non-Sendable closures.
private func makePump(
    recorder: FakePumpRecorder,
    translate: @escaping @Sendable (String) async throws -> String,
    onSuccess: (@MainActor (TranslationJob, String) -> Void)? = nil,
    onFailure: (@MainActor (TranslationJob, any Error) -> Void)? = nil
) -> TranslationJobPump {
    TranslationJobPump(
        translate: { @Sendable text in
            recorder.record(translated: text)
            return try await translate(text)
        },
        onSuccess: { job, text in
            recorder.record(success: job, text: text)
            onSuccess?(job, text)
        },
        onFailure: { job, error in
            recorder.record(failure: job, error: error)
            onFailure?(job, error)
        }
    )
}

/// Builds the pump inside the task (the pump holds non-Sendable closures) and
/// runs it until the test's callback cancels that task.
@MainActor
private func runPump(
    on consumer: TranslationJobBridge.Consumer,
    recorder: FakePumpRecorder,
    translate: @escaping @Sendable (String) async throws -> String,
    onSuccess: (@MainActor (TranslationJob, String) -> Void)? = nil,
    onFailure: (@MainActor (TranslationJob, any Error) -> Void)? = nil
) async {
    let task = Task { @MainActor in
        let pump = makePump(
            recorder: recorder,
            translate: translate,
            onSuccess: onSuccess,
            onFailure: onFailure
        )
        await pump.run(consumer)
    }
    await task.value
}

@MainActor
struct TranslationJobPumpTests {
    @Test("A job is translated once and reported through onSuccess")
    func jobTranslationSucceeds() async {
        let recorder = FakePumpRecorder()
        let bridge = TranslationJobBridge()
        let job = makeTranslationJob(utteranceID: UUID(), text: "  hello  ", isFinal: true)
        bridge.submit(job)

        await runPump(
            on: bridge.makeConsumer(),
            recorder: recorder,
            translate: { @Sendable _ in "你好" },
            onSuccess: { _, _ in withUnsafeCurrentTask { $0?.cancel() } }
        )

        #expect(recorder.translatedTexts == ["hello"])
        #expect(recorder.successes == [FakePumpRecorder.Success(job: job, text: "你好")])
        #expect(recorder.failures.isEmpty)
    }

    @Test("One wakeup drains every job the consumer still holds")
    func oneWakeupDrainsEveryQueuedJob() async {
        let recorder = FakePumpRecorder()
        let bridge = TranslationJobBridge()
        let first = makeTranslationJob(utteranceID: UUID(), text: "first")
        let second = makeTranslationJob(utteranceID: UUID(), text: "second", isFinal: true)
        bridge.submit(first)
        bridge.submit(second)

        await runPump(
            on: bridge.makeConsumer(),
            recorder: recorder,
            translate: { @Sendable text in text.uppercased() },
            onSuccess: { _, _ in
                if recorder.successes.count == 2 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        )

        #expect(recorder.translatedTexts == ["first", "second"])
        #expect(
            recorder.successes == [
                FakePumpRecorder.Success(job: first, text: "FIRST"),
                FakePumpRecorder.Success(job: second, text: "SECOND"),
            ]
        )
        #expect(recorder.failures.isEmpty)
    }

    @Test("A whitespace-only submission never reaches translate")
    func whitespaceOnlySubmissionIsSkippedByBridge() async {
        let recorder = FakePumpRecorder()
        let bridge = TranslationJobBridge()
        bridge.submit(makeTranslationJob(utteranceID: UUID(), text: " \n\t ", isFinal: true))
        let real = makeTranslationJob(utteranceID: UUID(), text: "real", isFinal: true)
        bridge.submit(real)

        await runPump(
            on: bridge.makeConsumer(),
            recorder: recorder,
            translate: { @Sendable text in text.uppercased() },
            onSuccess: { _, _ in withUnsafeCurrentTask { $0?.cancel() } }
        )

        #expect(recorder.translatedTexts == ["real"])
        #expect(recorder.successes == [FakePumpRecorder.Success(job: real, text: "REAL")])
        #expect(recorder.failures.isEmpty)
    }

    @Test("Cancellation between jobs requeues the remaining job and exits")
    func cancellationBetweenJobsRequeuesRemaining() async {
        let recorder = FakePumpRecorder()
        let bridge = TranslationJobBridge()
        let first = makeTranslationJob(utteranceID: UUID(), text: "first", isFinal: true)
        let second = makeTranslationJob(utteranceID: UUID(), text: "second", isFinal: true)
        bridge.submit(first)
        bridge.submit(second)

        await runPump(
            on: bridge.makeConsumer(),
            recorder: recorder,
            translate: { @Sendable text in text.uppercased() },
            onSuccess: { _, _ in
                if recorder.successes.count == 1 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        )

        #expect(recorder.translatedTexts == ["first"])
        #expect(recorder.successes.map(\.job) == [first])
        #expect(recorder.failures.isEmpty)

        let nextConsumer = bridge.makeConsumer()
        #expect(nextConsumer.takeNext() == second)
        #expect(nextConsumer.takeNext() == nil)
    }

    @Test("Cancellation during an in-flight translation requeues it without onFailure")
    func cancellationDuringTranslationRequeuesWithoutFailure() async {
        let recorder = FakePumpRecorder()
        let bridge = TranslationJobBridge()
        let job = makeTranslationJob(utteranceID: UUID(), text: "hello", isFinal: true)
        bridge.submit(job)
        let gate = FakeTranslateGate()

        let task = Task { @MainActor in
            let pump = makePump(
                recorder: recorder,
                translate: { @Sendable _ in try await gate.translate().get() }
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

    @Test("An in-flight translation that succeeds after cancellation is still reported")
    func inFlightSuccessAfterCancellationIsReported() async {
        let recorder = FakePumpRecorder()
        let bridge = TranslationJobBridge()
        let first = makeTranslationJob(utteranceID: UUID(), text: "first", isFinal: true)
        let second = makeTranslationJob(utteranceID: UUID(), text: "second", isFinal: true)
        bridge.submit(first)
        bridge.submit(second)
        let gate = FakeTranslateGate()

        let task = Task { @MainActor in
            let pump = makePump(
                recorder: recorder,
                translate: { @Sendable _ in try await gate.translate().get() }
            )
            await pump.run(bridge.makeConsumer())
        }

        await gate.waitForTranslationToStart()
        task.cancel()
        await gate.resume(with: .success("FIRST"))
        await task.value

        #expect(recorder.translatedTexts == ["first"])
        #expect(recorder.successes == [FakePumpRecorder.Success(job: first, text: "FIRST")])
        #expect(recorder.failures.isEmpty)

        let nextConsumer = bridge.makeConsumer()
        #expect(nextConsumer.takeNext() == second)
        #expect(nextConsumer.takeNext() == nil)
    }

    @Test("A newer job for the same utterance survives a cancelled in-flight translation")
    func newerSameUtteranceJobSurvivesCancellation() async {
        let recorder = FakePumpRecorder()
        let bridge = TranslationJobBridge()
        let utteranceID = UUID()
        let original = makeTranslationJob(utteranceID: utteranceID, text: "old")
        let newer = makeTranslationJob(utteranceID: utteranceID, text: "new", isFinal: true)
        bridge.submit(original)
        let gate = FakeTranslateGate()

        let task = Task { @MainActor in
            let pump = makePump(
                recorder: recorder,
                translate: { @Sendable _ in try await gate.translate().get() }
            )
            await pump.run(bridge.makeConsumer())
        }

        await gate.waitForTranslationToStart()
        bridge.submit(newer)
        task.cancel()
        await gate.resume(with: .failure(CancellationError()))
        await task.value

        #expect(recorder.translatedTexts == ["old"])
        #expect(recorder.successes.isEmpty)
        #expect(recorder.failures.isEmpty)

        let nextConsumer = bridge.makeConsumer()
        #expect(nextConsumer.takeNext() == newer)
        #expect(nextConsumer.takeNext() == nil)
    }

    @Test("A CancellationError without task cancellation requeues the job and exits")
    func cancellationErrorWithoutTaskCancellationRequeues() async {
        let recorder = FakePumpRecorder()
        let bridge = TranslationJobBridge()
        let first = makeTranslationJob(utteranceID: UUID(), text: "first")
        let second = makeTranslationJob(utteranceID: UUID(), text: "second", isFinal: true)
        bridge.submit(first)
        bridge.submit(second)

        await runPump(
            on: bridge.makeConsumer(),
            recorder: recorder,
            translate: { @Sendable _ in throw CancellationError() }
        )

        #expect(recorder.translatedTexts == ["first"])
        #expect(recorder.successes.isEmpty)
        #expect(recorder.failures.isEmpty)

        let nextConsumer = bridge.makeConsumer()
        #expect(nextConsumer.takeNext() == first)
        #expect(nextConsumer.takeNext() == second)
        #expect(nextConsumer.takeNext() == nil)
    }

    @Test("A superseded pump cannot requeue a job into the new consumer")
    func supersededPumpCannotRequeueIntoNewConsumer() async {
        let recorder = FakePumpRecorder()
        let bridge = TranslationJobBridge()
        let job = makeTranslationJob(utteranceID: UUID(), text: "hello", isFinal: true)
        bridge.submit(job)
        let gate = FakeTranslateGate()

        let task = Task { @MainActor in
            let pump = makePump(
                recorder: recorder,
                translate: { @Sendable _ in try await gate.translate().get() }
            )
            await pump.run(bridge.makeConsumer())
        }

        await gate.waitForTranslationToStart()
        let currentConsumer = bridge.makeConsumer()
        task.cancel()
        await gate.resume(with: .failure(CancellationError()))
        await task.value

        #expect(recorder.failures.isEmpty)
        #expect(currentConsumer.takeNext() == nil)
    }

    @Test("A new consumer keeps working after the superseded pump exits")
    func newConsumerKeepsWorkingAfterSupersededPumpExits() async {
        let recorder = FakePumpRecorder()
        let bridge = TranslationJobBridge()
        let supersededConsumer = bridge.makeConsumer()

        let staleTask = Task { @MainActor in
            let pump = makePump(
                recorder: recorder,
                translate: { @Sendable text in text.uppercased() }
            )
            await pump.run(supersededConsumer)
        }

        let currentConsumer = bridge.makeConsumer()
        let job = makeTranslationJob(utteranceID: UUID(), text: "hello", isFinal: true)
        bridge.submit(job)
        await staleTask.value

        #expect(recorder.translatedTexts.isEmpty)

        let task = Task { @MainActor in
            let pump = makePump(
                recorder: recorder,
                translate: { @Sendable text in text.uppercased() },
                onSuccess: { _, _ in withUnsafeCurrentTask { $0?.cancel() } }
            )
            await pump.run(currentConsumer)
        }
        await task.value

        #expect(recorder.translatedTexts == ["hello"])
        #expect(recorder.successes == [FakePumpRecorder.Success(job: job, text: "HELLO")])
        #expect(recorder.failures.isEmpty)
    }

    @Test("A failed translation is reported through onFailure and not onSuccess")
    func translationFailureIsReported() async {
        let recorder = FakePumpRecorder()
        let bridge = TranslationJobBridge()
        let job = makeTranslationJob(utteranceID: UUID(), text: "hello")
        bridge.submit(job)

        await runPump(
            on: bridge.makeConsumer(),
            recorder: recorder,
            translate: { @Sendable _ in throw FakeTranslationFailure() },
            onFailure: { _, _ in withUnsafeCurrentTask { $0?.cancel() } }
        )

        #expect(recorder.translatedTexts == ["hello"])
        #expect(recorder.successes.isEmpty)
        #expect(recorder.failures.count == 1)
        #expect(recorder.failures.first?.job == job)
        #expect(recorder.failures.first?.error is FakeTranslationFailure)
    }
}
