import Foundation

@MainActor
@Observable
final class MeetingViewModel {
    private let lifecycle: TaskLifecycle
    private let permissions: any PermissionGranting
    private let preferences: PreferencesStore
    private let summarizer: any ConversationSummarizing

    /// Feature-specific transient states (preparing assets, failed model
    /// preparation) layered over the lifecycle-owned session state.
    private var stateOverride: SessionState?

    var sessionState: SessionState {
        get { stateOverride ?? lifecycle.sessionState }
        set { stateOverride = newValue }
    }

    var sourceLanguage: AppLanguage
    var recognizesMultipleLanguages: Bool
    var fontSize: CaptionFontSize
    var pane: PaneState { projection.pane(.user) }
    var isSettingsPresented = false
    var isSummaryPresented = false
    var holdScreenAfterPause = false
    var transcript: [TranscriptEntry] { projection.transcript }
    var summary: ConversationSummary?
    var summaryError: String?
    var summaryAvailability: SummaryAvailability = .unavailable
    var isSummarizing = false
    var isLengthLimited = false
    var skipsBootstrap = false
    /// Set when a new task is blocked by a memory-only task with content.
    var isUnsavedTaskPromptPresented = false
    /// The blocked task's summary/export sheet is open and the user chose
    /// "export and continue"; the sheet offers continue once the file is ready.
    var isExportThenContinuePending = false
    /// "继续任务：…" prompt shown after restoring an unfinished task.
    var resumePromptText: String?

    private var speechTask: Task<Void, Never>?
    private var idleRestoreTask: Task<Void, Never>?
    private var projection = CaptionProjection(policy: .meeting)
    private let idleRestoreDelay: Duration

    init(
        gate: any SpeechSessionGating,
        permissions: any PermissionGranting,
        preferences: PreferencesStore,
        summarizer: any ConversationSummarizing,
        audioSession: any AudioSessionConfiguring = NoOpAudioSession(),
        taskStore: any TaskStoreV2 = InMemoryTaskStore(),
        idleRestoreDelay: Duration = .seconds(ConversationLayout.idleRestoreSeconds)
    ) {
        lifecycle = TaskLifecycle(
            feature: .meeting,
            store: taskStore,
            gate: gate,
            permissions: permissions,
            audioSession: audioSession
        )
        self.permissions = permissions
        self.preferences = preferences
        self.summarizer = summarizer
        self.idleRestoreDelay = idleRestoreDelay
        sourceLanguage = preferences.meetingLanguage
        recognizesMultipleLanguages = preferences.meetingRecognizesMultipleLanguages
        fontSize = preferences.fontSize
    }

    /// Compatibility initializer for call sites and tests that inject a raw
    /// speech engine; the meeting lifecycle gets its own gate around it.
    convenience init(
        speech: any SpeechRecognizing,
        permissions: any PermissionGranting,
        preferences: PreferencesStore,
        summarizer: any ConversationSummarizing,
        audioSession: any AudioSessionConfiguring = NoOpAudioSession(),
        taskStore: any TaskStoreV2 = InMemoryTaskStore(),
        idleRestoreDelay: Duration = .seconds(ConversationLayout.idleRestoreSeconds)
    ) {
        self.init(
            gate: SpeechSessionGate(engine: speech),
            permissions: permissions,
            preferences: preferences,
            summarizer: summarizer,
            audioSession: audioSession,
            taskStore: taskStore,
            idleRestoreDelay: idleRestoreDelay
        )
    }

    var hasActiveTask: Bool { lifecycle.hasActiveTask }
    var taskStartedAt: Date? { lifecycle.startedAt }
    var isMemoryOnly: Bool { lifecycle.isMemoryOnly }
    var isNotSaved: Bool { lifecycle.isNotSaved }
    var displayLanguage: AppLanguage { preferences.userLanguage }

    var recognitionLanguages: [AppLanguage] {
        MeetingRecognition.languages(
            multilingual: recognizesMultipleLanguages,
            pinned: sourceLanguage,
            display: displayLanguage
        )
    }

    var recognitionKey: String {
        recognitionLanguages.map(\.rawValue).joined(separator: "|")
    }

    var canSummarize: Bool {
        transcript.contains { !$0.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var keepsScreenAwake: Bool {
        sessionState == .listening || holdScreenAfterPause
    }

    var controlLabel: String {
        if !hasActiveTask {
            return Copy.needNewTask(for: displayLanguage)
        }
        switch sessionState {
        case .listening:
            return Copy.recording(for: displayLanguage)
        case .paused:
            return Copy.paused(for: displayLanguage)
        case .preparing:
            return Copy.preparing(for: displayLanguage)
        case .ready, .idle, .failed:
            return Copy.tapToStart(for: displayLanguage)
        }
    }

    var errorText: String? {
        if isLengthLimited {
            return Copy.meetingTooLong(for: displayLanguage)
        }
        if case let .failed(error) = sessionState {
            return error.userMessage(for: displayLanguage)
        }
        return nil
    }

    var exportableSession: TaskSession {
        let startedAt = lifecycle.startedAt ?? .now
        return TaskSession(
            id: lifecycle.taskID ?? UUID(),
            feature: .meeting,
            status: hasActiveTask ? .running : .ended,
            startedAt: startedAt,
            endedAt: nil,
            title: TaskTitle.make(
                feature: .meeting,
                source: sourceLanguage,
                target: nil,
                startedAt: startedAt,
                language: displayLanguage,
                multilingual: recognizesMultipleLanguages
            ),
            subtitle: TaskTitle.subtitle(from: transcript),
            sourceLanguage: sourceLanguage,
            targetLanguage: nil,
            entries: transcript,
            summary: summary
        )
    }

    func bootstrap() async {
        guard !skipsBootstrap else { return }
        stateOverride = .preparing
        if let existing = await lifecycle.restore() {
            applyRestored(existing)
        }
        let status = await permissions.currentStatus()
        if let error = status.asDuiyiError() {
            stateOverride = .failed(error)
            return
        }
        stateOverride = nil
    }

    /// Two-phase begin: the lifecycle stops the old stream and ends the old
    /// task first; module captions are cleared only after it reports ready.
    func beginTask() async {
        // Stop and drain the old stream first, so a final published during
        // stop is part of the snapshot that ends the old task.
        await lifecycle.pauseListening()
        await drainSpeechTask()
        // An empty display may be a cleared screen over content the lifecycle
        // already holds; only overwrite its snapshot with real captions.
        if !transcript.isEmpty {
            lifecycle.persist(transcript)
        }
        stateOverride = nil
        switch await lifecycle.prepareForNewTask() {
        case .ready:
            await createNewTask()
        case .blockedByUnsavedTask:
            isUnsavedTaskPromptPresented = true
        case .notSaved:
            // Keep the task and captions; the not-saved banner explains why.
            break
        }
    }

    /// Explicit user choice from the unsaved-task confirmation: drop the
    /// memory-only task and start a fresh one.
    @discardableResult
    func discardUnsavedTaskAndBegin() async -> TaskStoreWriteOutcome {
        isUnsavedTaskPromptPresented = false
        isExportThenContinuePending = false
        let outcome = await lifecycle.discardMemoryOnlyTask()
        stateOverride = nil
        await createNewTask()
        return outcome
    }

    func dismissUnsavedTaskPrompt() {
        isUnsavedTaskPromptPresented = false
    }

    /// "Export and continue": open the blocked task's summary/export sheet and
    /// remember that a successful export is followed by a new task.
    func beginExportThenContinue() {
        isUnsavedTaskPromptPresented = false
        isExportThenContinuePending = true
        isSummaryPresented = true
    }

    /// Closing the summary without tapping continue keeps the memory-only task
    /// and its transcript intact.
    func dismissSummary() {
        isSummaryPresented = false
        isExportThenContinuePending = false
    }

    /// User confirmed continue after the export file was prepared.
    @discardableResult
    func continueAfterExport() async -> TaskStoreWriteOutcome {
        guard isExportThenContinuePending else { return .persisted }
        isSummaryPresented = false
        isExportThenContinuePending = false
        return await discardUnsavedTaskAndBegin()
    }

    func endTask() async -> TaskSession? {
        // Stop the stream before ending so the engine can publish its last
        // final; drain the consumer before the transcript is snapshotted.
        await lifecycle.pauseListening()
        await drainSpeechTask()
        isUnsavedTaskPromptPresented = false
        isExportThenContinuePending = false
        let outcome = await lifecycle.endTask(transcript: transcript, summary: summary)
        stateOverride = nil
        holdScreenAfterPause = false
        idleRestoreTask?.cancel()
        projection.setSpeakingHint(nil, pane: .user)
        switch outcome {
        case let .ended(session):
            resetCaptions()
            resumePromptText = nil
            return session
        case .discardedEmpty:
            resetCaptions()
            resumePromptText = nil
            return nil
        case .notSaved:
            // Keep the transcript in memory for export; nothing was written.
            return nil
        }
    }

    func toggleListening() async {
        guard hasActiveTask, !isLengthLimited else { return }
        if sessionState == .listening {
            await stop()
        } else {
            await start()
        }
    }

    func start() async {
        guard hasActiveTask, !isLengthLimited, sessionState != .listening else { return }
        stateOverride = nil
        idleRestoreTask?.cancel()
        holdScreenAfterPause = false

        guard case let .started(handle) = await lifecycle.startListening(makeListeningRequest()) else {
            return
        }
        attachSpeechTask(handle)
    }

    func stop(restoreIdleTimerAfterDelay: Bool = true) async {
        let wasListening = sessionState == .listening
        if stateOverride == .listening {
            stateOverride = nil
        }
        await lifecycle.pauseListening()
        await drainSpeechTask()
        projection.setSpeakingHint(nil, pane: .user)
        if wasListening {
            if restoreIdleTimerAfterDelay {
                holdScreenAfterPause = true
                scheduleIdleRestore()
            } else {
                holdScreenAfterPause = false
                idleRestoreTask?.cancel()
            }
        }
    }

    /// Display-only clear: flushes pending captions first, then blanks the
    /// panes, speaking hint, and summary presentation. The transcript, summary
    /// data, cumulative 2万字 counter, and task/listening state stay intact.
    func clearDisplay() async {
        await lifecycle.flush()
        projection.clearDisplay()
        isSummaryPresented = false
        isExportThenContinuePending = false
    }

    /// Full caption reset, reserved for starting or ending a task.
    func resetCaptions() {
        projection.reset()
        summary = nil
        summaryError = nil
        isLengthLimited = false
    }

    func setRecognizesMultipleLanguages(_ enabled: Bool) {
        guard enabled != recognizesMultipleLanguages else { return }
        recognizesMultipleLanguages = enabled
        preferences.meetingRecognizesMultipleLanguages = enabled
        pauseRecognitionForLanguageChange()
    }

    func setSourceLanguage(_ language: AppLanguage) {
        if !recognizesMultipleLanguages, language == sourceLanguage {
            return
        }
        sourceLanguage = language
        preferences.meetingLanguage = language
        if recognizesMultipleLanguages {
            recognizesMultipleLanguages = false
            preferences.meetingRecognizesMultipleLanguages = false
        }
        pauseRecognitionForLanguageChange()
    }

    func setFontSize(_ size: CaptionFontSize) {
        fontSize = size
        preferences.fontSize = size
    }

    func enterPreparing() {
        idleRestoreTask?.cancel()
        holdScreenAfterPause = false
        stateOverride = .preparing
    }

    func restoreReady() {
        guard stateOverride == .preparing else { return }
        stateOverride = nil
    }

    func fail(_ error: DuiyiError) {
        stateOverride = .failed(error)
        holdScreenAfterPause = false
        idleRestoreTask?.cancel()
    }

    func accept(_ utterance: Utterance) {
        guard hasActiveTask, !isLengthLimited else { return }
        let text = SpokenText.collapseStutteredRepeats(
            utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !text.isEmpty else { return }
        let spoken = UtteranceAssembler.resolvedLanguage(claimed: utterance.language, text: text)
        if !recognizesMultipleLanguages, spoken != sourceLanguage {
            return
        }

        projection.setSpeakingHint(
            utterance.isFinal ? nil : Copy.speaking(for: spoken),
            pane: .user
        )

        let normalized = Utterance(
            id: utterance.id,
            language: spoken,
            text: text,
            isFinal: utterance.isFinal,
            createdAt: utterance.createdAt
        )
        guard let line = projection.ingest(normalized, pane: .user, speaker: .user) else {
            return
        }
        guard line.phase == .settled else { return }
        lifecycle.persist(projection.transcript)
        if projection.transcriptCharacterCount >= MeetingLayout.transcriptCharacterLimit {
            isLengthLimited = true
            Task { [weak self] in
                await self?.stop(restoreIdleTimerAfterDelay: false)
            }
        }
    }

    func requestSummary() async {
        summaryAvailability = await summarizer.availability()
        guard canSummarize else {
            summaryError = DuiyiError.summaryEmpty.userMessage(for: displayLanguage)
            isSummaryPresented = true
            return
        }
        isSettingsPresented = false
        isSummaryPresented = true
        isSummarizing = true
        summaryError = nil
        if summaryAvailability == .available {
            do {
                summary = try await summarizer.summarize(entries: transcript, outputLanguage: displayLanguage)
                if let summary {
                    await lifecycle.saveSummary(summary)
                }
            } catch let error as DuiyiError {
                summary = nil
                summaryError = error.userMessage(for: displayLanguage)
            } catch {
                summary = nil
                summaryError = DuiyiError.summaryEmpty.userMessage(for: displayLanguage)
            }
        } else {
            summary = nil
        }
        isSummarizing = false
    }

    private func createNewTask() async {
        // The lifecycle already stopped the old stream; drain its consumer so
        // the stop-time final cannot land in the new task's captions.
        await drainSpeechTask()
        resetCaptions()
        resumePromptText = nil
        _ = await lifecycle.startNewTask(makeNewTaskRequest())
    }

    private func makeNewTaskRequest() -> TaskLifecycle.NewTaskRequest {
        TaskLifecycle.NewTaskRequest(
            sourceLanguage: recognizesMultipleLanguages ? displayLanguage : sourceLanguage,
            targetLanguage: nil,
            multilingual: recognizesMultipleLanguages,
            titleLanguage: displayLanguage,
            startedAt: .now,
            autoStart: false,
            listening: makeListeningRequest()
        )
    }

    private func makeListeningRequest() -> TaskLifecycle.ListeningRequest {
        TaskLifecycle.ListeningRequest(
            languages: recognitionLanguages,
            fallbackLanguage: recognizesMultipleLanguages ? displayLanguage : sourceLanguage,
            style: .meetingNotes,
            audioUseCase: .interpretationCaptions
        )
    }

    private func applyRestored(_ session: TaskSession) {
        sourceLanguage = session.sourceLanguage
        recognizesMultipleLanguages = Self.isMultilingualTitle(session.title)
        projection.restore(session.entries)
        summary = session.summary
        isLengthLimited = projection.transcriptCharacterCount >= MeetingLayout.transcriptCharacterLimit
        resumePromptText = Copy.continueTask(session.title, for: displayLanguage)
    }

    /// A meeting task records its recognition mode only in the generated title
    /// ("multiple languages" vs. one language name); use that to restore the
    /// language pair without a schema change.
    private static func isMultilingualTitle(_ title: String) -> Bool {
        AppLanguage.allCases.contains { title.contains(Copy.meetingMultilingual(for: $0)) }
    }

    private func pauseRecognitionForLanguageChange() {
        projection.archiveLive(pane: .user)
        projection.setSpeakingHint(nil, pane: .user)
        if sessionState == .listening || sessionState == .paused {
            stateOverride = .ready
        }
    }

    private func attachSpeechTask(_ handle: SpeechSessionHandle) {
        speechTask?.cancel()
        speechTask = Task { [weak self] in
            for await utterance in handle.stream {
                self?.accept(utterance)
            }
            await self?.streamEnded(handle)
        }
    }

    /// Waits for the speech consumer after the gate has stopped the stream.
    /// The analyzer publishes its last final during `stop`; cancelling the
    /// consumer immediately would drop it.
    private func drainSpeechTask() async {
        let task = speechTask
        speechTask = nil
        await SpeechTaskDrain.wait(for: task)
    }

    private func streamEnded(_ handle: SpeechSessionHandle) async {
        let interrupted = await lifecycle.handleStreamEnded(handle)
        guard interrupted else { return }
        holdScreenAfterPause = false
        idleRestoreTask?.cancel()
        projection.setSpeakingHint(nil, pane: .user)
    }

    private func scheduleIdleRestore() {
        idleRestoreTask?.cancel()
        idleRestoreTask = Task { [weak self] in
            let delay = self?.idleRestoreDelay ?? .seconds(ConversationLayout.idleRestoreSeconds)
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.holdScreenAfterPause = false
        }
    }
}
