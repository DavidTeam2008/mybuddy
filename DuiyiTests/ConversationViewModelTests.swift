import Foundation
import Testing
@testable import Duiyi

actor MockSpeechEngine: SpeechRecognizing {
    private var continuation: AsyncStream<Utterance>.Continuation?

    func start(
        languages: [AppLanguage],
        fallbackLanguage: AppLanguage,
        style: SpeechRecognitionStyle
    ) async throws -> AsyncStream<Utterance> {
        _ = languages
        _ = fallbackLanguage
        _ = style
        let (stream, continuation) = AsyncStream<Utterance>.makeStream()
        self.continuation = continuation
        return stream
    }

    func stop() async {
        continuation?.finish()
        continuation = nil
    }

    func emit(_ utterance: Utterance) {
        continuation?.yield(utterance)
    }
}

struct MockPermissions: PermissionGranting {
    var status: PermissionStatus = .granted

    func currentStatus() async -> PermissionStatus { status }
    func requestAccess() async -> PermissionStatus { status }
}

struct MockSummarizer: ConversationSummarizing {
    var summary = ConversationSummary(text: "双方约定喝咖啡。", usedAppleIntelligence: true)

    func availability() async -> SummaryAvailability { .available }

    func summarize(
        entries: [TranscriptEntry],
        outputLanguage: AppLanguage
    ) async throws -> ConversationSummary {
        _ = entries
        _ = outputLanguage
        return summary
    }
}

@MainActor
struct ConversationViewModelTests {
    @Test("English speech for a Chinese-reading user lands on the user pane")
    func englishSpeechRoutesToUserPane() async {
        let speech = MockSpeechEngine()
        let viewModel = ConversationViewModel(
            speech: speech,
            permissions: MockPermissions(),
            preferences: PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString) ?? .standard),
            summarizer: MockSummarizer()
        )
        await viewModel.setUserLanguage(.zhHans)

        let utterance = Utterance(language: .english, text: "See you at three", isFinal: false)
        viewModel.accept(utterance)

        #expect(viewModel.userPane.live?.sourceText == "See you at three")
        #expect(viewModel.peerPane.speakingHint != nil)
        #expect(viewModel.userPane.speakingHint == nil)
    }

    @Test("Chinese speech for a Chinese-reading user lands on the peer pane")
    func chineseSpeechRoutesToPeerPane() async {
        let viewModel = ConversationViewModel(
            speech: MockSpeechEngine(),
            permissions: MockPermissions(),
            preferences: PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString) ?? .standard),
            summarizer: MockSummarizer()
        )
        await viewModel.setUserLanguage(.zhHans)

        viewModel.accept(Utterance(language: .zhHans, text: "三点见", isFinal: true))

        #expect(viewModel.peerPane.live?.sourceText == "三点见")
        #expect(viewModel.userPane.live == nil)
    }

    @Test("Stale translation jobs are ignored")
    func staleTranslationDropped() async {
        let viewModel = ConversationViewModel(
            speech: MockSpeechEngine(),
            permissions: MockPermissions(),
            preferences: PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString) ?? .standard),
            summarizer: MockSummarizer()
        )
        await viewModel.setUserLanguage(.zhHans)

        let first = Utterance(id: UUID(), language: .english, text: "Hello", isFinal: false)
        let second = Utterance(id: UUID(), language: .english, text: "Goodbye", isFinal: false)
        viewModel.accept(first)
        viewModel.accept(second)

        viewModel.fulfill(
            job: TranslationJob(utteranceID: first.id, source: .english, target: .zhHans, text: "Hello", isFinal: true),
            text: "你好"
        )

        #expect(viewModel.userPane.live?.id == second.id)
        #expect(viewModel.userPane.live?.translatedText != "你好")
        #expect(viewModel.userPane.history.first?.translatedText == "你好")
    }

    @Test("Clearing captions empties both panes")
    func resetCaptions() async {
        let viewModel = ConversationViewModel(
            speech: MockSpeechEngine(),
            permissions: MockPermissions(),
            preferences: PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString) ?? .standard),
            summarizer: MockSummarizer()
        )
        viewModel.accept(Utterance(language: .english, text: "Hello", isFinal: true))
        viewModel.resetCaptions()
        #expect(viewModel.userPane.live == nil)
        #expect(viewModel.peerPane.live == nil)
        #expect(viewModel.outboundJob == nil)
    }

    @Test("Clearing the display flushes captions, keeps transcript and task, and later lines append")
    func clearDisplayKeepsTranscriptAndStore() async {
        let store = InMemoryTaskStore()
        let gate = ConversationFakeGate()
        let viewModel = makeGateViewModel(gate: gate, store: store)
        await viewModel.beginTask()

        gate.emit(Utterance(language: .english, text: "See you at three", isFinal: true))
        await waitUntil { viewModel.transcript.count == 1 }
        gate.emit(Utterance(language: .zhHans, text: "好的我知道了", isFinal: false))
        await waitUntil { viewModel.transcript.count == 2 }
        viewModel.isSummaryPresented = true
        viewModel.summary = ConversationSummary(text: "约定三点见。", usedAppleIntelligence: true)

        #expect(viewModel.userPane.speakingHint != nil)

        await viewModel.clearDisplay()

        #expect(viewModel.userPane == .empty)
        #expect(viewModel.peerPane == .empty)
        #expect(!viewModel.isSummaryPresented)
        #expect(viewModel.summary?.text == "约定三点见。")
        #expect(viewModel.transcript.map(\.sourceText) == ["See you at three", "好的我知道了"])
        #expect(viewModel.hasActiveTask)
        #expect(viewModel.sessionState == .listening)
        #expect(gate.stopCount == 0)
        let active = await store.activeTask(for: .faceToFace)
        #expect(active?.entries.map(\.sourceText) == ["See you at three"])

        // Later captions keep appending to the same transcript.
        gate.emit(Utterance(language: .english, text: "Bring the contract", isFinal: true))
        await waitUntil { viewModel.transcript.count == 3 }
        #expect(viewModel.transcript.map(\.sourceText) == ["See you at three", "好的我知道了", "Bring the contract"])
    }

    @Test("Same utterance cannot flip onto the other pane")
    func languageFlipOnSameUtteranceIsDropped() async {
        let viewModel = makeViewModel()
        await viewModel.setUserLanguage(.zhHans)
        let id = UUID()
        viewModel.accept(Utterance(id: id, language: .english, text: "you are right", isFinal: false))
        viewModel.accept(Utterance(id: id, language: .zhHans, text: "你是对的", isFinal: false))

        #expect(viewModel.userPane.live?.sourceText == "you are right")
        #expect(viewModel.peerPane.live == nil)
    }

    @Test("Weak opposite-language leftovers after a commit do not overwrite the other pane")
    func weakOppositeLanguageAfterCommitIsDropped() async {
        let viewModel = makeViewModel()
        await viewModel.setUserLanguage(.zhHans)
        viewModel.accept(
            Utterance(language: .zhHans, text: "然后我给你介绍一下北京有哪些好玩的", isFinal: true)
        )
        viewModel.accept(Utterance(language: .english, text: "No okay", isFinal: true))

        #expect(viewModel.peerPane.live?.sourceText.contains("北京") == true)
        #expect(viewModel.userPane.live == nil)
    }

    @Test("Pause keeps the screen awake until the restore delay elapses")
    func pauseHoldsIdleTimerThenReleases() async throws {
        let viewModel = makeViewModel(idleRestoreDelay: .milliseconds(40))
        viewModel.autoStartListening = true
        await viewModel.bootstrap()
        await viewModel.beginTask()
        #expect(viewModel.sessionState == .listening)
        #expect(viewModel.keepsScreenAwake)

        await viewModel.stop()
        #expect(viewModel.sessionState == .paused)
        #expect(viewModel.keepsScreenAwake)

        try await Task.sleep(for: .milliseconds(80))
        #expect(!viewModel.keepsScreenAwake)
    }

    @Test("Bootstrap stays ready when auto-start is disabled")
    func bootstrapRespectsAutoStartOff() async {
        let preferences = PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString) ?? .standard)
        preferences.autoStartListening = false
        let viewModel = ConversationViewModel(
            speech: MockSpeechEngine(),
            permissions: MockPermissions(),
            preferences: preferences,
            summarizer: MockSummarizer()
        )
        await viewModel.bootstrap()
        #expect(viewModel.sessionState == .ready)
        #expect(!viewModel.keepsScreenAwake)
    }

    @Test("Auto-start preference is stored")
    func autoStartPreferencePersists() {
        let viewModel = makeViewModel()
        viewModel.setAutoStartListening(false)
        #expect(viewModel.autoStartListening == false)
    }

    @Test("Settled captions stay in history when a new utterance starts")
    func historyKeepsPreviousCaptions() async {
        let viewModel = makeViewModel()
        await viewModel.setUserLanguage(.zhHans)
        let first = Utterance(language: .english, text: "See you at three", isFinal: true)
        let second = Utterance(language: .english, text: "I'd like coffee", isFinal: false)
        viewModel.accept(first)
        viewModel.fulfill(
            job: TranslationJob(utteranceID: first.id, source: .english, target: .zhHans, text: first.text, isFinal: true),
            text: "三点见"
        )
        viewModel.accept(second)

        #expect(viewModel.userPane.history.count == 1)
        #expect(viewModel.userPane.history.first?.translatedText == "三点见")
        #expect(viewModel.userPane.live?.sourceText == "I'd like coffee")
        #expect(viewModel.canSummarize)
    }

    @Test("Growing restatements of the same sentence stay on one live line")
    func continuationDoesNotCreateHistoryRows() async {
        let viewModel = makeViewModel()
        await viewModel.setUserLanguage(.zhHans)
        let first = Utterance(
            language: .english,
            text: "The more inference added to the database",
            isFinal: true
        )
        let second = Utterance(
            language: .english,
            text: "The more inference added to the database of media from plot TV to games the better the prediction model",
            isFinal: true
        )
        viewModel.accept(first)
        viewModel.fulfill(
            job: TranslationJob(utteranceID: first.id, source: .english, target: .zhHans, text: first.text, isFinal: true),
            text: "从数据库中添加的推理越多"
        )
        viewModel.accept(second)
        viewModel.fulfill(
            job: TranslationJob(utteranceID: second.id, source: .english, target: .zhHans, text: second.text, isFinal: true),
            text: "从情节电视到游戏等媒体的数据库中添加的推理越多，预测模型就越好。"
        )

        #expect(viewModel.userPane.history.isEmpty)
        #expect(viewModel.userPane.live?.sourceText == second.text)
        #expect(viewModel.userPane.live?.translatedText.contains("预测模型") == true)
        #expect(viewModel.transcript.count == 1)
    }

    @Test("Japanese speech for a Chinese-reading user lands on the user pane")
    func japaneseSpeechRoutesToUserPane() async {
        let viewModel = makeViewModel()
        await viewModel.setUserLanguage(.zhHans)
        await viewModel.setPeerLanguage(.japanese)
        viewModel.accept(Utterance(language: .japanese, text: "コーヒーをください", isFinal: false))

        #expect(viewModel.userPane.live?.sourceText == "コーヒーをください")
        #expect(viewModel.peerPane.speakingHint != nil)
        #expect(viewModel.userLanguage == .zhHans)
        #expect(viewModel.peerLanguage == .japanese)
    }

    @Test("Picking the peer's language swaps the pair")
    func selectingPeerLanguageSwaps() async {
        let viewModel = makeViewModel()
        await viewModel.setUserLanguage(.zhHans)
        await viewModel.setPeerLanguage(.korean)
        await viewModel.setUserLanguage(.korean)

        #expect(viewModel.userLanguage == .korean)
        #expect(viewModel.peerLanguage == .zhHans)
    }

    @Test("Swap exchanges the two reading languages and clears live captions")
    func swapLanguagesExchangesPair() async {
        let viewModel = makeViewModel()
        await viewModel.setUserLanguage(.zhHans)
        await viewModel.setPeerLanguage(.thai)
        viewModel.accept(Utterance(language: .thai, text: "สวัสดี", isFinal: true))
        await viewModel.swapLanguages()

        #expect(viewModel.userLanguage == .thai)
        #expect(viewModel.peerLanguage == .zhHans)
        #expect(viewModel.userPane.live == nil)
        #expect(viewModel.peerPane.live == nil)
    }

    @Test("Changing language mid-conversation clears captions for the new pair")
    func changingLanguageClearsCaptions() async {
        let viewModel = makeViewModel()
        await viewModel.setUserLanguage(.zhHans)
        await viewModel.setPeerLanguage(.english)
        viewModel.accept(Utterance(language: .english, text: "See you at three", isFinal: true))
        await viewModel.setPeerLanguage(.japanese)

        #expect(viewModel.peerLanguage == .japanese)
        #expect(viewModel.userLanguage == .zhHans)
        #expect(viewModel.userPane.live == nil)
        #expect(viewModel.peerPane.live == nil)
    }

    @Test("Face-to-face still starts exactly two locales")
    func startUsesTwoLocales() async {
        let speech = RecordingSpeechEngine()
        let preferences = PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString) ?? .standard)
        preferences.userLanguage = .zhHans
        preferences.peerLanguage = .english
        preferences.autoStartListening = false
        let viewModel = ConversationViewModel(
            speech: speech,
            permissions: MockPermissions(),
            preferences: preferences,
            summarizer: MockSummarizer()
        )
        await viewModel.beginTask()
        await viewModel.start()
        let started = await speech.startedLanguages
        #expect(started == [.zhHans, .english])
    }

    @Test("Summary uses the on-device summarizer after a conversation")
    func summaryUsesInjectedSummarizer() async {
        let viewModel = makeViewModel()
        await viewModel.setUserLanguage(.zhHans)
        viewModel.accept(Utterance(language: .english, text: "Let's get coffee", isFinal: true))
        await viewModel.requestSummary()
        #expect(viewModel.summary?.text == "双方约定喝咖啡。")
        #expect(viewModel.isSummaryPresented)
    }

    @Test("Auto-start off leaves a new task ready without starting the gate")
    func autoStartOffStaysReady() async {
        let gate = ConversationFakeGate()
        let preferences = PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString) ?? .standard)
        preferences.autoStartListening = false
        let viewModel = ConversationViewModel(
            gate: gate,
            permissions: MockPermissions(),
            preferences: preferences,
            summarizer: MockSummarizer()
        )

        await viewModel.beginTask()

        #expect(viewModel.hasActiveTask)
        #expect(viewModel.sessionState == .ready)
        #expect(gate.startCount == 0)
    }

    @Test("Auto-start consumes the started handle and routes live speech")
    func autoStartConsumesStartedHandle() async {
        let gate = ConversationFakeGate()
        let viewModel = makeGateViewModel(gate: gate)

        await viewModel.beginTask()

        #expect(viewModel.sessionState == .listening)
        #expect(gate.startCount == 1)
        #expect(gate.starts.first?.languages == [.zhHans, .english])

        gate.emit(Utterance(language: .english, text: "See you at three", isFinal: false))
        await waitUntil { viewModel.userPane.live?.sourceText == "See you at three" }

        #expect(viewModel.userPane.live?.sourceText == "See you at three")
    }

    @Test("Auto-start consumes the handle when the task is memory-only")
    func autoStartConsumesHandleForMemoryOnlyTask() async {
        let store = ScriptedTaskStore()
        store.startNewFailure = .saveFailed
        let gate = ConversationFakeGate()
        let viewModel = makeGateViewModel(gate: gate, store: store)

        await viewModel.beginTask()

        #expect(viewModel.hasActiveTask)
        #expect(viewModel.isMemoryOnly)
        #expect(viewModel.showsNotSavedBanner)
        #expect(viewModel.sessionState == .listening)
        #expect(gate.startCount == 1)

        gate.emit(Utterance(language: .english, text: "Only in memory", isFinal: false))
        await waitUntil { viewModel.userPane.live?.sourceText == "Only in memory" }

        #expect(viewModel.userPane.live?.sourceText == "Only in memory")
    }

    @Test("Beginning a new task stops the old stream before ending it")
    func beginStopsOldStreamBeforeEnding() async {
        let log = ConversationEventLog()
        let store = ScriptedTaskStore()
        store.eventSink = { log.record($0) }
        let gate = ConversationFakeGate()
        gate.eventSink = { log.record($0) }
        let viewModel = makeGateViewModel(gate: gate, store: store)

        await viewModel.beginTask()
        gate.emit(Utterance(language: .zhHans, text: "旧任务最后一句", isFinal: true))
        await waitUntil { viewModel.transcript.count == 1 }

        await viewModel.beginTask()

        let stopIndex = log.firstIndex(of: "gate-stop")
        let endIndex = log.firstIndex(of: "store-end")
        #expect(stopIndex != nil && endIndex != nil && stopIndex! < endIndex!)
        #expect(viewModel.transcript.isEmpty)
        #expect(gate.startCount == 2)

        let active = await store.base.activeTask(for: .faceToFace)
        #expect(active?.entries.isEmpty == true)
        let ended = await store.base.list(filter: .faceToFace)
        #expect(ended.first?.entries.contains { $0.sourceText == "旧任务最后一句" } == true)
    }

    @Test("Ending flushes the last settled line into history")
    func endFlushesPendingCaption() async {
        let store = InMemoryTaskStore()
        let viewModel = makeGateViewModel(
            gate: ConversationFakeGate(),
            store: store,
            autoStart: false
        )
        await viewModel.beginTask()
        viewModel.accept(Utterance(language: .zhHans, text: "最后一句话", isFinal: true))

        let ended = await viewModel.endTask()

        #expect(ended?.entries.map(\.sourceText) == ["最后一句话"])
        #expect(viewModel.transcript.isEmpty)
        #expect(await store.list(filter: .faceToFace).count == 1)
    }

    @Test("An end that cannot be saved keeps transcript and writes no history")
    func notSavedEndKeepsTranscript() async {
        let store = ScriptedTaskStore()
        let viewModel = makeGateViewModel(
            gate: ConversationFakeGate(),
            store: store,
            autoStart: false
        )
        await viewModel.beginTask()
        viewModel.accept(Utterance(language: .zhHans, text: "还没保存的内容", isFinal: true))
        store.endFailure = .saveFailed

        let ended = await viewModel.endTask()

        #expect(ended == nil)
        #expect(viewModel.transcript.map(\.sourceText) == ["还没保存的内容"])
        #expect(viewModel.hasActiveTask)
        #expect(viewModel.showsNotSavedBanner)
        #expect(viewModel.sessionState == .paused)
        #expect(viewModel.peerPane.live?.sourceText == "还没保存的内容")
        #expect(viewModel.exportableSession.entries.map(\.sourceText) == ["还没保存的内容"])
        #expect(await store.base.list(filter: .faceToFace).isEmpty)
        #expect(store.endCalls == 1)
    }

    @Test("Restoring applies the task language pair and shows the continue prompt")
    func restoreAppliesLanguagePairAndPrompt() async throws {
        let store = InMemoryTaskStore()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let title = TaskTitle.make(
            feature: .faceToFace,
            source: .zhHans,
            target: .english,
            startedAt: startedAt,
            language: .zhHans
        )
        let draft = TaskDraft(
            feature: .faceToFace,
            sourceLanguage: .zhHans,
            targetLanguage: .english,
            multilingual: false,
            startedAt: startedAt,
            title: title
        )
        guard case let .persisted(seeded) = await store.startNew(draft) else {
            Issue.record("Could not seed the running task")
            return
        }
        _ = await store.append([makeEntry("Restored line")], to: seeded.id)
        _ = await store.setStatus(.pausedListening, for: seeded.id)

        let preferences = makePreferences(userLanguage: .english, peerLanguage: .zhHans)
        let viewModel = ConversationViewModel(
            speech: MockSpeechEngine(),
            permissions: MockPermissions(),
            preferences: preferences,
            summarizer: MockSummarizer(),
            taskStore: store
        )

        await viewModel.bootstrap()

        #expect(viewModel.userLanguage == .zhHans)
        #expect(viewModel.peerLanguage == .english)
        #expect(preferences.userLanguage == .zhHans)
        #expect(preferences.peerLanguage == .english)
        #expect(viewModel.hasActiveTask)
        #expect(viewModel.transcript.map(\.sourceText) == ["Restored line"])
        #expect(viewModel.userPane.history.count + viewModel.peerPane.history.count == 1)
        #expect(viewModel.resumePromptText?.contains("继续任务") == true)
        #expect(viewModel.resumePromptText?.contains(title) == true)
        #expect(viewModel.sessionState == .ready)
    }

    @Test("Exporting after clearing the display keeps the full transcript")
    func exportAfterClearUsesFullTranscript() async {
        let store = ScriptedTaskStore()
        store.startNewFailure = .saveFailed
        let gate = ConversationFakeGate()
        let viewModel = makeGateViewModel(gate: gate, store: store)
        await viewModel.beginTask()
        #expect(viewModel.isMemoryOnly)

        gate.emit(Utterance(language: .english, text: "See you at three", isFinal: true))
        await waitUntil { viewModel.transcript.count == 1 }
        gate.emit(Utterance(language: .zhHans, text: "好的我知道了", isFinal: true))
        await waitUntil { viewModel.transcript.count == 2 }

        await viewModel.clearDisplay()

        #expect(viewModel.userPane == .empty)
        #expect(viewModel.peerPane == .empty)
        #expect(
            viewModel.exportableSession.entries.map(\.sourceText)
                == ["See you at three", "好的我知道了"]
        )
    }

    @Test("Each pane keeps only the three most recent history lines while listening")
    func livePaneKeepsThreeHistoryLines() async {
        let gate = ConversationFakeGate()
        let viewModel = makeGateViewModel(gate: gate)
        await viewModel.beginTask()
        let texts = [
            "I will bring the contract",
            "The meeting starts at three",
            "Please send the invoice",
            "We need a receipt",
            "See you tomorrow",
        ]
        for text in texts {
            gate.emit(Utterance(language: .english, text: text, isFinal: true))
            await waitUntil { viewModel.transcript.contains { $0.sourceText == text } }
        }

        #expect(viewModel.transcript.map(\.sourceText) == texts)
        #expect(viewModel.userPane.live?.sourceText == texts.last)
        #expect(viewModel.userPane.history.map(\.sourceText) == Array(texts.dropFirst().dropLast()))
        #expect(viewModel.peerPane.history.isEmpty)
    }

    @Test("Restoring fills each pane with only the three most recent entries")
    func restoreFillsEachPaneWithThreeMostRecentEntries() async {
        let store = InMemoryTaskStore()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let title = TaskTitle.make(
            feature: .faceToFace,
            source: .zhHans,
            target: .english,
            startedAt: startedAt,
            language: .zhHans
        )
        let draft = TaskDraft(
            feature: .faceToFace,
            sourceLanguage: .zhHans,
            targetLanguage: .english,
            multilingual: false,
            startedAt: startedAt,
            title: title
        )
        guard case let .persisted(seeded) = await store.startNew(draft) else {
            Issue.record("Could not seed the running task")
            return
        }
        let entries = [
            makeEntry("user-1", speaker: .user),
            makeEntry("peer-1", speaker: .peer),
            makeEntry("user-2", speaker: .user),
            makeEntry("peer-2", speaker: .peer),
            makeEntry("user-3", speaker: .user),
            makeEntry("peer-3", speaker: .peer),
            makeEntry("user-4", speaker: .user),
            makeEntry("peer-4", speaker: .peer),
        ]
        _ = await store.append(entries, to: seeded.id)
        _ = await store.setStatus(.pausedListening, for: seeded.id)

        let viewModel = ConversationViewModel(
            speech: MockSpeechEngine(),
            permissions: MockPermissions(),
            preferences: makePreferences(userLanguage: .english, peerLanguage: .zhHans),
            summarizer: MockSummarizer(),
            taskStore: store
        )

        await viewModel.bootstrap()

        #expect(viewModel.transcript.map(\.sourceText) == entries.map(\.sourceText))
        // Entries spoken by the user are read on the peer pane and vice versa;
        // only the newest three per pane stay on screen.
        #expect(viewModel.peerPane.history.map(\.sourceText) == ["user-2", "user-3", "user-4"])
        #expect(viewModel.userPane.history.map(\.sourceText) == ["peer-2", "peer-3", "peer-4"])
        #expect(viewModel.userPane.live == nil)
        #expect(viewModel.peerPane.live == nil)
        #expect(viewModel.exportableSession.entries.count == entries.count)
    }

    @Test("Changing a language stops the current stream before clearing panes")
    func changingLanguageStopsStream() async {
        let gate = ConversationFakeGate()
        let viewModel = makeGateViewModel(gate: gate)
        await viewModel.beginTask()
        gate.emit(Utterance(language: .english, text: "See you at three", isFinal: true))
        await waitUntil { viewModel.userPane.live?.sourceText == "See you at three" }
        #expect(viewModel.sessionState == .listening)

        await viewModel.setPeerLanguage(.japanese)

        #expect(gate.stopCount == 1)
        #expect(viewModel.sessionState == .ready)
        #expect(viewModel.peerLanguage == .japanese)
        #expect(viewModel.userPane.live == nil)
        #expect(viewModel.peerPane.live == nil)
        #expect(viewModel.outboundJob == nil)
        #expect(viewModel.transcript.isEmpty)
    }

    @Test("A memory-only task with content blocks a new task until discarded")
    func unsavedTaskBlocksNewTask() async {
        let store = ScriptedTaskStore()
        store.startNewFailure = .saveFailed
        let viewModel = makeGateViewModel(
            gate: ConversationFakeGate(),
            store: store,
            autoStart: false
        )
        await viewModel.beginTask()
        #expect(viewModel.isMemoryOnly)
        #expect(viewModel.showsNotSavedBanner)
        viewModel.accept(Utterance(language: .zhHans, text: "唯一的副本", isFinal: true))

        await viewModel.beginTask()

        #expect(viewModel.isUnsavedTaskPromptPresented)
        #expect(viewModel.hasActiveTask)
        #expect(viewModel.transcript.map(\.sourceText) == ["唯一的副本"])
        #expect(store.startNewCalls == 1)

        await viewModel.discardUnsavedTaskAndBegin()

        #expect(!viewModel.isUnsavedTaskPromptPresented)
        #expect(viewModel.transcript.isEmpty)
        #expect(viewModel.hasActiveTask)
        #expect(store.startNewCalls == 2)
    }

    @Test("A new face-to-face task title uses the interface language, not the target")
    func newTaskTitleUsesInterfaceLanguage() async {
        let store = InMemoryTaskStore()
        let viewModel = makeGateViewModel(
            gate: ConversationFakeGate(),
            store: store,
            autoStart: false,
            preferences: makePreferences(userLanguage: .zhHans, peerLanguage: .english)
        )

        await viewModel.beginTask()

        let task = await store.activeTask(for: .faceToFace)
        #expect(task?.title.contains("面对面") == true)
        #expect(task?.title.contains("Face to face") == false)
        #expect(task?.sourceLanguage == .zhHans)
        #expect(task?.targetLanguage == .english)
    }

    @Test("A stream superseded by another owner pauses without a recognition error")
    func supersededStreamPausesSilently() async throws {
        let gate = ConversationFakeGate()
        let viewModel = makeGateViewModel(gate: gate)
        await viewModel.beginTask()
        #expect(viewModel.sessionState == .listening)

        _ = try await gate.start(
            owner: .meeting,
            languages: [.zhHans],
            fallbackLanguage: .zhHans,
            style: .meetingNotes
        )
        await waitUntil { viewModel.sessionState == .paused }

        #expect(viewModel.sessionState == .paused)
        #expect(viewModel.hasActiveTask)
    }

    private func makePreferences(
        userLanguage: AppLanguage,
        peerLanguage: AppLanguage
    ) -> PreferencesStore {
        let preferences = PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString) ?? .standard)
        preferences.userLanguage = userLanguage
        preferences.peerLanguage = peerLanguage
        return preferences
    }

    private func makeGateViewModel(
        gate: ConversationFakeGate,
        store: any TaskStoreV2 = InMemoryTaskStore(),
        autoStart: Bool = true,
        preferences: PreferencesStore? = nil
    ) -> ConversationViewModel {
        let resolved = preferences ?? makePreferences(userLanguage: .zhHans, peerLanguage: .english)
        resolved.autoStartListening = autoStart
        return ConversationViewModel(
            gate: gate,
            permissions: MockPermissions(),
            preferences: resolved,
            summarizer: MockSummarizer(),
            taskStore: store
        )
    }

    private func makeEntry(_ text: String, speaker: SpeakerSide = .user) -> TranscriptEntry {
        TranscriptEntry(
            id: UUID(),
            speaker: speaker,
            source: .zhHans,
            sourceText: text,
            translatedText: "",
            isFinal: true
        )
    }

    private func waitUntil(
        maxYields: Int = 500,
        _ condition: () -> Bool
    ) async {
        for _ in 0..<maxYields {
            if condition() { return }
            await Task.yield()
        }
    }

    @MainActor
    private func makeViewModel(
        idleRestoreDelay: Duration = .seconds(30)
    ) -> ConversationViewModel {
        ConversationViewModel(
            speech: MockSpeechEngine(),
            permissions: MockPermissions(),
            preferences: PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString) ?? .standard),
            summarizer: MockSummarizer(),
            idleRestoreDelay: idleRestoreDelay
        )
    }
}

@MainActor
private final class ConversationEventLog {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func contains(_ event: String) -> Bool {
        events.contains(event)
    }

    func firstIndex(of event: String) -> Int? {
        events.firstIndex(of: event)
    }
}

@MainActor
private final class ConversationFakeGate: SpeechSessionGating {
    struct Start {
        var owner: FeatureID
        var languages: [AppLanguage]
        var fallbackLanguage: AppLanguage
        var style: SpeechRecognitionStyle
    }

    private var generation: UInt64 = 0
    private var currentGeneration: UInt64?
    private var continuation: AsyncStream<Utterance>.Continuation?
    private(set) var starts: [Start] = []
    private(set) var stopCount = 0
    var eventSink: ((String) -> Void)?

    var startCount: Int { starts.count }

    func start(
        owner: FeatureID,
        languages: [AppLanguage],
        fallbackLanguage: AppLanguage,
        style: SpeechRecognitionStyle
    ) async throws -> SpeechSessionHandle {
        // A new start immediately supersedes the previous owner's stream.
        continuation?.finish()
        continuation = nil
        generation += 1
        let next = generation
        currentGeneration = next
        let (stream, continuation) = AsyncStream<Utterance>.makeStream()
        self.continuation = continuation
        starts.append(
            Start(
                owner: owner,
                languages: languages,
                fallbackLanguage: fallbackLanguage,
                style: style
            )
        )
        eventSink?("gate-start")
        return SpeechSessionHandle(owner: owner, generation: next, stream: stream)
    }

    func stop(_ handle: SpeechSessionHandle) async {
        stopCount += 1
        eventSink?("gate-stop")
        guard currentGeneration == handle.generation else { return }
        currentGeneration = nil
        continuation?.finish()
        continuation = nil
    }

    func isCurrent(_ handle: SpeechSessionHandle) async -> Bool {
        currentGeneration == handle.generation
    }

    func emit(_ utterance: Utterance) {
        continuation?.yield(utterance)
    }
}
