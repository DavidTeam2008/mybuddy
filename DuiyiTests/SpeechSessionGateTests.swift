import Foundation
import Testing
@testable import Duiyi

/// Fake engine for the gate seam. Records every start/stop call and keeps one
/// stream per session so teardown counts can be asserted per session.
actor SpeechSessionGateFakeEngine: SpeechRecognizing {
    struct StartCall: Equatable, Sendable {
        let languages: [AppLanguage]
        let fallbackLanguage: AppLanguage
        let style: SpeechRecognitionStyle
    }

    private final class SessionRecord {
        var continuation: AsyncStream<Utterance>.Continuation?
        var stopCount = 0
        var isFinished = false
    }

    private(set) var startCalls: [StartCall] = []
    private(set) var startAttemptCount = 0
    private(set) var stopWithoutSessionCount = 0
    private var sessions: [SessionRecord] = []
    private var activeSession: SessionRecord?
    private var nextStartError: (any Error)?

    func failNextStart(with error: any Error) {
        nextStartError = error
    }

    func start(
        languages: [AppLanguage],
        fallbackLanguage: AppLanguage,
        style: SpeechRecognitionStyle
    ) async throws -> AsyncStream<Utterance> {
        startAttemptCount += 1
        if let error = nextStartError {
            nextStartError = nil
            throw error
        }
        startCalls.append(
            StartCall(languages: languages, fallbackLanguage: fallbackLanguage, style: style)
        )
        let (stream, continuation) = AsyncStream<Utterance>.makeStream()
        let record = SessionRecord()
        record.continuation = continuation
        sessions.append(record)
        activeSession = record
        return stream
    }

    func stop() async {
        guard let session = activeSession else {
            stopWithoutSessionCount += 1
            return
        }
        activeSession = nil
        session.stopCount += 1
        finish(session)
    }

    /// Ends the active stream the way an engine failure would: without the
    /// gate asking for a stop.
    func failActiveStream() {
        guard let session = activeSession else { return }
        finish(session)
    }

    func emit(_ utterance: Utterance) {
        activeSession?.continuation?.yield(utterance)
    }

    var sessionCount: Int { sessions.count }
    var stopCounts: [Int] { sessions.map(\.stopCount) }
    var finishedFlags: [Bool] { sessions.map(\.isFinished) }
    var activeSessionIndex: Int? {
        guard let activeSession else { return nil }
        return sessions.firstIndex { $0 === activeSession }
    }

    private func finish(_ session: SessionRecord) {
        session.isFinished = true
        session.continuation?.finish()
        session.continuation = nil
    }
}

struct SpeechSessionGateTests {
    @Test("Start returns a handle carrying the owner, first generation, and engine stream")
    func startReturnsHandleWithOwnerGenerationAndStream() async throws {
        let engine = SpeechSessionGateFakeEngine()
        let gate = SpeechSessionGate(engine: engine)

        let handle = try await gate.start(
            owner: .faceToFace,
            languages: [.zhHans, .english],
            fallbackLanguage: .english,
            style: .liveCaptions
        )

        #expect(handle.owner == .faceToFace)
        #expect(handle.generation == 1)
        #expect(await gate.isCurrent(handle))
        let calls = await engine.startCalls
        #expect(calls.count == 1)
        #expect(calls.first?.languages == [.zhHans, .english])
        #expect(calls.first?.fallbackLanguage == .english)
        #expect(calls.first?.style == .liveCaptions)

        let utterance = Utterance(language: .english, text: "See you at three", isFinal: true)
        await engine.emit(utterance)
        var iterator = handle.stream.makeAsyncIterator()
        #expect(await iterator.next() == utterance)
    }

    @Test("Starting a new owner stops the old stream once and stale stop cannot touch the new one")
    func newOwnerSupersedesOldSession() async throws {
        let engine = SpeechSessionGateFakeEngine()
        let gate = SpeechSessionGate(engine: engine)
        let first = try await gate.start(
            owner: .faceToFace,
            languages: [.zhHans, .english],
            fallbackLanguage: .english,
            style: .liveCaptions
        )
        let second = try await gate.start(
            owner: .simultaneous,
            languages: [.zhHans, .english],
            fallbackLanguage: .english,
            style: .liveCaptions
        )

        #expect(first.generation == 1)
        #expect(second.generation == 2)
        #expect(await gate.isCurrent(first) == false)
        #expect(await gate.isCurrent(second))
        var stopCounts = await engine.stopCounts
        #expect(stopCounts == [1, 0])
        var finished = await engine.finishedFlags
        #expect(finished == [true, false])
        #expect(await engine.activeSessionIndex == 1)

        await gate.stop(first)

        stopCounts = await engine.stopCounts
        #expect(stopCounts == [1, 0])
        #expect(await gate.isCurrent(second))
        #expect(await engine.activeSessionIndex == 1)
        finished = await engine.finishedFlags
        #expect(finished == [true, false])

        let utterance = Utterance(language: .english, text: "Still listening", isFinal: false)
        await engine.emit(utterance)
        var iterator = second.stream.makeAsyncIterator()
        #expect(await iterator.next() == utterance)
    }

    @Test("Stopping the current handle tears down once and repeating the stop is a no-op")
    func currentStopIsIdempotent() async throws {
        let engine = SpeechSessionGateFakeEngine()
        let gate = SpeechSessionGate(engine: engine)
        let first = try await gate.start(
            owner: .meeting,
            languages: [.zhHans],
            fallbackLanguage: .zhHans,
            style: .meetingNotes
        )

        await gate.stop(first)
        #expect(await gate.isCurrent(first) == false)
        var stopCounts = await engine.stopCounts
        var finished = await engine.finishedFlags
        #expect(stopCounts == [1])
        #expect(finished == [true])

        await gate.stop(first)
        stopCounts = await engine.stopCounts
        finished = await engine.finishedFlags
        #expect(stopCounts == [1])
        #expect(finished == [true])
        #expect(await engine.stopWithoutSessionCount == 0)

        let second = try await gate.start(
            owner: .faceToFace,
            languages: [.zhHans, .english],
            fallbackLanguage: .english,
            style: .liveCaptions
        )
        #expect(second.generation == 2)
        #expect(await gate.isCurrent(second))
        #expect(await engine.stopCounts == [1, 0])
    }

    @Test("Restarting the same owner issues a new generation and invalidates the old handle")
    func sameOwnerRestartAdvancesGeneration() async throws {
        let engine = SpeechSessionGateFakeEngine()
        let gate = SpeechSessionGate(engine: engine)
        let first = try await gate.start(
            owner: .meeting,
            languages: [.zhHans],
            fallbackLanguage: .zhHans,
            style: .meetingNotes
        )
        let second = try await gate.start(
            owner: .meeting,
            languages: [.zhHans],
            fallbackLanguage: .zhHans,
            style: .meetingNotes
        )

        #expect(first.generation == 1)
        #expect(second.generation == 2)
        #expect(await gate.isCurrent(first) == false)
        #expect(await gate.isCurrent(second))
        #expect(await engine.stopCounts == [1, 0])
        #expect(await engine.finishedFlags == [true, false])

        await gate.stop(first)
        #expect(await engine.stopCounts == [1, 0])
        #expect(await gate.isCurrent(second))
    }

    @Test("A failed start only errors the new owner and leaves the old owner stopped, not failed")
    func failedStartDoesNotErrorPreviousOwner() async throws {
        let engine = SpeechSessionGateFakeEngine()
        let gate = SpeechSessionGate(engine: engine)
        let previous = try await gate.start(
            owner: .faceToFace,
            languages: [.zhHans, .english],
            fallbackLanguage: .english,
            style: .liveCaptions
        )
        await engine.failNextStart(with: DuiyiError.deviceIncapable)

        do {
            _ = try await gate.start(
                owner: .simultaneous,
                languages: [.zhHans, .english],
                fallbackLanguage: .english,
                style: .liveCaptions
            )
            Issue.record("Expected the new owner's start to throw")
        } catch {
            #expect(error as? DuiyiError == .deviceIncapable)
        }

        #expect(await gate.isCurrent(previous) == false)
        #expect(await engine.stopCounts == [1])
        #expect(await engine.finishedFlags == [true])
        #expect(await engine.startAttemptCount == 2)
        #expect(await engine.stopWithoutSessionCount == 0)

        let recovered = try await gate.start(
            owner: .meeting,
            languages: [.zhHans],
            fallbackLanguage: .zhHans,
            style: .meetingNotes
        )
        #expect(recovered.generation == 3)
        #expect(await gate.isCurrent(recovered))
        #expect(await engine.startAttemptCount == 3)
        #expect(await engine.startCalls.count == 2)
    }

    @Test("Only a current stream ending without stop is an interruption; a superseded end is silent")
    func supersededEndIsNotRecognitionInterrupted() async throws {
        let engine = SpeechSessionGateFakeEngine()
        let gate = SpeechSessionGate(engine: engine)
        let superseded = try await gate.start(
            owner: .faceToFace,
            languages: [.zhHans, .english],
            fallbackLanguage: .english,
            style: .liveCaptions
        )
        let current = try await gate.start(
            owner: .simultaneous,
            languages: [.zhHans, .english],
            fallbackLanguage: .english,
            style: .liveCaptions
        )

        // The old owner's stream ended because it was replaced: still not current.
        #expect(await gate.isCurrent(superseded) == false)
        // The new owner's stream is alive: still current.
        #expect(await gate.isCurrent(current))

        await engine.failActiveStream()

        // An unexpected end of the current stream is a real interruption.
        #expect(await gate.isCurrent(current))
        #expect(await engine.stopCounts == [1, 0])
        #expect(await engine.finishedFlags == [true, true])
    }

    @Test("Twenty rapid module switches keep one current session and tear down every old one once")
    func rapidModuleSwitches() async throws {
        let engine = SpeechSessionGateFakeEngine()
        let gate = SpeechSessionGate(engine: engine)
        let owners: [FeatureID] = [.faceToFace, .simultaneous, .meeting]
        var handles: [SpeechSessionHandle] = []

        for index in 0..<20 {
            let handle = try await gate.start(
                owner: owners[index % owners.count],
                languages: [.zhHans, .english],
                fallbackLanguage: .english,
                style: index.isMultiple(of: 2) ? .liveCaptions : .meetingNotes
            )
            handles.append(handle)
        }

        #expect(handles.map(\.generation) == (1...20).map(UInt64.init))
        for (index, handle) in handles.enumerated() {
            #expect(await gate.isCurrent(handle) == (index == 19))
        }
        #expect(await engine.startCalls.count == 20)
        #expect(await engine.stopCounts == Array(repeating: 1, count: 19) + [0])
        #expect(await engine.finishedFlags == Array(repeating: true, count: 19) + [false])
        #expect(await engine.stopWithoutSessionCount == 0)
        #expect(await engine.activeSessionIndex == 19)

        await gate.stop(handles[19])
        #expect(await gate.isCurrent(handles[19]) == false)
        #expect(await engine.stopCounts == Array(repeating: 1, count: 20))
        #expect(await engine.stopWithoutSessionCount == 0)
    }

    @Test("Ten background and foreground cycles stop each session exactly once and eat stale stops")
    func backgroundForegroundCycles() async throws {
        let engine = SpeechSessionGateFakeEngine()
        let gate = SpeechSessionGate(engine: engine)
        var handles: [SpeechSessionHandle] = []
        var previous: SpeechSessionHandle?

        for _ in 0..<10 {
            let handle = try await gate.start(
                owner: .meeting,
                languages: [.zhHans],
                fallbackLanguage: .zhHans,
                style: .meetingNotes
            )
            // Background: a previous module's stale stop arrives first, then
            // the module that actually owns the stream stops it.
            if let previous {
                await gate.stop(previous)
            }
            await gate.stop(handle)
            #expect(await gate.isCurrent(handle) == false)
            handles.append(handle)
            previous = handle
        }

        #expect(handles.map(\.generation) == (1...10).map(UInt64.init))
        #expect(await engine.startCalls.count == 10)
        #expect(await engine.stopCounts == Array(repeating: 1, count: 10))
        #expect(await engine.finishedFlags == Array(repeating: true, count: 10))
        #expect(await engine.stopWithoutSessionCount == 0)
        #expect(await engine.activeSessionIndex == nil)
    }

    @Test("Twenty concurrent starts serialize without deadlock and leave exactly one current session")
    func concurrentStartsSerialize() async throws {
        let engine = SpeechSessionGateFakeEngine()
        let gate = SpeechSessionGate(engine: engine)
        let owners: [FeatureID] = [.faceToFace, .simultaneous, .meeting]

        let handles = try await withThrowingTaskGroup(of: SpeechSessionHandle.self) { group in
            for index in 0..<20 {
                group.addTask {
                    try await gate.start(
                        owner: owners[index % owners.count],
                        languages: [.zhHans, .english],
                        fallbackLanguage: .english,
                        style: .liveCaptions
                    )
                }
            }
            var collected: [SpeechSessionHandle] = []
            for try await handle in group {
                collected.append(handle)
            }
            return collected
        }

        #expect(handles.count == 20)
        #expect(handles.map(\.generation).sorted() == (1...20).map(UInt64.init))
        var currentHandle: SpeechSessionHandle?
        for handle in handles {
            if await gate.isCurrent(handle) {
                #expect(currentHandle == nil)
                currentHandle = handle
            }
        }
        #expect(currentHandle?.generation == 20)
        #expect(await engine.startCalls.count == 20)
        #expect(await engine.stopCounts.dropLast().allSatisfy { $0 == 1 })
        #expect(await engine.stopCounts.last == 0)
        #expect(await engine.stopWithoutSessionCount == 0)
        #expect(await engine.activeSessionIndex == 19)
    }
}
