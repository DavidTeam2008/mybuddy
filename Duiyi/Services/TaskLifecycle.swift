import Foundation

/// Per-feature owner of the task and listening lifecycle (Wave 1, ticket #4).
///
/// This is the expand-step replacement for `TaskSessionController`: it owns the
/// current task, status transitions, restore, the two-phase new-task flow,
/// ending, the 250 ms persist debounce, flushing, scene-phase pausing, the
/// `notSaved` mark, and the common permission/audio/gate listening start-up.
/// Feature-specific prechecks (for example interpretation voice-out routing)
/// stay in the ViewModel.
@MainActor
@Observable
final class TaskLifecycle {
    struct ListeningRequest: Equatable, Sendable {
        var languages: [AppLanguage]
        var fallbackLanguage: AppLanguage
        var style: SpeechRecognitionStyle
        var audioUseCase: AudioUseCase
    }

    struct NewTaskRequest: Equatable, Sendable {
        var sourceLanguage: AppLanguage
        var targetLanguage: AppLanguage?
        var multilingual: Bool
        /// The interface ("the language I read") language used for the title.
        var titleLanguage: AppLanguage
        var startedAt: Date
        var autoStart: Bool
        var listening: ListeningRequest
    }

    enum PrepareOutcome: Equatable, Sendable {
        case ready
        case blockedByUnsavedTask
        case notSaved(TaskStoreFailureReason)
    }

    enum StartOutcome {
        case started(SpeechSessionHandle?)
        case notPersisted(TaskStoreFailureReason, SpeechSessionHandle?)
        case failed(DuiyiError)
    }

    enum ListeningOutcome {
        case started(SpeechSessionHandle)
        case failed(DuiyiError)
    }

    enum EndOutcome: Equatable, Sendable {
        case ended(TaskSession)
        case discardedEmpty
        case notSaved(TaskStoreFailureReason)
    }

    let feature: FeatureID

    private(set) var current: TaskSession?
    private(set) var sessionState: SessionState = .idle
    /// Sticky for the current task: a write failed after the seam's one retry.
    private(set) var isNotSaved = false
    /// True when the task exists only in memory because `startNew` failed.
    private(set) var isMemoryOnly = false
    /// Latest snapshot handed to `persist`, retained for the unsaved-task guard.
    private(set) var latestTranscript: [TranscriptEntry] = []

    private let store: any TaskStoreV2
    private let gate: any SpeechSessionGating
    private let permissions: any PermissionGranting
    private let audioSession: any AudioSessionConfiguring
    private let persistDebounce: Duration

    @ObservationIgnored private var activeHandle: SpeechSessionHandle?
    @ObservationIgnored private var pendingPersist: PendingPersist?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    private struct PendingPersist {
        var taskID: UUID
        var entries: [TranscriptEntry]
    }

    init(
        feature: FeatureID,
        store: any TaskStoreV2,
        gate: any SpeechSessionGating,
        permissions: any PermissionGranting,
        audioSession: any AudioSessionConfiguring,
        persistDebounce: Duration = .milliseconds(250)
    ) {
        self.feature = feature
        self.store = store
        self.gate = gate
        self.permissions = permissions
        self.audioSession = audioSession
        self.persistDebounce = persistDebounce
    }

    var hasActiveTask: Bool {
        guard let current else { return false }
        return current.status != .ended
    }

    var taskID: UUID? { current?.id }
    var startedAt: Date? { current?.startedAt }

    // MARK: - Restore

    /// Restores this feature's newest unfinished task. The returned session
    /// carries the task's own language pair, which the ViewModel applies
    /// instead of following the current preferences.
    @discardableResult
    func restore() async -> TaskSession? {
        switch await store.readActiveTask(for: feature) {
        case let .value(task):
            current = task
            isMemoryOnly = false
            isNotSaved = false
            sessionState = .ready
            return task
        case .unavailable:
            current = nil
            isMemoryOnly = false
            isNotSaved = true
            sessionState = .ready
            return nil
        }
    }

    // MARK: - New task (two-phase)

    /// Phase one: stop the current stream, flush pending captions, then finish
    /// the current task with the store-aware empty check. The caller clears
    /// module captions only after `.ready`.
    func prepareForNewTask() async -> PrepareOutcome {
        await pauseListening()
        await flush()

        guard current != nil else { return .ready }

        if isNotSaved && Self.hasUsableText(latestTranscript) {
            return .blockedByUnsavedTask
        }

        if isMemoryOnly {
            clearCurrent()
            return .ready
        }

        guard let taskID = current?.id else { return .ready }
        switch await store.end(taskID: taskID, entries: [], summary: nil) {
        case .ended, .discardedEmpty:
            clearCurrent()
            return .ready
        case let .notPersisted(reason):
            isNotSaved = true
            sessionState = .paused
            return .notSaved(reason)
        }
    }

    /// Phase two: create the task (durable, or memory-only when the store
    /// write fails) and optionally start listening.
    func startNewTask(_ request: NewTaskRequest) async -> StartOutcome {
        cancelPendingPersist()
        latestTranscript = []
        sessionState = .ready

        let title = TaskTitle.make(
            feature: feature,
            source: request.sourceLanguage,
            target: request.targetLanguage,
            startedAt: request.startedAt,
            language: request.titleLanguage,
            multilingual: request.multilingual
        )
        let draft = TaskDraft(
            feature: feature,
            sourceLanguage: request.sourceLanguage,
            targetLanguage: request.targetLanguage,
            multilingual: request.multilingual,
            startedAt: request.startedAt,
            title: title
        )

        var persistenceFailure: TaskStoreFailureReason?
        switch await store.startNew(draft) {
        case let .persisted(session):
            current = session
            isMemoryOnly = false
            isNotSaved = false
        case let .notPersisted(reason):
            current = TaskSession(
                id: UUID(),
                feature: feature,
                status: .running,
                startedAt: request.startedAt,
                endedAt: nil,
                title: title,
                subtitle: nil,
                sourceLanguage: request.sourceLanguage,
                targetLanguage: request.targetLanguage,
                entries: [],
                summary: nil
            )
            isMemoryOnly = true
            isNotSaved = true
            persistenceFailure = reason
        }

        guard request.autoStart else {
            if let persistenceFailure {
                return .notPersisted(persistenceFailure, nil)
            }
            return .started(nil)
        }

        switch await startListening(request.listening) {
        case let .started(handle):
            if let persistenceFailure {
                return .notPersisted(persistenceFailure, handle)
            }
            return .started(handle)
        case let .failed(error):
            return .failed(error)
        }
    }

    // MARK: - Listening

    func startListening(_ request: ListeningRequest) async -> ListeningOutcome {
        guard hasActiveTask else {
            let error = DuiyiError.recognitionInterrupted
            sessionState = .failed(error)
            return .failed(error)
        }

        if let handle = activeHandle {
            activeHandle = nil
            await gate.stop(handle)
        }

        var status = await permissions.currentStatus()
        if status != .granted {
            status = await permissions.requestAccess()
        }
        if let error = status.asDuiyiError() {
            sessionState = .failed(error)
            return .failed(error)
        }

        do {
            try await audioSession.activate(request.audioUseCase)
        } catch let error as DuiyiError {
            sessionState = .failed(error)
            return .failed(error)
        } catch {
            sessionState = .failed(.recognitionInterrupted)
            return .failed(.recognitionInterrupted)
        }

        do {
            let handle = try await gate.start(
                owner: feature,
                languages: request.languages,
                fallbackLanguage: request.fallbackLanguage,
                style: request.style
            )
            activeHandle = handle
            sessionState = .listening
            await setStatus(.running)
            return .started(handle)
        } catch let error as DuiyiError {
            sessionState = .failed(error)
            return .failed(error)
        } catch {
            sessionState = .failed(.recognitionInterrupted)
            return .failed(.recognitionInterrupted)
        }
    }

    /// User pause / module switch: stop this feature's stream and keep the task.
    func pauseListening() async {
        guard let handle = activeHandle else { return }
        activeHandle = nil
        await gate.stop(handle)

        guard sessionState == .listening else { return }
        sessionState = .paused
        await setStatus(.pausedListening)
        await flush()
    }

    /// Backgrounding only pauses listening; it never ends the task.
    func pauseForScenePhase() async {
        await pauseListening()
        await flush()
    }

    /// Classifies a finished stream at the lifecycle seam. A still-current
    /// handle ended unexpectedly (real interruption); a handle superseded by
    /// another owner ends silently into paused. The task is never ended here.
    @discardableResult
    func handleStreamEnded() async -> Bool {
        guard let handle = activeHandle else { return false }
        activeHandle = nil

        guard await gate.isCurrent(handle) else {
            sessionState = .paused
            await setStatus(.pausedListening)
            await flush()
            return false
        }

        sessionState = .failed(.recognitionInterrupted)
        await setStatus(.pausedListening)
        await flush()
        return true
    }

    /// Leaves an unsaved task on explicit user request ("discard and start
    /// new"). A durable task is removed; a memory-only task just disappears.
    func discardCurrentTask() async -> TaskStoreWriteOutcome {
        await pauseListening()
        cancelPendingPersist()
        let outcome: TaskStoreWriteOutcome
        if let taskID = current?.id, !isMemoryOnly {
            outcome = await store.deleteTask(id: taskID)
        } else {
            outcome = .persisted
        }
        current = nil
        isMemoryOnly = false
        isNotSaved = false
        latestTranscript = []
        sessionState = .ready
        return outcome
    }

    // MARK: - End

    /// Stops listening, flushes the pending snapshot, then lets the store decide
    /// from its persisted transcript whether the task ends into history or is
    /// discarded as empty. `notSaved` keeps the task and transcript in memory.
    func endTask(
        transcript: [TranscriptEntry],
        summary: ConversationSummary?
    ) async -> EndOutcome {
        await pauseListening()
        latestTranscript = transcript
        await flush()
        cancelPendingPersist()

        guard let taskID = current?.id else {
            latestTranscript = []
            sessionState = .ready
            return .discardedEmpty
        }

        switch await store.end(taskID: taskID, entries: transcript, summary: summary) {
        case let .ended(session):
            clearCurrent()
            return .ended(session)
        case .discardedEmpty:
            clearCurrent()
            return .discardedEmpty
        case let .notPersisted(reason):
            isNotSaved = true
            sessionState = .paused
            return .notSaved(reason)
        }
    }

    // MARK: - Persistence

    /// Records the latest transcript snapshot and schedules a debounced append.
    func persist(_ transcript: [TranscriptEntry]) {
        guard hasActiveTask, let taskID = current?.id else { return }
        latestTranscript = transcript
        guard !isMemoryOnly else { return }

        pendingPersist = PendingPersist(taskID: taskID, entries: transcript)
        debounceTask?.cancel()
        let delay = persistDebounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.writePendingPersist()
        }
    }

    /// Cancels any scheduled append and writes the latest snapshot immediately.
    func flush() async {
        debounceTask?.cancel()
        debounceTask = nil
        await writePendingPersist()
    }

    private func writePendingPersist() async {
        guard let pending = pendingPersist else { return }
        pendingPersist = nil
        guard let current,
              current.id == pending.taskID,
              current.status != .ended,
              !isMemoryOnly else {
            return
        }
        let outcome = await store.append(pending.entries, to: pending.taskID)
        if case .notPersisted = outcome {
            isNotSaved = true
        }
    }

    private func cancelPendingPersist() {
        debounceTask?.cancel()
        debounceTask = nil
        pendingPersist = nil
    }

    // MARK: - Helpers

    private func setStatus(_ status: TaskStatus) async {
        guard let taskID = current?.id else { return }
        current?.status = status
        guard !isMemoryOnly else { return }
        let outcome = await store.setStatus(status, for: taskID)
        if case .notPersisted = outcome {
            isNotSaved = true
        }
    }

    private func clearCurrent() {
        cancelPendingPersist()
        current = nil
        isMemoryOnly = false
        isNotSaved = false
        latestTranscript = []
        sessionState = .ready
    }

    private static func hasUsableText(_ entries: [TranscriptEntry]) -> Bool {
        entries.contains { !$0.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
