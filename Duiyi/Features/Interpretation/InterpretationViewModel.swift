import Foundation

@MainActor
@Observable
final class InterpretationViewModel {
    private let lifecycle: TaskLifecycle
    private let permissions: any PermissionGranting
    private let preferences: PreferencesStore
    private let summarizer: any ConversationSummarizing
    private let audioSession: any AudioSessionConfiguring
    private let synthesizer: any SpeechSynthesizing

    /// Feature-specific transient states (asset preparation, preparation
    /// failure) layered over the lifecycle-owned session state.
    private var stateOverride: SessionState?

    var sessionState: SessionState {
        get { stateOverride ?? lifecycle.sessionState }
        set { stateOverride = newValue }
    }

    var sourceLanguage: AppLanguage
    var targetLanguage: AppLanguage
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
    var voiceOutEnabled: Bool
    var showsSourceLine: Bool
    var canSpeakWithoutEcho = false
    var voiceOutBlockedMessage: String?
    var skipsBootstrap = false
    /// Set when a new task is blocked by a memory-only task with content.
    var isUnsavedTaskPromptPresented = false
    /// The blocked task's summary/export sheet is open and the user chose
    /// "export and continue"; the sheet offers continue once the file is ready.
    var isExportThenContinuePending = false
    /// "继续任务：…" prompt shown after restoring an unfinished task.
    var resumePromptText: String?

    private let pipeline: TranslationPipeline
    private var projection = CaptionProjection(policy: .interpretation)
    private let lateTranslation: LateTranslationBackfill

    private var speechTask: Task<Void, Never>?
    private var idleRestoreTask: Task<Void, Never>?
    private var routeTask: Task<Void, Never>?
    private var speakTask: Task<Void, Never>?
    private var spokenPrefixes: [UUID: String] = [:]
    private var lastSpokenTranslation = ""
    private var spokenCompactTail = ""
    private var pendingJobs: [SynthesisJob] = []
    private var isSpeaking = false
    private var speechGeneration = 0
    private var speechDebounces: [UUID: Task<Void, Never>] = [:]
    private var pendingSettledSpeech: [UUID: String] = [:]
    private let idleRestoreDelay: Duration
    private let speechSettleDelay: Duration

    init(
        gate: any SpeechSessionGating,
        permissions: any PermissionGranting,
        preferences: PreferencesStore,
        summarizer: any ConversationSummarizing,
        audioSession: any AudioSessionConfiguring,
        synthesizer: any SpeechSynthesizing,
        taskStore: any TaskStoreV2 = InMemoryTaskStore(),
        idleRestoreDelay: Duration = .seconds(ConversationLayout.idleRestoreSeconds),
        speechSettleDelay: Duration = .milliseconds(380)
    ) {
        let lifecycle = TaskLifecycle(
            feature: .simultaneous,
            store: taskStore,
            gate: gate,
            permissions: permissions,
            audioSession: audioSession
        )
        self.lifecycle = lifecycle
        lateTranslation = LateTranslationBackfill(lifecycle: lifecycle)
        self.permissions = permissions
        self.preferences = preferences
        self.summarizer = summarizer
        self.audioSession = audioSession
        self.synthesizer = synthesizer
        self.idleRestoreDelay = idleRestoreDelay
        self.speechSettleDelay = speechSettleDelay
        self.pipeline = TranslationPipeline()
        sourceLanguage = preferences.sourceLanguage
        targetLanguage = preferences.targetLanguage
        fontSize = preferences.fontSize
        voiceOutEnabled = preferences.voiceOutEnabled
        showsSourceLine = preferences.showsSourceLine
    }

    /// Test seam: injects only the debounce scheduler. The ViewModel still
    /// constructs its own pipeline, so callers cannot substitute the stale
    /// rule (finals always win; only previews may be dropped as shorter).
    init(
        gate: any SpeechSessionGating,
        permissions: any PermissionGranting,
        preferences: PreferencesStore,
        summarizer: any ConversationSummarizing,
        audioSession: any AudioSessionConfiguring,
        synthesizer: any SpeechSynthesizing,
        taskStore: any TaskStoreV2 = InMemoryTaskStore(),
        idleRestoreDelay: Duration = .seconds(ConversationLayout.idleRestoreSeconds),
        speechSettleDelay: Duration = .milliseconds(380),
        scheduler: any TranslationScheduler
    ) {
        let lifecycle = TaskLifecycle(
            feature: .simultaneous,
            store: taskStore,
            gate: gate,
            permissions: permissions,
            audioSession: audioSession
        )
        self.lifecycle = lifecycle
        lateTranslation = LateTranslationBackfill(lifecycle: lifecycle)
        self.permissions = permissions
        self.preferences = preferences
        self.summarizer = summarizer
        self.audioSession = audioSession
        self.synthesizer = synthesizer
        self.idleRestoreDelay = idleRestoreDelay
        self.speechSettleDelay = speechSettleDelay
        self.pipeline = TranslationPipeline(scheduler: scheduler)
        sourceLanguage = preferences.sourceLanguage
        targetLanguage = preferences.targetLanguage
        fontSize = preferences.fontSize
        voiceOutEnabled = preferences.voiceOutEnabled
        showsSourceLine = preferences.showsSourceLine
    }

    /// Compatibility initializer for call sites and tests that inject a raw
    /// speech engine; the interpretation lifecycle gets its own gate around it.
    convenience init(
        speech: any SpeechRecognizing,
        permissions: any PermissionGranting,
        preferences: PreferencesStore,
        summarizer: any ConversationSummarizing,
        audioSession: any AudioSessionConfiguring,
        synthesizer: any SpeechSynthesizing,
        taskStore: any TaskStoreV2 = InMemoryTaskStore(),
        idleRestoreDelay: Duration = .seconds(ConversationLayout.idleRestoreSeconds),
        speechSettleDelay: Duration = .milliseconds(380)
    ) {
        self.init(
            gate: SpeechSessionGate(engine: speech),
            permissions: permissions,
            preferences: preferences,
            summarizer: summarizer,
            audioSession: audioSession,
            synthesizer: synthesizer,
            taskStore: taskStore,
            idleRestoreDelay: idleRestoreDelay,
            speechSettleDelay: speechSettleDelay
        )
    }

    var hasActiveTask: Bool { lifecycle.hasActiveTask }
    var taskStartedAt: Date? { lifecycle.startedAt }
    var isMemoryOnly: Bool { lifecycle.isMemoryOnly }
    var isNotSaved: Bool { lifecycle.isNotSaved }

    /// The language the user reads the interface in ("我看的语言"). UI copy and
    /// summaries follow it; `targetLanguage` stays the translation direction.
    var interfaceLanguage: AppLanguage { preferences.userLanguage }

    var canSummarize: Bool {
        transcript.contains { !$0.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var exportableSession: TaskSession {
        let startedAt = lifecycle.startedAt ?? .now
        return TaskSession(
            id: lifecycle.taskID ?? UUID(),
            feature: .simultaneous,
            status: hasActiveTask ? .running : .ended,
            startedAt: startedAt,
            endedAt: nil,
            title: TaskTitle.make(
                feature: .simultaneous,
                source: sourceLanguage,
                target: targetLanguage,
                startedAt: startedAt,
                language: interfaceLanguage
            ),
            subtitle: nil,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            entries: transcript,
            summary: summary
        )
    }

    var controlLabel: String {
        if !hasActiveTask {
            return Copy.needNewTask(for: interfaceLanguage)
        }
        switch sessionState {
        case .listening:
            return Copy.listening(for: interfaceLanguage)
        case .ready:
            return Copy.tapToStart(for: interfaceLanguage)
        case .paused:
            return Copy.paused(for: interfaceLanguage)
        case .preparing:
            return Copy.preparing(for: interfaceLanguage)
        case .failed, .idle:
            return Copy.tapToStart(for: interfaceLanguage)
        }
    }

    var errorText: String? {
        if case let .failed(error) = sessionState {
            return error.userMessage(for: interfaceLanguage)
        }
        return nil
    }

    var keepsScreenAwake: Bool {
        sessionState == .listening || holdScreenAfterPause
    }

    var voiceOutLabel: String {
        if let voiceOutBlockedMessage {
            return voiceOutBlockedMessage
        }
        if voiceOutEnabled {
            return Copy.voiceOutSpeaking(for: interfaceLanguage)
        }
        return Copy.voiceOut(for: interfaceLanguage)
    }

    var isVoiceOutBlocked: Bool {
        voiceOutBlockedMessage != nil
    }

    var pendingSpeechCount: Int {
        pendingJobs.count
    }

    /// The newest translation job that has not been drained yet; the pipeline
    /// owns the queue. Kept for tests.
    var outboundJob: TranslationJob? {
        pipeline.outboundJob
    }

    /// Bumps on every enqueue so the Host drains the pipeline queue instead of
    /// a single job observed through SwiftUI (which can coalesce two jobs).
    var outboundRevision: Int {
        pipeline.outboundRevision
    }

    func takeNextOutboundJob() -> TranslationJob? {
        pipeline.takeNextOutboundJob()
    }

    func bootstrap() async {
        startRouteObserver()
        canSpeakWithoutEcho = await audioSession.currentRoute().canSpeakWithoutEcho
        if voiceOutEnabled, !canSpeakWithoutEcho {
            voiceOutEnabled = false
            preferences.voiceOutEnabled = false
        }
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
    /// task first; captions are cleared only after it reports ready.
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
        lateTranslation.beginEnding()
        let prepareOutcome = await lifecycle.prepareForNewTask()
        lateTranslation.endEnding()
        switch prepareOutcome {
        case .ready:
            await lateTranslation.flushPending()
            await createNewTask()
        case .blockedByUnsavedTask:
            lateTranslation.discardPending()
            isUnsavedTaskPromptPresented = true
        case .notSaved:
            // Keep the task and captions; the not-saved banner explains why.
            lateTranslation.discardPending()
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
        // Stop this module's stream before cancelling the consumer so the
        // finished stream is classified as superseded, not interrupted. Wait
        // for the consumer so a final published during stop is applied before
        // the transcript snapshot is written.
        await lifecycle.pauseListening()
        await drainSpeechTask()
        isUnsavedTaskPromptPresented = false
        isExportThenContinuePending = false
        await clearSpeechQueue()
        lateTranslation.beginEnding()
        let outcome = await lifecycle.endTask(transcript: transcript, summary: summary)
        lateTranslation.endEnding()
        stateOverride = nil
        holdScreenAfterPause = false
        idleRestoreTask?.cancel()
        projection.setSpeakingHint(nil, pane: .user)
        switch outcome {
        case let .ended(session):
            await lateTranslation.flushPending()
            resetCaptions()
            resumePromptText = nil
            return session
        case .discardedEmpty:
            lateTranslation.discardPending()
            resetCaptions()
            resumePromptText = nil
            return nil
        case .notSaved:
            // Keep the transcript in memory for export; nothing was written.
            lateTranslation.discardPending()
            return nil
        }
    }

    func toggleListening() async {
        guard hasActiveTask else { return }
        if sessionState == .listening {
            await stop()
        } else {
            await start()
        }
    }

    func start() async {
        guard hasActiveTask, sessionState != .listening else { return }
        idleRestoreTask?.cancel()
        holdScreenAfterPause = false
        stateOverride = nil

        // Voice-out routing prechecks stay in the ViewModel; the lifecycle
        // starts listening only after the route is usable.
        if voiceOutEnabled {
            let allowed = await prepareVoiceOutRoute()
            if !allowed {
                await forceVoiceOutOff(reason: .voiceOutNeedsHeadphones)
            }
        }

        guard case let .started(handle) = await lifecycle.startListening(makeListeningRequest()) else {
            return
        }
        holdScreenAfterPause = false
        attachSpeechTask(handle)
    }

    func stop(restoreIdleTimerAfterDelay: Bool = true) async {
        let wasListening = sessionState == .listening
        if stateOverride == .listening {
            stateOverride = nil
        }
        // Clearing the lifecycle handle first keeps the cancelled stream from
        // being reported as a recognition interruption. Drain the consumer so
        // the engine's stop-time final reaches the transcript before the
        // speaking hint and queue are cleared.
        await lifecycle.pauseListening()
        await drainSpeechTask()
        await clearSpeechQueue()
        if wasListening {
            if restoreIdleTimerAfterDelay {
                holdScreenAfterPause = true
                scheduleIdleRestore()
            } else {
                holdScreenAfterPause = false
                idleRestoreTask?.cancel()
            }
        }
        projection.setSpeakingHint(nil, pane: .user)
    }

    /// Clears only what is on screen: pending captions are flushed first, then
    /// the pane, speaking hint, and summary presentation are cleared. The task,
    /// transcript, saved summary, listening session, and speech queue stay
    /// untouched. Export always uses the full transcript.
    func clearDisplay() async {
        await lifecycle.flush()
        projection.clearDisplay()
        isSummaryPresented = false
        isExportThenContinuePending = false
    }

    /// Full reset for a new task, an ended task, or a direction/language
    /// change; never for the display-only clear action.
    func resetCaptions() {
        projection.reset()
        pipeline.reset()
        spokenPrefixes.removeAll()
        lastSpokenTranslation = ""
        spokenCompactTail = ""
        cancelSpeechDebounces()
        summary = nil
        summaryError = nil
        Task { await clearSpeechQueue() }
    }

    /// Direction changes stop the current stream before the live caption is
    /// cleared and translation routing is rebuilt; listening does not resume
    /// automatically.
    func setSourceLanguage(_ language: AppLanguage) async {
        guard language != sourceLanguage else { return }
        let wasActive = sessionState == .listening || sessionState == .paused
        if language == targetLanguage {
            targetLanguage = sourceLanguage
            preferences.targetLanguage = targetLanguage
        }
        sourceLanguage = language
        preferences.sourceLanguage = language
        await applyDirectionChange(wasActive: wasActive)
    }

    func setTargetLanguage(_ language: AppLanguage) async {
        guard language != targetLanguage else { return }
        let wasActive = sessionState == .listening || sessionState == .paused
        if language == sourceLanguage {
            sourceLanguage = targetLanguage
            preferences.sourceLanguage = sourceLanguage
        }
        targetLanguage = language
        preferences.targetLanguage = language
        await applyDirectionChange(wasActive: wasActive)
    }

    func swapDirection() async {
        guard sourceLanguage != targetLanguage else { return }
        let wasActive = sessionState == .listening || sessionState == .paused
        let previousSource = sourceLanguage
        sourceLanguage = targetLanguage
        targetLanguage = previousSource
        preferences.sourceLanguage = sourceLanguage
        preferences.targetLanguage = targetLanguage
        await applyDirectionChange(wasActive: wasActive)
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
        Task { await clearSpeechQueue() }
    }

    func setFontSize(_ size: CaptionFontSize) {
        fontSize = size
        preferences.fontSize = size
    }

    func setShowsSourceLine(_ enabled: Bool) {
        showsSourceLine = enabled
        preferences.showsSourceLine = enabled
    }

    func setVoiceOutEnabled(_ enabled: Bool) async {
        let wasListening = sessionState == .listening
        if wasListening {
            await pauseCaptureForReroute()
        }

        if !enabled {
            voiceOutEnabled = false
            preferences.voiceOutEnabled = false
            voiceOutBlockedMessage = nil
            canSpeakWithoutEcho = false
            await clearSpeechQueue()
        } else {
            let hasVoice = await synthesizer.hasVoice(for: targetLanguage)
            if !hasVoice {
                await denyVoiceOut(.synthesisVoiceMissing)
            } else if await prepareVoiceOutRoute() {
                voiceOutEnabled = true
                preferences.voiceOutEnabled = true
                voiceOutBlockedMessage = nil
            } else {
                await denyVoiceOut(.voiceOutNeedsHeadphones)
            }
        }

        if wasListening {
            stateOverride = nil
            guard case let .started(handle) = await lifecycle.startListening(makeListeningRequest()) else {
                return
            }
            attachSpeechTask(handle)
        } else {
            try? await audioSession.activate(currentUseCase)
        }
    }

    func accept(_ utterance: Utterance) {
        guard utterance.language == sourceLanguage else { return }
        let text = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        projection.setSpeakingHint(
            utterance.isFinal ? nil : Copy.speaking(for: sourceLanguage),
            pane: .user
        )

        let normalized = Utterance(
            id: utterance.id,
            language: utterance.language,
            text: text,
            isFinal: utterance.isFinal,
            createdAt: utterance.createdAt
        )
        guard let line = projection.ingest(normalized, pane: .user, speaker: .peer) else {
            return
        }
        if line.phase == .settled {
            lifecycle.persist(projection.transcript)
        }
        enqueueTranslation(line, isFinal: utterance.isFinal)
    }

    func fulfill(job: TranslationJob, text: String) {
        guard let update = pipeline.accept(job: job, text: text) else { return }
        // A record that is gone means the task was ended and reset while this
        // translation was in flight. A final result still belongs in the
        // finished transcript; a preview does not.
        let hadRecord = projection.contains(utteranceID: update.utteranceID)
        let line = projection.applyTranslation(
            utteranceID: update.utteranceID,
            text: update.translatedText,
            settle: job.isFinal
        )
        if job.isFinal {
            lifecycle.persist(projection.transcript)
            lateTranslation.finalArrived(
                entryID: update.utteranceID,
                text: update.translatedText,
                hasLiveRecord: hadRecord
            )
        }
        guard let line, !lateTranslation.isEnding else { return }
        scheduleSpeech(
            utteranceID: update.utteranceID,
            translated: line.translatedText,
            settle: job.isFinal
        )
    }

    func failTranslation(job: TranslationJob, error: Error) {
        pipeline.fail(job: job)
    }

    /// Test seam: waits for a late-final backfill drain started by `fulfill`.
    func waitForTranslationBackfill() async {
        await lateTranslation.waitForDrain()
    }

    func requestSummary() async {
        summaryAvailability = await summarizer.availability()
        guard canSummarize else {
            summaryError = DuiyiError.summaryEmpty.userMessage(for: interfaceLanguage)
            isSummaryPresented = true
            return
        }
        isSettingsPresented = false
        isSummaryPresented = true
        isSummarizing = true
        summaryError = nil
        if summaryAvailability == .available {
            do {
                summary = try await summarizer.summarize(entries: transcript, outputLanguage: interfaceLanguage)
                if let summary {
                    await lifecycle.saveSummary(summary)
                }
            } catch let error as DuiyiError {
                summary = nil
                summaryError = error.userMessage(for: interfaceLanguage)
            } catch {
                summary = nil
                summaryError = DuiyiError.summaryEmpty.userMessage(for: interfaceLanguage)
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
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            multilingual: false,
            titleLanguage: interfaceLanguage,
            startedAt: .now,
            autoStart: false,
            listening: makeListeningRequest()
        )
    }

    private func makeListeningRequest() -> TaskLifecycle.ListeningRequest {
        TaskLifecycle.ListeningRequest(
            languages: [sourceLanguage],
            fallbackLanguage: sourceLanguage,
            style: .liveCaptions,
            audioUseCase: currentUseCase
        )
    }

    private var currentUseCase: AudioUseCase {
        voiceOutEnabled && canSpeakWithoutEcho ? .interpretationVoiceOut : .interpretationCaptions
    }

    private func prepareVoiceOutRoute() async -> Bool {
        do {
            try await audioSession.activate(.interpretationVoiceOut)
        } catch {
            canSpeakWithoutEcho = false
            return false
        }
        var snapshot = await audioSession.currentRoute()
        if !snapshot.canSpeakWithoutEcho {
            try? await Task.sleep(for: .milliseconds(200))
            snapshot = await audioSession.currentRoute()
        }
        canSpeakWithoutEcho = snapshot.canSpeakWithoutEcho
        return canSpeakWithoutEcho
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

    /// Stops this feature's capture without touching the task so the audio
    /// route can change underneath the session.
    private func pauseCaptureForReroute() async {
        await lifecycle.pauseListening()
        await drainSpeechTask()
    }

    private func rerouteCaptureIfListening() async {
        guard sessionState == .listening else {
            try? await audioSession.activate(currentUseCase)
            return
        }
        await lifecycle.pauseListening()
        await drainSpeechTask()
        stateOverride = nil
        guard case let .started(handle) = await lifecycle.startListening(makeListeningRequest()) else {
            return
        }
        attachSpeechTask(handle)
    }

    /// Stops the current stream before clearing the live caption and the
    /// direction-specific translation bookkeeping. Listening does not resume
    /// on its own.
    private func applyDirectionChange(wasActive: Bool) async {
        await lifecycle.pauseListening()
        await drainSpeechTask()
        projection.archiveLive(pane: .user)
        projection.setSpeakingHint(nil, pane: .user)
        pipeline.reset()
        spokenPrefixes.removeAll()
        lastSpokenTranslation = ""
        spokenCompactTail = ""
        cancelSpeechDebounces()
        // The view may already have entered asset preparation for the new
        // pair; never overwrite that transient state with a stale "ready".
        if wasActive, stateOverride != .preparing, stateOverride?.isFailed != true {
            stateOverride = .ready
        }
        await clearSpeechQueue()
    }

    private func enqueueTranslation(_ line: CaptionLine, isFinal: Bool) {
        let delays = translationDelays()
        pipeline.submit(
            TranslationSubmission(
                line: line,
                isFinal: isFinal,
                target: targetLanguage,
                firstDelay: delays.first,
                subsequentDelay: delays.subsequent
            )
        )
    }

    /// Voice-out keeps its tighter 25/50 ms cadence; captions keep 40/90 ms.
    private func translationDelays() -> (first: Duration, subsequent: Duration) {
        if voiceOutEnabled {
            return (.milliseconds(25), .milliseconds(50))
        }
        return (
            .milliseconds(ConversationLayout.firstTranslationDebounceMilliseconds),
            .milliseconds(ConversationLayout.translationDebounceMilliseconds)
        )
    }

    private func scheduleSpeech(utteranceID: UUID, translated: String, settle: Bool) {
        guard voiceOutEnabled, canSpeakWithoutEcho else { return }
        guard settle else { return }
        let slot = speechSlot(for: utteranceID, translated: translated)
        pendingSettledSpeech[slot] = translated
        if speechSettleDelay <= .zero {
            enqueueSpokenClauses(utteranceID: utteranceID, translated: translated, settle: true)
            pendingSettledSpeech[slot] = nil
            return
        }
        speechDebounces[slot]?.cancel()
        speechDebounces[slot] = Task { [weak self] in
            try? await Task.sleep(for: self?.speechSettleDelay ?? .milliseconds(380))
            guard !Task.isCancelled else { return }
            guard let text = self?.pendingSettledSpeech[slot] else { return }
            self?.pendingSettledSpeech[slot] = nil
            self?.speechDebounces[slot] = nil
            self?.enqueueSpokenClauses(utteranceID: utteranceID, translated: text, settle: true)
        }
    }

    private func speechSlot(for utteranceID: UUID, translated: String) -> UUID {
        if let existing = pendingSettledSpeech[utteranceID] {
            if SpokenText.shouldReplaceScheduledSpeech(existing, with: translated) {
                return utteranceID
            }
            return UUID()
        }
        if let match = pendingSettledSpeech.first(where: {
            SpokenText.shouldReplaceScheduledSpeech($0.value, with: translated)
        }) {
            speechDebounces[match.key]?.cancel()
            speechDebounces[match.key] = nil
            pendingSettledSpeech[match.key] = nil
            return match.key
        }
        return utteranceID
    }

    private func enqueueSpokenClauses(utteranceID: UUID, translated: String, settle: Bool) {
        guard voiceOutEnabled, canSpeakWithoutEcho else { return }
        var alreadySpoken = spokenPrefixes[utteranceID] ?? ""
        if alreadySpoken.isEmpty || alreadySpoken.count < lastSpokenTranslation.count,
           ClauseSplitter.shouldCarry(lastSpokenTranslation, into: translated, language: targetLanguage) {
            alreadySpoken = lastSpokenTranslation
        }
        let (clauses, prefix) = ClauseSplitter.consume(
            translated: translated,
            utteranceID: utteranceID,
            language: targetLanguage,
            alreadySpoken: alreadySpoken,
            isSettled: settle
        )
        if !prefix.isEmpty {
            spokenPrefixes[utteranceID] = prefix
            lastSpokenTranslation = prefix
        }
        guard !clauses.isEmpty else { return }
        let queuedCompact = pendingJobs.map { SpokenText.compact($0.text) }.joined()
        let alreadyHeard = alreadySpoken + spokenCompactTail + queuedCompact
        let fresh = clauses.filter { clause in
            !SpokenText.containsCompact(alreadyHeard, clause: clause.text)
        }
        guard !fresh.isEmpty else { return }
        for clause in fresh {
            pendingJobs.append(SynthesisJob(clause: clause))
        }
        dropSurplusShortConfirmations()
        pumpSpeech()
    }

    private func dropSurplusShortConfirmations() {
        while pendingJobs.count > InterpretationLayout.speechQueueLimit {
            guard let index = pendingJobs.firstIndex(where: {
                SpokenText.compact($0.text).count <= InterpretationLayout.speechShortConfirmationLimit
            }) else {
                break
            }
            pendingJobs.remove(at: index)
        }
    }

    private func rememberSpoken(_ text: String) {
        spokenCompactTail += SpokenText.compact(text)
        let limit = 280
        if spokenCompactTail.count > limit {
            spokenCompactTail.removeFirst(spokenCompactTail.count - limit)
        }
    }

    private func pumpSpeech() {
        guard !isSpeaking else { return }
        guard let next = pendingJobs.first else { return }
        pendingJobs.removeFirst()
        isSpeaking = true
        rememberSpoken(next.text)
        let generation = speechGeneration
        speakTask = Task { [weak self] in
            guard let self, !Task.isCancelled, generation == self.speechGeneration else { return }
            await self.synthesizer.speak(next)
            guard !Task.isCancelled, generation == self.speechGeneration else { return }
            self.isSpeaking = false
            self.pumpSpeech()
        }
    }

    private func cancelSpeechDebounces() {
        for task in speechDebounces.values {
            task.cancel()
        }
        speechDebounces.removeAll()
        pendingSettledSpeech.removeAll()
    }

    private func clearSpeechQueue() async {
        speechGeneration += 1
        cancelSpeechDebounces()
        speakTask?.cancel()
        speakTask = nil
        pendingJobs.removeAll()
        isSpeaking = false
        await synthesizer.stopAndClear()
    }

    private func denyVoiceOut(_ reason: DuiyiError) async {
        voiceOutEnabled = false
        preferences.voiceOutEnabled = false
        canSpeakWithoutEcho = false
        voiceOutBlockedMessage = reason.userMessage(for: interfaceLanguage)
        await clearSpeechQueue()
    }

    private func forceVoiceOutOff(reason: DuiyiError) async {
        await denyVoiceOut(reason)
        await rerouteCaptureIfListening()
    }

    private func startRouteObserver() {
        guard routeTask == nil else { return }
        routeTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.audioSession.routeChanges()
            for await snapshot in stream {
                self.handleRoute(snapshot)
            }
        }
    }

    private func handleRoute(_ snapshot: AudioRouteSnapshot) {
        canSpeakWithoutEcho = snapshot.canSpeakWithoutEcho
        guard voiceOutEnabled, !canSpeakWithoutEcho else { return }
        Task { await confirmHeadphonesLost() }
    }

    private func confirmHeadphonesLost() async {
        try? await Task.sleep(for: .milliseconds(300))
        let snapshot = await audioSession.currentRoute()
        canSpeakWithoutEcho = snapshot.canSpeakWithoutEcho
        guard voiceOutEnabled, !canSpeakWithoutEcho else { return }
        await forceVoiceOutOff(reason: .voiceOutNeedsHeadphones)
    }

    /// A superseded stream ends silently (the gate's other owner took over);
    /// only a still-current stream is a real recognition interruption.
    private func streamEnded(_ handle: SpeechSessionHandle) async {
        let interrupted = await lifecycle.handleStreamEnded(handle)
        guard interrupted else { return }
        holdScreenAfterPause = false
        idleRestoreTask?.cancel()
        projection.setSpeakingHint(nil, pane: .user)
        await clearSpeechQueue()
    }

    /// Applies the task's own language pair (not the current preferences) and
    /// restores its transcript and pane window with a "继续任务：…" prompt.
    private func applyRestored(_ session: TaskSession) {
        sourceLanguage = session.sourceLanguage
        preferences.sourceLanguage = session.sourceLanguage
        if let target = session.targetLanguage, target != session.sourceLanguage {
            targetLanguage = target
            preferences.targetLanguage = target
        }
        projection.restore(session.entries)
        summary = session.summary
        resumePromptText = Copy.continueTask(session.title, for: interfaceLanguage)
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
