import Foundation

@MainActor
@Observable
final class ConversationViewModel {
    private let lifecycle: TaskLifecycle
    private let permissions: any PermissionGranting
    private let preferences: PreferencesStore
    private let summarizer: any ConversationSummarizing

    /// Feature-specific transient states (asset preparation, preparation
    /// failure) layered over the lifecycle-owned session state.
    private var stateOverride: SessionState?

    var sessionState: SessionState {
        get { stateOverride ?? lifecycle.sessionState }
        set { stateOverride = newValue }
    }

    var userLanguage: AppLanguage
    var peerLanguage: AppLanguage
    var fontSize: CaptionFontSize
    var userPane = PaneState.empty
    var peerPane = PaneState.empty
    var isSettingsPresented = false
    var isSummaryPresented = false
    var outboundJob: TranslationJob?
    var autoStartListening: Bool
    var holdScreenAfterPause = false
    var transcript: [TranscriptEntry] = []
    var summary: ConversationSummary?
    var summaryError: String?
    var summaryAvailability: SummaryAvailability = .unavailable
    var isSummarizing = false
    /// Set when a new task is blocked by a memory-only task with content.
    var isUnsavedTaskPromptPresented = false
    /// The blocked task's summary/export sheet is open and the user chose
    /// "export and continue"; the sheet offers continue once the file is ready.
    var isExportThenContinuePending = false
    /// "继续任务：…" prompt shown after restoring an unfinished task.
    var resumePromptText: String?

    private var speechTask: Task<Void, Never>?
    private var translationDebounce: Task<Void, Never>?
    private var idleRestoreTask: Task<Void, Never>?
    private var routedSideByUtterance: [UUID: SpeakerSide] = [:]
    private var lastCommittedLanguage: AppLanguage?
    private var lastCommittedAt = Date.distantPast
    private var lastAppliedSourceCount: [UUID: Int] = [:]
    private var sentSourceText: [UUID: String] = [:]
    private var utteranceAliases: [UUID: UUID] = [:]
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
            feature: .faceToFace,
            store: taskStore,
            gate: gate,
            permissions: permissions,
            audioSession: audioSession
        )
        self.permissions = permissions
        self.preferences = preferences
        self.summarizer = summarizer
        self.idleRestoreDelay = idleRestoreDelay
        userLanguage = preferences.userLanguage
        peerLanguage = preferences.peerLanguage
        fontSize = preferences.fontSize
        autoStartListening = preferences.autoStartListening
    }

    /// Compatibility initializer for call sites and tests that inject a raw
    /// speech engine; the face-to-face lifecycle gets its own gate around it.
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

    var canSummarize: Bool {
        transcript.contains { !$0.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var exportableSession: TaskSession {
        let startedAt = lifecycle.startedAt ?? .now
        return TaskSession(
            id: lifecycle.taskID ?? UUID(),
            feature: .faceToFace,
            status: hasActiveTask ? .running : .ended,
            startedAt: startedAt,
            endedAt: nil,
            title: TaskTitle.make(
                feature: .faceToFace,
                source: userLanguage,
                target: peerLanguage,
                startedAt: startedAt,
                language: preferences.userLanguage
            ),
            subtitle: nil,
            sourceLanguage: userLanguage,
            targetLanguage: peerLanguage,
            entries: transcript,
            summary: summary
        )
    }

    var controlLabel: String {
        if !hasActiveTask {
            return Copy.needNewTask(for: userLanguage)
        }
        switch sessionState {
        case .listening:
            return Copy.listening(for: userLanguage)
        case .ready:
            return Copy.tapToStart(for: userLanguage)
        case .paused:
            return Copy.paused(for: userLanguage)
        case .preparing:
            return Copy.preparing(for: userLanguage)
        case .failed, .idle:
            return Copy.tapToStart(for: userLanguage)
        }
    }

    var userErrorText: String? {
        if case let .failed(error) = sessionState {
            return error.userMessage(for: userLanguage)
        }
        return nil
    }

    var keepsScreenAwake: Bool {
        sessionState == .listening || holdScreenAfterPause
    }

    var skipsBootstrap = false

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
        // Stop this module's stream before cancelling the consumer so the
        // finished stream is classified as superseded, not interrupted.
        await lifecycle.pauseListening()
        speechTask?.cancel()
        speechTask = nil
        isUnsavedTaskPromptPresented = false
        isExportThenContinuePending = false
        let outcome = await lifecycle.endTask(transcript: transcript, summary: summary)
        stateOverride = nil
        holdScreenAfterPause = false
        idleRestoreTask?.cancel()
        mutatePane(.user) { $0.speakingHint = nil }
        mutatePane(.peer) { $0.speakingHint = nil }
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
        // being reported as a recognition interruption.
        await lifecycle.pauseListening()
        speechTask?.cancel()
        speechTask = nil
        if wasListening {
            if restoreIdleTimerAfterDelay {
                holdScreenAfterPause = true
                scheduleIdleRestore()
            } else {
                holdScreenAfterPause = false
                idleRestoreTask?.cancel()
            }
        }
        mutatePane(.user) { $0.speakingHint = nil }
        mutatePane(.peer) { $0.speakingHint = nil }
    }

    /// Display-only clear: flush any pending captions first, then empty both
    /// panes and close the summary sheet. The transcript, summary data, task,
    /// routing bookkeeping, and listening stream stay untouched.
    func clearDisplay() async {
        await lifecycle.flush()
        userPane.resetCaptions()
        peerPane.resetCaptions()
        isSummaryPresented = false
        isExportThenContinuePending = false
    }

    func resetCaptions() {
        userPane.resetCaptions()
        peerPane.resetCaptions()
        transcript = []
        outboundJob = nil
        translationDebounce?.cancel()
        routedSideByUtterance.removeAll()
        lastCommittedLanguage = nil
        lastCommittedAt = .distantPast
        lastAppliedSourceCount.removeAll()
        sentSourceText.removeAll()
        utteranceAliases.removeAll()
        summary = nil
        summaryError = nil
    }

    /// Language/peer changes stop the current stream before the live captions
    /// are cleared and translation direction is rebuilt; listening does not
    /// resume automatically.
    func setUserLanguage(_ language: AppLanguage) async {
        guard language != userLanguage else { return }
        await pauseForLanguageChange()
        if language == peerLanguage {
            peerLanguage = userLanguage
            preferences.peerLanguage = peerLanguage
        }
        userLanguage = language
        preferences.userLanguage = language
        resetCaptions()
    }

    func setPeerLanguage(_ language: AppLanguage) async {
        guard language != peerLanguage else { return }
        await pauseForLanguageChange()
        if language == userLanguage {
            userLanguage = peerLanguage
            preferences.userLanguage = userLanguage
        }
        peerLanguage = language
        preferences.peerLanguage = language
        resetCaptions()
    }

    func swapLanguages() async {
        guard userLanguage != peerLanguage else { return }
        await pauseForLanguageChange()
        let previousUser = userLanguage
        userLanguage = peerLanguage
        peerLanguage = previousUser
        preferences.userLanguage = userLanguage
        preferences.peerLanguage = peerLanguage
        resetCaptions()
    }

    func enterPreparing() {
        idleRestoreTask?.cancel()
        holdScreenAfterPause = false
        sessionState = .preparing
    }

    func restoreReady() {
        guard sessionState == .preparing else { return }
        sessionState = .ready
    }

    func markPaused() {
        sessionState = .paused
    }

    func fail(_ error: DuiyiError) {
        sessionState = .failed(error)
        holdScreenAfterPause = false
        idleRestoreTask?.cancel()
    }

    func setFontSize(_ size: CaptionFontSize) {
        fontSize = size
        preferences.fontSize = size
    }

    func setAutoStartListening(_ enabled: Bool) {
        autoStartListening = enabled
        preferences.autoStartListening = enabled
    }

    func accept(_ utterance: Utterance) {
        if shouldIgnoreCrosstalk(utterance) {
            return
        }

        let listener: SpeakerSide
        if let pinned = routedSideByUtterance[utterance.id] {
            let detectedSide = LanguageRouter.targetSide(detected: utterance.language, userLanguage: userLanguage)
            if detectedSide != pinned {
                return
            }
            listener = pinned
        } else {
            listener = LanguageRouter.targetSide(detected: utterance.language, userLanguage: userLanguage)
            routedSideByUtterance[utterance.id] = listener
        }

        let speaker = listener.opposite
        let speaking = Copy.speaking(for: speaker == .user ? userLanguage : peerLanguage)

        if utterance.isFinal {
            mutatePane(speaker) { $0.speakingHint = nil }
            lastCommittedLanguage = utterance.language
            lastCommittedAt = .now
        } else {
            mutatePane(speaker) { $0.speakingHint = speaking }
            mutatePane(listener) { $0.speakingHint = nil }
        }

        let existing = pane(listener).live
        let captionID: UUID
        let carriedTranslation: String
        if let existing, existing.source == utterance.language,
           SpokenText.isDistinctGreeting(
            incomingSource: utterance.text,
            incomingDisplay: utterance.text,
            previousSource: existing.sourceText,
            previousDisplay: existing.displayText
           ) {
            captionID = UUID()
            carriedTranslation = ""
            utteranceAliases[utterance.id] = captionID
        } else if let existing, existing.source == utterance.language,
           SpokenText.isContinuation(utterance.text, of: existing.sourceText, language: utterance.language) {
            captionID = existing.id
            carriedTranslation = existing.translatedText
            utteranceAliases[utterance.id] = existing.id
        } else {
            captionID = utterance.id
            carriedTranslation = existing?.id == utterance.id ? existing?.translatedText ?? "" : ""
        }

        let line = CaptionLine(
            id: captionID,
            side: listener,
            source: utterance.language,
            sourceText: utterance.text,
            translatedText: carriedTranslation,
            phase: utterance.isFinal ? .settled : .streaming
        )
        var applied = line
        mutatePane(listener) {
            applied = $0.applyLive(line)
            $0.trimHistory(to: ConversationLayout.paneHistoryLimit)
        }
        upsertTranscript(line: applied, speaker: speaker)
        enqueueTranslation(applied, isFinal: utterance.isFinal)
    }

    func fulfill(job: TranslationJob, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !job.isFinal, let applied = lastAppliedSourceCount[canonicalID(job.utteranceID)], applied > job.text.count {
            return
        }
        let utteranceID = canonicalID(job.utteranceID)
        lastAppliedSourceCount[utteranceID] = max(lastAppliedSourceCount[utteranceID] ?? 0, job.text.count)
        applyTranslation(utteranceID: utteranceID, text: trimmed, settle: job.isFinal)
        if outboundJob?.id == job.id {
            outboundJob = nil
        }
    }

    func failTranslation(job: TranslationJob, error: Error) {
        if outboundJob?.id == job.id {
            outboundJob = nil
        }
    }

    func requestSummary() async {
        summaryAvailability = await summarizer.availability()
        guard canSummarize else {
            summaryError = DuiyiError.summaryEmpty.userMessage(for: userLanguage)
            isSummaryPresented = true
            return
        }
        isSettingsPresented = false
        isSummaryPresented = true
        isSummarizing = true
        summaryError = nil
        if summaryAvailability == .available {
            do {
                summary = try await summarizer.summarize(entries: transcript, outputLanguage: userLanguage)
                if let summary {
                    await lifecycle.saveSummary(summary)
                }
            } catch let error as DuiyiError {
                summary = nil
                summaryError = error.userMessage(for: userLanguage)
            } catch {
                summary = nil
                summaryError = DuiyiError.summaryEmpty.userMessage(for: userLanguage)
            }
        } else {
            summary = nil
        }
        isSummarizing = false
    }

    private func enqueueTranslation(_ line: CaptionLine, isFinal: Bool) {
        let text = line.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if sentSourceText[line.id] == text, !isFinal {
            return
        }

        let job = TranslationJob(
            utteranceID: line.id,
            source: line.source,
            target: LanguageRouter.targetLanguage(
                detected: line.source,
                userLanguage: userLanguage,
                peerLanguage: peerLanguage
            ),
            text: text,
            isFinal: isFinal
        )
        let isFirst = sentSourceText[line.id] == nil
        let shouldFlush = isFinal
            || Self.endsWithClause(text)
            || (isFirst && Self.isWorthTranslating(text, language: line.source))

        translationDebounce?.cancel()
        if shouldFlush {
            sentSourceText[line.id] = text
            outboundJob = job
            return
        }
        let delay = isFirst
            ? ConversationLayout.firstTranslationDebounceMilliseconds
            : ConversationLayout.translationDebounceMilliseconds
        translationDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            self?.sentSourceText[line.id] = text
            self?.outboundJob = job
        }
    }

    private func applyTranslation(utteranceID: UUID, text: String, settle: Bool) {
        mutatePane(.user) { $0.applyTranslation(utteranceID: utteranceID, text: text, settle: settle) }
        mutatePane(.peer) { $0.applyTranslation(utteranceID: utteranceID, text: text, settle: settle) }
        if let index = transcript.firstIndex(where: { $0.id == utteranceID }) {
            transcript[index].translatedText = text
            if settle {
                transcript[index].isFinal = true
                lifecycle.persist(transcript)
            }
        }
    }

    private func upsertTranscript(line: CaptionLine, speaker: SpeakerSide) {
        if let index = transcript.firstIndex(where: { $0.id == line.id }) {
            transcript[index].sourceText = SpokenText.preferredSource(transcript[index].sourceText, line.sourceText)
            if !line.translatedText.isEmpty {
                transcript[index].translatedText = line.translatedText
            }
            transcript[index].isFinal = line.phase == .settled
            dropPrefixTranscript(after: index, speaker: speaker, language: line.source)
            if line.phase == .settled {
                lifecycle.persist(transcript)
            }
            return
        }
        if let last = transcript.last,
           last.speaker == speaker,
           SpokenText.isContinuation(line.sourceText, of: last.sourceText, language: line.source) {
            var updated = last
            updated.sourceText = SpokenText.preferredSource(last.sourceText, line.sourceText)
            if !line.translatedText.isEmpty {
                updated.translatedText = line.translatedText
            }
            updated.isFinal = line.phase == .settled
            transcript[transcript.count - 1] = updated
            dropPrefixTranscript(after: transcript.count - 1, speaker: speaker, language: line.source)
            if line.phase == .settled {
                lifecycle.persist(transcript)
            }
            return
        }
        transcript.append(
            TranscriptEntry(
                id: line.id,
                speaker: speaker,
                source: line.source,
                sourceText: line.sourceText,
                translatedText: line.translatedText,
                isFinal: line.phase == .settled
            )
        )
        if line.phase == .settled {
            lifecycle.persist(transcript)
        }
    }

    private func dropPrefixTranscript(after index: Int, speaker: SpeakerSide, language: AppLanguage) {
        let current = transcript[index]
        var cursor = index
        while cursor > 0 {
            let prior = transcript[cursor - 1]
            guard prior.speaker == speaker,
                  SpokenText.isContinuation(current.sourceText, of: prior.sourceText, language: language) else {
                break
            }
            transcript.remove(at: cursor - 1)
            cursor -= 1
        }
    }

    private func canonicalID(_ id: UUID) -> UUID {
        utteranceAliases[id] ?? id
    }

    private func shouldIgnoreCrosstalk(_ utterance: Utterance) -> Bool {
        guard let lastCommittedLanguage else { return false }
        guard Date().timeIntervalSince(lastCommittedAt) < 1.0 else { return false }
        guard utterance.language != lastCommittedLanguage else { return false }
        return !UtteranceAssembler.isConfident(utterance.text, language: utterance.language)
    }

    private func pane(_ side: SpeakerSide) -> PaneState {
        switch side {
        case .user: return userPane
        case .peer: return peerPane
        }
    }

    private func mutatePane(_ side: SpeakerSide, _ body: (inout PaneState) -> Void) {
        switch side {
        case .user:
            body(&userPane)
        case .peer:
            body(&peerPane)
        }
    }

    private func createNewTask() async {
        // The lifecycle already stopped the old stream; drop any stale buffered
        // utterances so they cannot land in the new task.
        speechTask?.cancel()
        speechTask = nil
        resetCaptions()
        resumePromptText = nil
        switch await lifecycle.startNewTask(makeNewTaskRequest()) {
        case let .started(handle):
            stateOverride = nil
            if let handle {
                attachSpeechTask(handle)
            }
        case let .notPersisted(_, handle):
            // The memory-only task is live; consume its auto-started stream
            // immediately so autoStart still records speech.
            stateOverride = nil
            if let handle {
                attachSpeechTask(handle)
            }
        case .failed:
            // Leave the lifecycle's failed state visible for the user.
            break
        }
    }

    private func makeNewTaskRequest() -> TaskLifecycle.NewTaskRequest {
        TaskLifecycle.NewTaskRequest(
            sourceLanguage: userLanguage,
            targetLanguage: peerLanguage,
            multilingual: false,
            titleLanguage: preferences.userLanguage,
            startedAt: .now,
            autoStart: autoStartListening,
            listening: makeListeningRequest()
        )
    }

    private func makeListeningRequest() -> TaskLifecycle.ListeningRequest {
        TaskLifecycle.ListeningRequest(
            languages: [userLanguage, peerLanguage],
            fallbackLanguage: peerLanguage,
            style: .liveCaptions,
            audioUseCase: .faceToFace
        )
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

    /// A superseded stream ends silently (the gate's other owner took over);
    /// only a still-current stream is a real recognition interruption.
    private func streamEnded(_ handle: SpeechSessionHandle) async {
        let interrupted = await lifecycle.handleStreamEnded(handle)
        guard interrupted else { return }
        holdScreenAfterPause = false
        idleRestoreTask?.cancel()
        mutatePane(.user) { $0.speakingHint = nil }
        mutatePane(.peer) { $0.speakingHint = nil }
    }

    /// Stops capture before the pair is mutated and the live captions are
    /// cleared, so an old-direction stream cannot write into the new routing.
    private func pauseForLanguageChange() async {
        let wasActive = sessionState == .listening || sessionState == .paused
        await lifecycle.pauseListening()
        speechTask?.cancel()
        speechTask = nil
        // The view may already have entered asset preparation for the new
        // pair; never overwrite that transient state with a stale "ready".
        if wasActive, stateOverride != .preparing, stateOverride?.isFailed != true {
            stateOverride = .ready
        }
    }

    /// Applies the task's own language pair (not the current preferences) and
    /// restores its transcript and pane window with a "继续任务：…" prompt.
    private func applyRestored(_ session: TaskSession) {
        userLanguage = session.sourceLanguage
        preferences.userLanguage = session.sourceLanguage
        if let target = session.targetLanguage, target != session.sourceLanguage {
            peerLanguage = target
            preferences.peerLanguage = target
        }
        transcript = session.entries
        summary = session.summary
        userPane = .empty
        peerPane = .empty
        for entry in session.entries {
            let listener = entry.speaker.opposite
            mutatePane(listener) {
                $0.history.append(
                    CaptionLine(
                        id: entry.id,
                        side: listener,
                        source: entry.source,
                        sourceText: entry.sourceText,
                        translatedText: entry.translatedText,
                        phase: .settled
                    )
                )
                $0.trimHistory(to: ConversationLayout.paneHistoryLimit)
            }
        }
        resumePromptText = Copy.continueTask(session.title, for: userLanguage)
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

    static func endsWithClause(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return last.unicodeScalars.allSatisfy { ClauseSplitter.terminators.contains($0) }
    }

    static func isWorthTranslating(_ text: String, language: AppLanguage) -> Bool {
        switch language {
        case .zhHans:
            return UtteranceAssembler.hanCount(text) >= 2
        case .english:
            return UtteranceAssembler.wordCount(text) >= 2 || text.count >= 8
        case .japanese:
            return UtteranceAssembler.kanaCount(text) + UtteranceAssembler.hanCount(text) >= 2
        case .korean:
            return UtteranceAssembler.hangulCount(text) >= 2
        case .thai:
            return UtteranceAssembler.thaiCount(text) >= 2
        case .vietnamese:
            return UtteranceAssembler.wordCount(text) >= 2
                || UtteranceAssembler.vietnameseMarkCount(text) >= 1
                || text.count >= 8
        }
    }
}
