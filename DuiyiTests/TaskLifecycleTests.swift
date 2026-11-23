import Foundation
import Testing
@testable import Duiyi

/// Shared ordered log across the fake store, gate, and audio session so tests
/// can assert cross-seam ordering (for example "stop the stream before finish").
@MainActor
private final class LifecycleEventLog {
    enum Event: Equatable {
        case audioActivate(AudioUseCase)
        case gateStart(FeatureID)
        case gateStop(UInt64)
        case storeStartNew
        case storeAppend(UUID)
        case storeSetStatus(TaskStatus)
        case storeEnd(UUID)
        case storeDelete(UUID)
    }

    private(set) var events: [Event] = []

    func record(_ event: Event) {
        events.append(event)
    }

    func firstIndex(of event: Event) -> Int? {
        events.firstIndex(of: event)
    }
}

@MainActor
private final class LifecycleFakeGate: SpeechSessionGating {
    struct Start: Equatable {
        var owner: FeatureID
        var languages: [AppLanguage]
        var fallbackLanguage: AppLanguage
        var style: SpeechRecognitionStyle
    }

    let log: LifecycleEventLog
    private var generation: UInt64 = 0
    private var currentGeneration: UInt64?
    private var continuations: [UInt64: AsyncStream<Utterance>.Continuation] = [:]
    private(set) var starts: [Start] = []
    private(set) var stopCount = 0
    var nextStartError: (any Error)?

    init(log: LifecycleEventLog) {
        self.log = log
    }

    func start(
        owner: FeatureID,
        languages: [AppLanguage],
        fallbackLanguage: AppLanguage,
        style: SpeechRecognitionStyle
    ) async throws -> SpeechSessionHandle {
        log.record(.gateStart(owner))
        if let nextStartError {
            self.nextStartError = nil
            throw nextStartError
        }
        generation += 1
        let next = generation
        if let currentGeneration {
            continuations[currentGeneration]?.finish()
            continuations[currentGeneration] = nil
        }
        let (stream, continuation) = AsyncStream<Utterance>.makeStream()
        continuations[next] = continuation
        currentGeneration = next
        starts.append(
            Start(
                owner: owner,
                languages: languages,
                fallbackLanguage: fallbackLanguage,
                style: style
            )
        )
        return SpeechSessionHandle(owner: owner, generation: next, stream: stream)
    }

    func stop(_ handle: SpeechSessionHandle) async {
        log.record(.gateStop(handle.generation))
        stopCount += 1
        guard currentGeneration == handle.generation else { return }
        currentGeneration = nil
        continuations[handle.generation]?.finish()
        continuations[handle.generation] = nil
    }

    func isCurrent(_ handle: SpeechSessionHandle) async -> Bool {
        currentGeneration == handle.generation
    }

    /// Ends the active stream without a stop, the way an engine failure would.
    func failCurrentStream() {
        guard let currentGeneration else { return }
        continuations[currentGeneration]?.finish()
        continuations[currentGeneration] = nil
    }
}

@MainActor
private final class LifecycleFakeStore: TaskStoreV2 {
    let log: LifecycleEventLog
    let base: InMemoryTaskStore
    var availability: TaskStoreAvailability = .ready
    var startNewFailure: TaskStoreFailureReason?
    var appendFailure: TaskStoreFailureReason?
    var endFailure: TaskStoreFailureReason?
    var setStatusFailure: TaskStoreFailureReason?
    var deleteFailure: TaskStoreFailureReason?
    var readFailure: TaskStoreFailureReason?
    private(set) var appendCount = 0
    private(set) var endCount = 0

    init(log: LifecycleEventLog) {
        self.log = log
        base = InMemoryTaskStore()
    }

    func prepare() async {}
    func retry() async {}

    // MARK: - TaskStoreV2 reads

    func readActiveTask(for feature: FeatureID) async -> TaskStoreReadResult<TaskSession?> {
        if let readFailure { return .unavailable(readFailure) }
        return await base.readActiveTask(for: feature)
    }

    func readUnfinishedTasks() async -> TaskStoreReadResult<[TaskSession]> {
        if let readFailure { return .unavailable(readFailure) }
        return await base.readUnfinishedTasks()
    }

    func readList(filter: FeatureID?) async -> TaskStoreReadResult<[TaskSession]> {
        if let readFailure { return .unavailable(readFailure) }
        return await base.readList(filter: filter)
    }

    func readTask(id: UUID) async -> TaskStoreReadResult<TaskSession?> {
        if let readFailure { return .unavailable(readFailure) }
        return await base.readTask(id: id)
    }

    // MARK: - TaskStoreV2 writes with optional failure injection

    func startNew(_ draft: TaskDraft) async -> TaskStoreWriteResult<TaskSession> {
        log.record(.storeStartNew)
        if let startNewFailure { return .notPersisted(startNewFailure) }
        return await base.startNew(draft)
    }

    func append(_ entries: [TranscriptEntry], to taskID: UUID) async -> TaskStoreWriteOutcome {
        log.record(.storeAppend(taskID))
        appendCount += 1
        if let appendFailure { return .notPersisted(appendFailure) }
        return await base.append(entries, to: taskID)
    }

    func updateTranslations(_ entries: [TranscriptEntry], for taskID: UUID) async -> TaskStoreWriteOutcome {
        if let appendFailure { return .notPersisted(appendFailure) }
        return await base.updateTranslations(entries, for: taskID)
    }

    func setStatus(_ status: TaskStatus, for taskID: UUID) async -> TaskStoreWriteOutcome {
        log.record(.storeSetStatus(status))
        if let setStatusFailure { return .notPersisted(setStatusFailure) }
        return await base.setStatus(status, for: taskID)
    }

    func saveSummary(_ summary: ConversationSummary, for taskID: UUID) async -> TaskStoreWriteOutcome {
        if let appendFailure { return .notPersisted(appendFailure) }
        return await base.saveSummary(summary, for: taskID)
    }

    func end(
        taskID: UUID,
        entries: [TranscriptEntry],
        summary: ConversationSummary?
    ) async -> TaskStoreEndResult {
        log.record(.storeEnd(taskID))
        endCount += 1
        if let endFailure { return .notPersisted(endFailure) }
        return await base.end(taskID: taskID, entries: entries, summary: summary)
    }

    func deleteTask(id: UUID) async -> TaskStoreWriteOutcome {
        log.record(.storeDelete(id))
        if let deleteFailure { return .notPersisted(deleteFailure) }
        return await base.deleteTask(id: id)
    }
}

@MainActor
private final class LifecycleFakePermissions: PermissionGranting {
    var status: PermissionStatus = .granted
    var requestResult: PermissionStatus?
    private(set) var requestCount = 0

    func currentStatus() async -> PermissionStatus {
        status
    }

    func requestAccess() async -> PermissionStatus {
        requestCount += 1
        return requestResult ?? status
    }
}

@MainActor
private final class LifecycleFakeAudioSession: AudioSessionConfiguring {
    let log: LifecycleEventLog
    private(set) var activations: [AudioUseCase] = []
    var activationError: (any Error)?

    init(log: LifecycleEventLog) {
        self.log = log
    }

    func activate(_ useCase: AudioUseCase) async throws {
        log.record(.audioActivate(useCase))
        activations.append(useCase)
        if let activationError { throw activationError }
    }

    func deactivate() async {}

    func currentRoute() async -> AudioRouteSnapshot {
        AudioRouteSnapshot(outputs: [.builtInSpeaker])
    }

    func routeChanges() async -> AsyncStream<AudioRouteSnapshot> {
        AsyncStream { $0.finish() }
    }
}

@MainActor
struct TaskLifecycleTests {
    @Test("Start new task with auto-start activates audio and starts the gate for the feature")
    func autoStartStartsListening() async throws {
        let log = LifecycleEventLog()
        let store = LifecycleFakeStore(log: log)
        let gate = LifecycleFakeGate(log: log)
        let audio = LifecycleFakeAudioSession(log: log)
        let lifecycle = makeLifecycle(store: store, gate: gate, audio: audio)

        let outcome = await lifecycle.startNewTask(makeRequest(autoStart: true))

        guard case let .started(handle) = outcome else {
            Issue.record("Expected started, got \(outcome)")
            return
        }
        #expect(handle != nil)
        #expect(gate.starts.count == 1)
        #expect(gate.starts.first?.owner == .meeting)
        #expect(gate.starts.first?.languages == [.zhHans, .english])
        #expect(gate.starts.first?.fallbackLanguage == .english)
        #expect(gate.starts.first?.style == .meetingNotes)
        #expect(audio.activations == [.interpretationCaptions])
        #expect(lifecycle.hasActiveTask)
        #expect(lifecycle.sessionState == .listening)
        let taskID = try #require(lifecycle.taskID)
        #expect(await store.base.task(id: taskID)?.status == .running)
    }

    @Test("Preparing a new task stops the old stream before finishing the task")
    func prepareStopsOldStreamBeforeEnding() async throws {
        let log = LifecycleEventLog()
        let store = LifecycleFakeStore(log: log)
        let gate = LifecycleFakeGate(log: log)
        let lifecycle = makeLifecycle(store: store, gate: gate)

        let started = await lifecycle.startNewTask(makeRequest(autoStart: true))
        let handle = try #require(started.handle)
        let oldTaskID = try #require(lifecycle.taskID)

        let outcome = await lifecycle.prepareForNewTask()

        #expect(outcome == .ready)
        #expect(lifecycle.current == nil)
        #expect(await gate.isCurrent(handle) == false)
        let stopIndex = try #require(log.firstIndex(of: .gateStop(handle.generation)))
        let endIndex = try #require(log.firstIndex(of: .storeEnd(oldTaskID)))
        #expect(stopIndex < endIndex)
        #expect(await store.base.task(id: oldTaskID) == nil)
    }

    @Test("Ending a task flushes pending captions before the store-aware end")
    func endFlushesPendingCaptions() async throws {
        let log = LifecycleEventLog()
        let store = LifecycleFakeStore(log: log)
        let gate = LifecycleFakeGate(log: log)
        let lifecycle = makeLifecycle(store: store, gate: gate)

        _ = await lifecycle.startNewTask(makeRequest(autoStart: false))
        let taskID = try #require(lifecycle.taskID)
        let entry = makeEntry("六点见")
        lifecycle.persist([entry])

        let outcome = await lifecycle.endTask(transcript: [entry], summary: nil)

        guard case let .ended(session) = outcome else {
            Issue.record("Expected ended, got \(outcome)")
            return
        }
        #expect(session.entries.map(\.sourceText) == ["六点见"])
        let appendIndex = try #require(log.firstIndex(of: .storeAppend(taskID)))
        let endIndex = try #require(log.firstIndex(of: .storeEnd(taskID)))
        #expect(appendIndex < endIndex)
        #expect(lifecycle.current == nil)
        #expect(await store.base.list(filter: .meeting).count == 1)
    }

    @Test("Ending a listening task stops its stream before the store end")
    func endStopsListening() async throws {
        let log = LifecycleEventLog()
        let store = LifecycleFakeStore(log: log)
        let gate = LifecycleFakeGate(log: log)
        let lifecycle = makeLifecycle(store: store, gate: gate)
        let started = await lifecycle.startNewTask(makeRequest(autoStart: true))
        let handle = try #require(started.handle)
        let taskID = try #require(lifecycle.taskID)
        let entry = makeEntry("停流后再结束")
        lifecycle.persist([entry])

        let outcome = await lifecycle.endTask(transcript: [entry], summary: nil)

        guard case .ended = outcome else {
            Issue.record("Expected ended, got \(outcome)")
            return
        }
        #expect(await gate.isCurrent(handle) == false)
        let stopIndex = try #require(log.firstIndex(of: .gateStop(handle.generation)))
        let endIndex = try #require(log.firstIndex(of: .storeEnd(taskID)))
        #expect(stopIndex < endIndex)
        #expect(lifecycle.sessionState == .ready)
    }

    @Test("Ending a task with no transcript anywhere discards the empty task")
    func endDiscardsEmptyTask() async throws {
        let log = LifecycleEventLog()
        let store = LifecycleFakeStore(log: log)
        let gate = LifecycleFakeGate(log: log)
        let lifecycle = makeLifecycle(store: store, gate: gate)

        _ = await lifecycle.startNewTask(makeRequest(autoStart: false))
        let taskID = try #require(lifecycle.taskID)

        let outcome = await lifecycle.endTask(transcript: [], summary: nil)

        #expect(outcome == .discardedEmpty)
        #expect(lifecycle.current == nil)
        #expect(await store.base.task(id: taskID) == nil)
    }

    @Test("An empty in-memory transcript still ends when the store already has captions")
    func endUsesStoreForEmptyVerdict() async throws {
        let log = LifecycleEventLog()
        let store = LifecycleFakeStore(log: log)
        let gate = LifecycleFakeGate(log: log)
        let lifecycle = makeLifecycle(store: store, gate: gate)

        _ = await lifecycle.startNewTask(makeRequest(autoStart: false))
        let taskID = try #require(lifecycle.taskID)
        let persisted = makeEntry("已经落盘的句子")
        #expect(await store.base.append([persisted], to: taskID) == .persisted)

        let outcome = await lifecycle.endTask(transcript: [], summary: nil)

        guard case let .ended(session) = outcome else {
            Issue.record("Expected ended, got \(outcome)")
            return
        }
        #expect(session.entries.map(\.sourceText) == ["已经落盘的句子"])
        #expect(lifecycle.current == nil)
        #expect(await store.base.list(filter: .meeting).count == 1)
    }

    @Test("Persist coalesces to the latest snapshot and flush writes it once")
    func flushWritesLatestSnapshotOnce() async throws {
        let log = LifecycleEventLog()
        let store = LifecycleFakeStore(log: log)
        let gate = LifecycleFakeGate(log: log)
        let lifecycle = makeLifecycle(store: store, gate: gate)

        _ = await lifecycle.startNewTask(makeRequest(autoStart: false))
        let taskID = try #require(lifecycle.taskID)
        let first = makeEntry("第一句")
        let second = makeEntry("第二句")

        lifecycle.persist([first])
        lifecycle.persist([first, second])
        await lifecycle.flush()

        #expect(store.appendCount == 1)
        let stored = await store.base.task(id: taskID)?.entries.map(\.sourceText)
        #expect(stored == ["第一句", "第二句"])
    }

    @Test("Starting a new task cancels the old task's pending write")
    func startNewCancelsOldPendingWrite() async throws {
        let log = LifecycleEventLog()
        let store = LifecycleFakeStore(log: log)
        let gate = LifecycleFakeGate(log: log)
        let lifecycle = makeLifecycle(store: store, gate: gate)

        _ = await lifecycle.startNewTask(makeRequest(autoStart: false))
        let oldTaskID = try #require(lifecycle.taskID)
        lifecycle.persist([makeEntry("旧任务最后一句")])

        _ = await lifecycle.startNewTask(makeRequest(autoStart: false))
        let newTaskID = try #require(lifecycle.taskID)
        await lifecycle.flush()

        #expect(oldTaskID != newTaskID)
        #expect(store.appendCount == 0)
        let oldEntries = await store.base.task(id: oldTaskID)?.entries
        let newEntries = await store.base.task(id: newTaskID)?.entries
        #expect(oldEntries?.isEmpty == true)
        #expect(newEntries?.isEmpty == true)
    }

    @Test("A failed end keeps the task and transcript and marks it not saved")
    func failedEndKeepsTaskAndTranscript() async throws {
        let log = LifecycleEventLog()
        let store = LifecycleFakeStore(log: log)
        let gate = LifecycleFakeGate(log: log)
        let lifecycle = makeLifecycle(store: store, gate: gate)

        _ = await lifecycle.startNewTask(makeRequest(autoStart: false))
        let taskID = try #require(lifecycle.taskID)
        let entry = makeEntry("还没保存的内容")
        store.endFailure = .saveFailed

        let outcome = await lifecycle.endTask(transcript: [entry], summary: nil)

        #expect(outcome == .notSaved(.saveFailed))
        #expect(lifecycle.current?.id == taskID)
        #expect(lifecycle.hasActiveTask)
        #expect(lifecycle.isNotSaved)
        #expect(lifecycle.latestTranscript.map(\.sourceText) == ["还没保存的内容"])
        #expect(await store.base.task(id: taskID)?.status == .running)
    }

    @Test("Preparing a new task reports notSaved when finishing the old task fails")
    func prepareReportsNotSavedWhenEndFails() async throws {
        let log = LifecycleEventLog()
        let store = LifecycleFakeStore(log: log)
        let gate = LifecycleFakeGate(log: log)
        let lifecycle = makeLifecycle(store: store, gate: gate)

        _ = await lifecycle.startNewTask(makeRequest(autoStart: false))
        let taskID = try #require(lifecycle.taskID)
        store.endFailure = .saveFailed

        let outcome = await lifecycle.prepareForNewTask()

        #expect(outcome == .notSaved(.saveFailed))
        #expect(lifecycle.current?.id == taskID)
        #expect(lifecycle.isNotSaved)
        #expect(store.endCount == 1)
    }

    @Test("Preparing a new task blocks on an unsaved memory-only task with content")
    func prepareBlocksUnsavedTaskWithContent() async throws {
        let log = LifecycleEventLog()
        let store = LifecycleFakeStore(log: log)
        let gate = LifecycleFakeGate(log: log)
        let lifecycle = makeLifecycle(store: store, gate: gate)
        store.startNewFailure = .saveFailed

        let started = await lifecycle.startNewTask(makeRequest(autoStart: false))
        guard case let .notPersisted(reason, nil) = started else {
            Issue.record("Expected notPersisted, got \(started)")
            return
        }
        #expect(reason == .saveFailed)
        #expect(lifecycle.isMemoryOnly)
        #expect(lifecycle.isNotSaved)
        let taskID = try #require(lifecycle.taskID)
        lifecycle.persist([makeEntry("只在内存里的内容")])

        let outcome = await lifecycle.prepareForNewTask()

        #expect(outcome == .blockedByUnsavedTask)
        #expect(lifecycle.current?.id == taskID)
        #expect(lifecycle.latestTranscript.map(\.sourceText) == ["只在内存里的内容"])
        #expect(store.endCount == 0)
    }

    @Test("Discarding a memory-only unsaved task clears it without writing history")
    func discardMemoryOnlyTask() async throws {
        let log = LifecycleEventLog()
        let store = LifecycleFakeStore(log: log)
        let gate = LifecycleFakeGate(log: log)
        let lifecycle = makeLifecycle(store: store, gate: gate)
        store.startNewFailure = .unavailable
        _ = await lifecycle.startNewTask(makeRequest(autoStart: false))
        lifecycle.persist([makeEntry("要放弃的内容")])

        let outcome = await lifecycle.discardCurrentTask()

        #expect(outcome == .persisted)
        #expect(lifecycle.current == nil)
        #expect(!lifecycle.isNotSaved)
        #expect(store.endCount == 0)
        #expect(await store.base.unfinishedTasks().isEmpty)
    }

    @Test("Discarding a durable unsaved task deletes it from the store")
    func discardDurableUnsavedTask() async throws {
        let log = LifecycleEventLog()
        let store = LifecycleFakeStore(log: log)
        let gate = LifecycleFakeGate(log: log)
        let lifecycle = makeLifecycle(store: store, gate: gate)
        _ = await lifecycle.startNewTask(makeRequest(autoStart: false))
        let taskID = try #require(lifecycle.taskID)
        let entry = makeEntry("已经保存的一句")
        lifecycle.persist([entry])
        await lifecycle.flush()
        store.appendFailure = .saveFailed
        lifecycle.persist([entry, makeEntry("没写进去的一句")])
        await lifecycle.flush()
        #expect(lifecycle.isNotSaved)

        let outcome = await lifecycle.discardCurrentTask()

        #expect(outcome == .persisted)
        #expect(lifecycle.current == nil)
        #expect(await store.base.task(id: taskID) == nil)
    }

    @Test("Restore returns the unfinished task with its recorded language pair")
    func restoreReturnsTaskAndLanguagePair() async throws {
        let log = LifecycleEventLog()
        let store = LifecycleFakeStore(log: log)
        let gate = LifecycleFakeGate(log: log)
        let draft = TaskDraft(
            feature: .meeting,
            sourceLanguage: .english,
            targetLanguage: .zhHans,
            multilingual: false,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            title: "Seed task"
        )
        guard case let .persisted(seeded) = await store.base.startNew(draft) else {
            Issue.record("Seed task could not be created")
            return
        }
        _ = await store.base.setStatus(.pausedListening, for: seeded.id)
        let lifecycle = makeLifecycle(store: store, gate: gate)

        let restored = await lifecycle.restore()

        #expect(restored?.id == seeded.id)
        #expect(restored?.sourceLanguage == .english)
        #expect(restored?.targetLanguage == .zhHans)
        #expect(lifecycle.current?.sourceLanguage == .english)
        #expect(lifecycle.current?.targetLanguage == .zhHans)
        #expect(lifecycle.sessionState == .ready)
        #expect(lifecycle.hasActiveTask)
        #expect(gate.starts.isEmpty)
    }

    @Test("Restore marks the lifecycle not saved when the store cannot be read")
    func restoreUnavailableMarksNotSaved() async {
        let log = LifecycleEventLog()
        let store = LifecycleFakeStore(log: log)
        let gate = LifecycleFakeGate(log: log)
        let lifecycle = makeLifecycle(store: store, gate: gate)
        store.readFailure = .unavailable

        let restored = await lifecycle.restore()

        #expect(restored == nil)
        #expect(lifecycle.current == nil)
        #expect(lifecycle.isNotSaved)
        #expect(lifecycle.sessionState == .ready)
    }

    @Test("Scene phase only pauses listening and keeps the task active")
    func scenePhaseOnlyPauses() async throws {
        let log = LifecycleEventLog()
        let store = LifecycleFakeStore(log: log)
        let gate = LifecycleFakeGate(log: log)
        let lifecycle = makeLifecycle(store: store, gate: gate)
        _ = await lifecycle.startNewTask(makeRequest(autoStart: true))
        let taskID = try #require(lifecycle.taskID)
        lifecycle.persist([makeEntry("后台前最后一句")])

        await lifecycle.pauseForScenePhase()

        #expect(lifecycle.sessionState == .paused)
        #expect(lifecycle.hasActiveTask)
        #expect(lifecycle.current?.status == .pausedListening)
        #expect(await store.base.task(id: taskID)?.status == .pausedListening)
        #expect(store.endCount == 0)
        #expect(gate.stopCount == 1)
        #expect(store.appendCount == 1)
        let stored = await store.base.task(id: taskID)?.entries.map(\.sourceText)
        #expect(stored == ["后台前最后一句"])
    }

    @Test("Denied permission fails listening without starting the gate")
    func permissionDeniedDoesNotStartGate() async {
        let log = LifecycleEventLog()
        let store = LifecycleFakeStore(log: log)
        let gate = LifecycleFakeGate(log: log)
        let permissions = LifecycleFakePermissions()
        permissions.status = .microphoneDenied
        let lifecycle = makeLifecycle(store: store, gate: gate, permissions: permissions)

        let outcome = await lifecycle.startNewTask(makeRequest(autoStart: true))

        guard case .failed(.microphoneDenied) = outcome else {
            Issue.record("Expected microphoneDenied, got \(outcome)")
            return
        }
        #expect(permissions.requestCount == 1)
        #expect(gate.starts.isEmpty)
        #expect(lifecycle.sessionState == .failed(.microphoneDenied))
        #expect(lifecycle.hasActiveTask)
    }

    @Test("Audio activation failure fails listening before the gate starts")
    func audioFailureDoesNotStartGate() async {
        let log = LifecycleEventLog()
        let store = LifecycleFakeStore(log: log)
        let gate = LifecycleFakeGate(log: log)
        let audio = LifecycleFakeAudioSession(log: log)
        audio.activationError = DuiyiError.deviceIncapable
        let lifecycle = makeLifecycle(store: store, gate: gate, audio: audio)

        let outcome = await lifecycle.startNewTask(makeRequest(autoStart: true))

        guard case .failed(.deviceIncapable) = outcome else {
            Issue.record("Expected deviceIncapable, got \(outcome)")
            return
        }
        #expect(audio.activations == [.interpretationCaptions])
        #expect(gate.starts.isEmpty)
        #expect(lifecycle.sessionState == .failed(.deviceIncapable))
    }

    @Test("Gate start failure surfaces the engine error")
    func gateStartFailureSurfacesError() async {
        let log = LifecycleEventLog()
        let store = LifecycleFakeStore(log: log)
        let gate = LifecycleFakeGate(log: log)
        gate.nextStartError = DuiyiError.deviceIncapable
        let lifecycle = makeLifecycle(store: store, gate: gate)

        let outcome = await lifecycle.startNewTask(makeRequest(autoStart: true))

        guard case .failed(.deviceIncapable) = outcome else {
            Issue.record("Expected deviceIncapable, got \(outcome)")
            return
        }
        #expect(lifecycle.sessionState == .failed(.deviceIncapable))
        #expect(lifecycle.hasActiveTask)
    }

    @Test("Task title follows the interface language")
    func titleFollowsInterfaceLanguage() async throws {
        let log = LifecycleEventLog()
        let store = LifecycleFakeStore(log: log)
        let gate = LifecycleFakeGate(log: log)
        let zhLifecycle = makeLifecycle(store: store, gate: gate)
        _ = await zhLifecycle.startNewTask(makeRequest(autoStart: false, titleLanguage: .zhHans))
        let zhTitle = try #require(zhLifecycle.current?.title)
        #expect(zhTitle.contains("会议记录"))

        let enLifecycle = makeLifecycle(store: store, gate: gate)
        _ = await enLifecycle.startNewTask(makeRequest(autoStart: false, titleLanguage: .english))
        let enTitle = try #require(enLifecycle.current?.title)
        #expect(enTitle.contains("Meeting notes"))
    }

    @Test("A superseded stream ends silently and only pauses the task")
    func supersededStreamEndIsSilent() async throws {
        let log = LifecycleEventLog()
        let store = LifecycleFakeStore(log: log)
        let gate = LifecycleFakeGate(log: log)
        let lifecycle = makeLifecycle(store: store, gate: gate)
        let started = await lifecycle.startNewTask(makeRequest(autoStart: true))
        let handle = try #require(started.handle)
        let taskID = try #require(lifecycle.taskID)

        _ = try await gate.start(
            owner: .simultaneous,
            languages: [.zhHans, .english],
            fallbackLanguage: .english,
            style: .liveCaptions
        )
        #expect(await gate.isCurrent(handle) == false)

        let interrupted = await lifecycle.handleStreamEnded()

        #expect(interrupted == false)
        #expect(lifecycle.sessionState == .paused)
        #expect(lifecycle.hasActiveTask)
        #expect(await store.base.task(id: taskID)?.status == .pausedListening)
    }

    @Test("An unexpected end of the current stream reports recognition interruption")
    func currentStreamEndIsInterrupted() async throws {
        let log = LifecycleEventLog()
        let store = LifecycleFakeStore(log: log)
        let gate = LifecycleFakeGate(log: log)
        let lifecycle = makeLifecycle(store: store, gate: gate)
        _ = await lifecycle.startNewTask(makeRequest(autoStart: true))
        let taskID = try #require(lifecycle.taskID)

        gate.failCurrentStream()

        let interrupted = await lifecycle.handleStreamEnded()

        #expect(interrupted)
        #expect(lifecycle.sessionState == .failed(.recognitionInterrupted))
        #expect(lifecycle.hasActiveTask)
        #expect(await store.base.task(id: taskID)?.status == .pausedListening)
    }

    // MARK: - Helpers

    private func makeEntry(_ text: String) -> TranscriptEntry {
        TranscriptEntry(
            id: UUID(),
            speaker: .user,
            source: .zhHans,
            sourceText: text,
            translatedText: "",
            isFinal: true
        )
    }

    private func makeLifecycle(
        store: LifecycleFakeStore,
        gate: LifecycleFakeGate,
        audio: LifecycleFakeAudioSession? = nil,
        permissions: LifecycleFakePermissions = LifecycleFakePermissions()
    ) -> TaskLifecycle {
        let log = store.log
        return TaskLifecycle(
            feature: .meeting,
            store: store,
            gate: gate,
            permissions: permissions,
            audioSession: audio ?? LifecycleFakeAudioSession(log: log),
            persistDebounce: .seconds(3600)
        )
    }

    private func makeRequest(
        autoStart: Bool,
        titleLanguage: AppLanguage = .zhHans
    ) -> TaskLifecycle.NewTaskRequest {
        TaskLifecycle.NewTaskRequest(
            sourceLanguage: .zhHans,
            targetLanguage: .english,
            multilingual: true,
            titleLanguage: titleLanguage,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            autoStart: autoStart,
            listening: TaskLifecycle.ListeningRequest(
                languages: [.zhHans, .english],
                fallbackLanguage: .english,
                style: .meetingNotes,
                audioUseCase: .interpretationCaptions
            )
        )
    }
}

private extension TaskLifecycle.StartOutcome {
    var handle: SpeechSessionHandle? {
        switch self {
        case let .started(handle):
            return handle
        case .notPersisted, .failed:
            return nil
        }
    }
}
