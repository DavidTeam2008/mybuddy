import Foundation
import Testing
@testable import Duiyi

@MainActor
struct MeetingViewModelTests {
    @Test("Same-sentence revisions collapse and end writes the full transcript")
    func meetingKeepsFullTranscript() async {
        let store = InMemoryTaskStore()
        let viewModel = makeViewModel(store: store)
        await viewModel.beginTask()
        let firstID = UUID()
        viewModel.accept(Utterance(id: firstID, language: .zhHans, text: "接下来把预算确认一下", isFinal: false))
        viewModel.accept(Utterance(id: firstID, language: .zhHans, text: "接下来把预算确认一下，本周内发给设计组。", isFinal: true))
        viewModel.accept(Utterance(language: .zhHans, text: "大家同意六点集合。", isFinal: true))
        #expect(viewModel.transcript.count == 2)
        #expect(viewModel.pane.history.count + (viewModel.pane.live == nil ? 0 : 1) <= 2)
        let saved = await viewModel.endTask()
        #expect(saved?.entries.count == 2)
        #expect(saved?.entries.contains { $0.sourceText.contains("设计组") } == true)
        #expect(saved?.entries.contains { $0.sourceText.contains("六点") } == true)
        let listed = await store.list(filter: .meeting)
        #expect(listed.count == 1)
    }

    @Test("The same utterance id stays one line from volatile to final")
    func sameIDVolatileToFinalKeepsOneLine() async {
        let viewModel = makeViewModel()
        await viewModel.beginTask()
        let id = UUID()

        viewModel.accept(Utterance(id: id, language: .zhHans, text: "把预算确认", isFinal: false))
        viewModel.accept(Utterance(id: id, language: .zhHans, text: "把预算确认一下。", isFinal: true))

        #expect(viewModel.transcript.count == 1)
        #expect(viewModel.transcript.first?.id == id)
        #expect(viewModel.transcript.first?.sourceText == "把预算确认一下。")
        #expect(viewModel.pane.live?.id == id)
    }

    @Test("Different utterance ids keep separate lines even for similar text")
    func differentIDsKeepSeparateLines() async {
        let viewModel = makeViewModel()
        await viewModel.beginTask()

        viewModel.accept(Utterance(language: .zhHans, text: "把预算确认一下", isFinal: true))
        viewModel.accept(
            Utterance(language: .zhHans, text: "把预算确认一下，本周内发给设计组。", isFinal: true)
        )

        #expect(viewModel.transcript.map(\.sourceText) == [
            "把预算确认一下",
            "把预算确认一下，本周内发给设计组。",
        ])
        #expect(viewModel.pane.history.map(\.sourceText) == ["把预算确认一下"])
        #expect(viewModel.pane.live?.sourceText == "把预算确认一下，本周内发给设计组。")
    }

    @Test("A volatile greeting name swap becomes two lines through the assembler")
    func volatileGreetingNameSwapKeepsSeparateLines() async throws {
        let viewModel = makeViewModel(meetingLanguage: .english)
        await viewModel.beginTask()
        var assembler = UtteranceAssembler()

        let firstValue = assembler.ingest(language: .english, text: "Hi, Jack", isFinal: false)
        let first = try #require(firstValue)
        viewModel.accept(first)
        let secondValue = assembler.ingest(language: .english, text: "Hi, Lucy", isFinal: false)
        let second = try #require(secondValue)
        viewModel.accept(second)

        #expect(second.id != first.id)
        #expect(viewModel.transcript.map(\.sourceText) == ["Hi, Jack", "Hi, Lucy"])
    }

    @Test("A long final followed by a short continuation keeps the new transcript line")
    func longFinalThenShortContinuationKeepsNewText() async {
        let viewModel = makeViewModel(meetingLanguage: .english)
        await viewModel.beginTask()
        let longText = "The translation pipeline, the speech session gate, the storage degradation policy, and the accessibility audit in considerable detail."
        let shortText = "And the team agreed to revisit the remaining items next week."

        viewModel.accept(Utterance(language: .english, text: longText, isFinal: true))
        let id = UUID()
        viewModel.accept(Utterance(id: id, language: .english, text: "And", isFinal: false))
        viewModel.accept(Utterance(id: id, language: .english, text: "And the team", isFinal: false))
        viewModel.accept(Utterance(id: id, language: .english, text: shortText, isFinal: true))

        #expect(viewModel.pane.live?.sourceText == shortText)
        #expect(viewModel.transcript.contains { $0.sourceText == shortText })
        #expect(viewModel.transcript.contains { $0.sourceText.contains("translation pipeline") })
    }

    @Test("Meeting never starts listening on new task")
    func meetingDoesNotAutostart() async {
        let viewModel = makeViewModel()
        await viewModel.beginTask()
        #expect(viewModel.hasActiveTask)
        #expect(viewModel.sessionState != .listening)
    }

    @Test("Default meeting mode pins the reading language")
    func defaultModeUsesPinnedReadingLanguage() async {
        let speech = RecordingSpeechEngine()
        let viewModel = makeViewModel(speech: speech)
        #expect(!viewModel.recognizesMultipleLanguages)
        #expect(viewModel.recognitionLanguages == [.zhHans])
        await viewModel.beginTask()
        await viewModel.start()
        let started = await speech.startedLanguages
        let style = await speech.startedStyle
        #expect(started == [.zhHans])
        #expect(style == .meetingNotes)
    }

    @Test("Multilingual meeting starts the reading language and its pair")
    func multilingualUsesReadingPair() async {
        let speech = RecordingSpeechEngine()
        let viewModel = makeViewModel(speech: speech)
        viewModel.setRecognizesMultipleLanguages(true)
        #expect(viewModel.recognitionLanguages == [.zhHans, .english])
        await viewModel.beginTask()
        await viewModel.start()
        let started = await speech.startedLanguages
        #expect(started == [.zhHans, .english])
    }

    @Test("Chinese and English stay separate transcript lines")
    func mixedLanguagesStaySeparate() async {
        let viewModel = makeViewModel()
        viewModel.setRecognizesMultipleLanguages(true)
        await viewModel.beginTask()
        viewModel.accept(Utterance(language: .zhHans, text: "把预算确认一下。", isFinal: true))
        viewModel.accept(Utterance(language: .english, text: "I can send it this week.", isFinal: true))
        #expect(viewModel.transcript.count == 2)
        #expect(viewModel.transcript[0].source == .zhHans)
        #expect(viewModel.transcript[1].source == .english)
        let saved = await viewModel.endTask()
        #expect(saved?.title.contains("多种语言") == true)
        #expect(saved?.entries.map(\.source) == [.zhHans, .english])
    }

    @Test("Pinning one language ignores the others")
    func pinnedLanguageIgnoresOthers() async {
        let speech = RecordingSpeechEngine()
        let viewModel = makeViewModel(speech: speech)
        viewModel.setSourceLanguage(.japanese)
        #expect(!viewModel.recognizesMultipleLanguages)
        #expect(viewModel.recognitionLanguages == [.japanese])
        await viewModel.beginTask()
        await viewModel.start()
        let started = await speech.startedLanguages
        #expect(started == [.japanese])
        viewModel.accept(Utterance(language: .english, text: "Hello there", isFinal: true))
        viewModel.accept(Utterance(language: .japanese, text: "こんにちは", isFinal: true))
        #expect(viewModel.transcript.count == 1)
        #expect(viewModel.transcript.first?.sourceText == "こんにちは")
    }

    @Test("Recognition order puts the reading language first")
    func recognitionOrderPrefersDisplayLanguage() {
        let languages = MeetingRecognition.languages(
            multilingual: true,
            pinned: .thai,
            display: .korean
        )
        #expect(languages == [.korean, .english])
    }

    @Test("Chinese characters are not stored as English")
    func retagsChineseTextClaimedAsEnglish() async {
        let viewModel = makeViewModel()
        await viewModel.beginTask()
        viewModel.accept(
            Utterance(
                language: .english,
                text: "在那时开始之前呢，我想请大家想象一个画面",
                isFinal: true
            )
        )
        #expect(viewModel.transcript.count == 1)
        #expect(viewModel.transcript.first?.source == .zhHans)
    }

    @Test("The same caption id updates its language when Chinese wins")
    func upsertUpdatesSourceWhenLanguageChanges() async {
        let viewModel = makeViewModel()
        await viewModel.beginTask()
        let id = UUID()
        viewModel.accept(Utterance(id: id, language: .english, text: "Then I want you to imagine", isFinal: false))
        viewModel.accept(
            Utterance(
                id: id,
                language: .zhHans,
                text: "在那时开始之前呢我想请大家想象一个画面假如你是一个穿着校服的高中生",
                isFinal: true
            )
        )
        #expect(viewModel.transcript.count == 1)
        #expect(viewModel.transcript.first?.source == .zhHans)
        #expect(viewModel.transcript.first?.sourceText.contains("想象") == true)
    }

    @Test("Immediate repeated phrases collapse once")
    func collapseStutteredRepeats() async {
        let viewModel = makeViewModel()
        await viewModel.beginTask()
        viewModel.accept(Utterance(language: .zhHans, text: "如果是你们你们会愿意把这个视频发到网上吗？", isFinal: true))
        #expect(viewModel.transcript.first?.sourceText.contains("你们你们") == false)
        #expect(viewModel.transcript.first?.sourceText.contains("你们会愿意") == true)
    }

    @Test("Beginning a new task stops the old stream before ending, keeping old lines out of the new task")
    func beginStopsOldStreamBeforeEnding() async {
        let log = MeetingEventLog()
        let store = ScriptedTaskStore()
        store.eventSink = { log.record($0) }
        let gate = MeetingFakeGate(log: log)
        let viewModel = makeViewModel(store: store, gate: gate)

        await viewModel.beginTask()
        await viewModel.start()
        #expect(viewModel.sessionState == .listening)
        viewModel.accept(Utterance(language: .zhHans, text: "旧任务最后一句", isFinal: true))

        await viewModel.beginTask()

        #expect(log.contains("gate-stop"))
        #expect(log.contains("store-end"))
        let stopIndex = log.firstIndex(of: "gate-stop")
        let endIndex = log.firstIndex(of: "store-end")
        #expect(stopIndex != nil && endIndex != nil && stopIndex! < endIndex!)
        #expect(viewModel.transcript.isEmpty)
        let active = await store.base.activeTask(for: .meeting)
        #expect(active?.entries.isEmpty == true)
        let ended = await store.base.list(filter: .meeting)
        #expect(ended.first?.entries.contains { $0.sourceText == "旧任务最后一句" } == true)
    }

    @Test("Ending immediately still flushes the last settled line")
    func endFlushesPendingCaption() async {
        let store = InMemoryTaskStore()
        let viewModel = makeViewModel(store: store)
        await viewModel.beginTask()
        viewModel.accept(Utterance(language: .zhHans, text: "最后一句话", isFinal: true))

        let ended = await viewModel.endTask()

        #expect(ended?.entries.map(\.sourceText) == ["最后一句话"])
        #expect(viewModel.transcript.isEmpty)
    }

    @Test("Beginning a new task drains a final emitted when the old stream stops")
    func beginTaskDrainsFinalEmittedOnStop() async {
        let store = InMemoryTaskStore()
        let gate = MeetingFakeGate(log: MeetingEventLog())
        gate.finalOnStop = Utterance(language: .zhHans, text: "旧会议最后一句", isFinal: true)
        let viewModel = makeViewModel(store: store, gate: gate)

        await viewModel.beginTask()
        await viewModel.start()
        await viewModel.beginTask()

        let ended = await store.list(filter: .meeting)
        #expect(ended.first?.entries.contains { $0.sourceText == "旧会议最后一句" } == true)
    }

    @Test("Ending a task drains a final emitted when the stream stops")
    func endTaskDrainsFinalEmittedOnStop() async throws {
        let store = InMemoryTaskStore()
        let gate = MeetingFakeGate(log: MeetingEventLog())
        gate.finalOnStop = Utterance(language: .zhHans, text: "会议最后一句", isFinal: true)
        let viewModel = makeViewModel(store: store, gate: gate)

        await viewModel.beginTask()
        await viewModel.start()
        let ended = try #require(await viewModel.endTask())

        #expect(ended.entries.contains { $0.sourceText == "会议最后一句" })
    }

    @Test("Stopping listening drains a final emitted when the stream stops")
    func stopDrainsFinalEmittedOnStop() async {
        let gate = MeetingFakeGate(log: MeetingEventLog())
        gate.finalOnStop = Utterance(language: .zhHans, text: "会议暂停最后一句", isFinal: true)
        let viewModel = makeViewModel(gate: gate)

        await viewModel.beginTask()
        await viewModel.start()
        await viewModel.stop(restoreIdleTimerAfterDelay: false)

        #expect(viewModel.transcript.contains { $0.sourceText == "会议暂停最后一句" })
    }

    @Test("Ending an empty task discards it without history")
    func endDiscardsEmptyTask() async {
        let store = InMemoryTaskStore()
        let viewModel = makeViewModel(store: store)
        await viewModel.beginTask()

        let ended = await viewModel.endTask()

        #expect(ended == nil)
        #expect(!viewModel.hasActiveTask)
        #expect(await store.list(filter: .meeting).isEmpty)
    }

    @Test("Ending with an empty memory transcript still ends when the store has captions")
    func endUsesStoreCaptionsForEmptyVerdict() async throws {
        let store = InMemoryTaskStore()
        let viewModel = makeViewModel(store: store)
        await viewModel.beginTask()
        let taskID = try #require(await store.activeTask(for: .meeting)?.id)
        let persisted = makeEntry("已经落盘的句子")
        #expect(await store.append([persisted], to: taskID) == .persisted)

        let ended = await viewModel.endTask()

        #expect(ended != nil)
        #expect(ended?.entries.map(\.sourceText) == ["已经落盘的句子"])
        let listed = await store.list(filter: .meeting)
        #expect(listed.count == 1)
    }

    @Test("An end that cannot be saved keeps the transcript and writes no history")
    func notSavedEndKeepsTranscript() async {
        let store = ScriptedTaskStore()
        let viewModel = makeViewModel(store: store)
        await viewModel.beginTask()
        viewModel.accept(Utterance(language: .zhHans, text: "还没保存的内容", isFinal: true))
        store.endFailure = .saveFailed

        let ended = await viewModel.endTask()

        #expect(ended == nil)
        #expect(viewModel.transcript.map(\.sourceText) == ["还没保存的内容"])
        #expect(viewModel.hasActiveTask)
        #expect(viewModel.isNotSaved)
        #expect(viewModel.sessionState == .paused)
        #expect(viewModel.exportableSession.entries.map(\.sourceText) == ["还没保存的内容"])
        #expect(await store.base.list(filter: .meeting).isEmpty)
        #expect(store.endCalls == 1)
    }

    @Test("Restoring applies the task language pair and shows the continue prompt")
    func restoreAppliesLanguagePairAndPrompt() async throws {
        let store = InMemoryTaskStore()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let title = TaskTitle.make(
            feature: .meeting,
            source: .english,
            target: nil,
            startedAt: startedAt,
            language: .zhHans,
            multilingual: false
        )
        let draft = TaskDraft(
            feature: .meeting,
            sourceLanguage: .english,
            targetLanguage: nil,
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

        let viewModel = makeViewModel(store: store)
        await viewModel.bootstrap()

        #expect(viewModel.sourceLanguage == .english)
        #expect(viewModel.hasActiveTask)
        #expect(viewModel.transcript.map(\.sourceText) == ["Restored line"])
        #expect(viewModel.pane.history.count == 1)
        #expect(viewModel.resumePromptText?.contains("继续任务") == true)
        #expect(viewModel.resumePromptText?.contains(title) == true)
        #expect(viewModel.sessionState == .ready)
    }

    @Test("Restoring fills the meeting window with every entry and keeps the full transcript")
    func restoreFillsMeetingWindow() async {
        let store = InMemoryTaskStore()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let title = TaskTitle.make(
            feature: .meeting,
            source: .zhHans,
            target: nil,
            startedAt: startedAt,
            language: .zhHans,
            multilingual: false
        )
        let draft = TaskDraft(
            feature: .meeting,
            sourceLanguage: .zhHans,
            targetLanguage: nil,
            multilingual: false,
            startedAt: startedAt,
            title: title
        )
        guard case let .persisted(seeded) = await store.startNew(draft) else {
            Issue.record("Could not seed the running task")
            return
        }
        let texts = (0..<5).map { "恢复行 \($0)" }
        _ = await store.append(texts.map { makeEntry($0) }, to: seeded.id)
        _ = await store.setStatus(.pausedListening, for: seeded.id)

        let viewModel = makeViewModel(store: store)
        await viewModel.bootstrap()

        #expect(viewModel.pane.live == nil)
        #expect(viewModel.pane.history.map(\.sourceText) == texts)
        #expect(viewModel.transcript.map(\.sourceText) == texts)
    }

    @Test("Restoring a multilingual task keeps both recognition languages")
    func restoreKeepsMultilingualPair() async throws {
        let store = InMemoryTaskStore()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let title = TaskTitle.make(
            feature: .meeting,
            source: .zhHans,
            target: nil,
            startedAt: startedAt,
            language: .zhHans,
            multilingual: true
        )
        let draft = TaskDraft(
            feature: .meeting,
            sourceLanguage: .zhHans,
            targetLanguage: nil,
            multilingual: true,
            startedAt: startedAt,
            title: title
        )
        guard case let .persisted(seeded) = await store.startNew(draft) else {
            Issue.record("Could not seed the running task")
            return
        }
        _ = await store.append([makeEntry("把预算确认一下。")], to: seeded.id)

        let viewModel = makeViewModel(store: store)
        await viewModel.bootstrap()

        #expect(viewModel.recognizesMultipleLanguages)
        #expect(viewModel.sourceLanguage == .zhHans)
        #expect(viewModel.recognitionLanguages == [.zhHans, .english])
    }

    @Test("A new meeting task title follows the interface language")
    func taskTitleUsesInterfaceLanguage() async {
        let store = InMemoryTaskStore()
        let viewModel = makeViewModel(store: store, userLanguage: .english, meetingLanguage: .zhHans)
        await viewModel.beginTask()

        let task = await store.activeTask(for: .meeting)
        #expect(task?.title.contains("Meeting notes") == true)
        #expect(task?.title.contains("会议记录") == false)
        #expect(task?.sourceLanguage == .zhHans)
    }

    @Test("A memory-only task with content blocks a new task until the user discards it")
    func unsavedTaskBlocksNewTask() async {
        let store = ScriptedTaskStore()
        store.startNewFailure = .saveFailed
        let viewModel = makeViewModel(store: store)
        await viewModel.beginTask()
        #expect(viewModel.isMemoryOnly)
        #expect(viewModel.isNotSaved)
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

    @Test("Export and continue starts a new task after the user continues")
    func exportThenContinueStartsNewTask() async {
        let store = ScriptedTaskStore()
        store.startNewFailure = .saveFailed
        let viewModel = makeViewModel(store: store)
        await viewModel.beginTask()
        viewModel.accept(Utterance(language: .zhHans, text: "唯一的副本", isFinal: true))
        await viewModel.beginTask()
        #expect(viewModel.isUnsavedTaskPromptPresented)

        viewModel.beginExportThenContinue()

        #expect(viewModel.isSummaryPresented)
        #expect(viewModel.isExportThenContinuePending)
        #expect(!viewModel.isUnsavedTaskPromptPresented)

        await viewModel.continueAfterExport()

        #expect(!viewModel.isSummaryPresented)
        #expect(!viewModel.isExportThenContinuePending)
        #expect(viewModel.transcript.isEmpty)
        #expect(viewModel.hasActiveTask)
        #expect(store.startNewCalls == 2)
    }

    @Test("Closing the export summary keeps the memory-only task intact")
    func closingExportSummaryKeepsTask() async {
        let store = ScriptedTaskStore()
        store.startNewFailure = .saveFailed
        let viewModel = makeViewModel(store: store)
        await viewModel.beginTask()
        viewModel.accept(Utterance(language: .zhHans, text: "唯一的副本", isFinal: true))
        await viewModel.beginTask()
        viewModel.beginExportThenContinue()

        viewModel.dismissSummary()

        #expect(!viewModel.isSummaryPresented)
        #expect(!viewModel.isExportThenContinuePending)
        #expect(viewModel.hasActiveTask)
        #expect(viewModel.isMemoryOnly)
        #expect(viewModel.transcript.map(\.sourceText) == ["唯一的副本"])
        #expect(store.startNewCalls == 1)
    }

    @Test("Reaching the character limit pauses listening and keeps the task unfinished")
    func characterLimitPausesListening() async throws {
        let store = InMemoryTaskStore()
        let viewModel = makeViewModel(store: store, speech: MockSpeechEngine())
        await viewModel.beginTask()
        await viewModel.start()
        #expect(viewModel.sessionState == .listening)

        let characters = (0..<MeetingLayout.transcriptCharacterLimit).map {
            Character(UnicodeScalar(0x4E00 + $0)!)
        }
        var index = 0
        while index < characters.count, !viewModel.isLengthLimited {
            let end = min(index + 100, characters.count)
            viewModel.accept(
                Utterance(
                    language: .zhHans,
                    text: String(characters[index..<end]),
                    isFinal: true
                )
            )
            index = end
        }

        #expect(viewModel.isLengthLimited)
        await waitUntil { viewModel.sessionState != .listening }
        #expect(viewModel.sessionState == .paused)
        #expect(viewModel.isLengthLimited)
        #expect(viewModel.hasActiveTask)
        let taskID = try #require(await store.activeTask(for: .meeting)?.id)
        #expect(await store.task(id: taskID)?.status == .pausedListening)
        let listed = await store.list(filter: .meeting)
        #expect(listed.isEmpty)
    }

    @Test("Clearing the display keeps the transcript, export, and listening state")
    func clearDisplayKeepsTranscriptAndListening() async {
        let log = MeetingEventLog()
        let gate = MeetingFakeGate(log: log)
        let viewModel = makeViewModel(gate: gate)
        await viewModel.beginTask()
        await viewModel.start()
        #expect(viewModel.sessionState == .listening)
        viewModel.accept(Utterance(language: .zhHans, text: "第一句。", isFinal: true))
        viewModel.accept(Utterance(language: .zhHans, text: "第二句。", isFinal: true))
        let saved = viewModel.transcript
        viewModel.isSummaryPresented = true

        await viewModel.clearDisplay()

        #expect(viewModel.transcript == saved)
        #expect(viewModel.exportableSession.entries == saved)
        #expect(viewModel.pane.history.isEmpty)
        #expect(viewModel.pane.live == nil)
        #expect(viewModel.pane.speakingHint == nil)
        #expect(!viewModel.isSummaryPresented)
        #expect(viewModel.hasActiveTask)
        #expect(viewModel.sessionState == .listening)
        #expect(gate.stopCount == 0)

        viewModel.accept(Utterance(language: .zhHans, text: "第三句。", isFinal: true))
        #expect(viewModel.transcript.map(\.sourceText) == ["第一句。", "第二句。", "第三句。"])
        #expect(viewModel.exportableSession.entries.count == 3)
    }

    @Test("Clearing the display flushes the pending caption before clearing")
    func clearDisplayFlushesPendingCaption() async {
        let log = MeetingEventLog()
        let store = ScriptedTaskStore()
        store.eventSink = { log.record($0) }
        let viewModel = makeViewModel(store: store)
        await viewModel.beginTask()
        viewModel.accept(Utterance(language: .zhHans, text: "清屏前的最后一句", isFinal: true))

        await viewModel.clearDisplay()

        let active = await store.base.activeTask(for: .meeting)
        #expect(active?.entries.map(\.sourceText) == ["清屏前的最后一句"])
        #expect(store.appendCalls == 1)
        #expect(log.contains("store-append"))
        #expect(!viewModel.isNotSaved)
    }

    @Test("The 20k character count keeps accumulating across a display clear")
    func characterCountAccumulatesAcrossClear() async {
        let viewModel = makeViewModel()
        await viewModel.beginTask()
        let characters = (0..<MeetingLayout.transcriptCharacterLimit).map {
            Character(UnicodeScalar(0x4E00 + $0)!)
        }
        let half = MeetingLayout.transcriptCharacterLimit / 2

        var index = 0
        while index < half {
            let end = min(index + 100, half)
            viewModel.accept(
                Utterance(
                    language: .zhHans,
                    text: String(characters[index..<end]),
                    isFinal: true
                )
            )
            index = end
        }
        await viewModel.clearDisplay()
        #expect(!viewModel.isLengthLimited)
        #expect(viewModel.transcript.reduce(0) { $0 + $1.sourceText.count } == half)

        while index < characters.count {
            let end = min(index + 100, characters.count)
            viewModel.accept(
                Utterance(
                    language: .zhHans,
                    text: String(characters[index..<end]),
                    isFinal: true
                )
            )
            index = end
        }

        #expect(viewModel.isLengthLimited)
        #expect(viewModel.transcript.reduce(0) { $0 + $1.sourceText.count } >= MeetingLayout.transcriptCharacterLimit)
    }

    @Test("The 20k limit stays after a display clear and keeps the task unfinished")
    func lengthLimitSurvivesClear() async throws {
        let store = InMemoryTaskStore()
        let viewModel = makeViewModel(store: store)
        await viewModel.beginTask()
        await viewModel.start()
        let characters = (0..<MeetingLayout.transcriptCharacterLimit).map {
            Character(UnicodeScalar(0x4E00 + $0)!)
        }
        var index = 0
        while index < characters.count, !viewModel.isLengthLimited {
            let end = min(index + 100, characters.count)
            viewModel.accept(
                Utterance(
                    language: .zhHans,
                    text: String(characters[index..<end]),
                    isFinal: true
                )
            )
            index = end
        }
        #expect(viewModel.isLengthLimited)
        await waitUntil { viewModel.sessionState != .listening }
        let transcriptCount = viewModel.transcript.count

        await viewModel.clearDisplay()

        #expect(viewModel.isLengthLimited)
        #expect(viewModel.errorText == Copy.meetingTooLong(for: .zhHans))
        #expect(viewModel.transcript.count == transcriptCount)
        #expect(viewModel.hasActiveTask)
        let taskID = try #require(await store.activeTask(for: .meeting)?.id)
        #expect(await store.task(id: taskID)?.status == .pausedListening)
        #expect(await store.list(filter: .meeting).isEmpty)
    }

    @Test("Clearing the display closes the summary sheet but keeps the summary data")
    func clearDisplayKeepsSummaryData() async {
        let viewModel = makeViewModel()
        await viewModel.beginTask()
        viewModel.accept(Utterance(language: .zhHans, text: "把预算确认一下。", isFinal: true))
        await viewModel.requestSummary()
        let summaryText = viewModel.summary?.text
        #expect(viewModel.isSummaryPresented)

        await viewModel.clearDisplay()

        #expect(!viewModel.isSummaryPresented)
        #expect(viewModel.summary?.text == summaryText)
        #expect(viewModel.exportableSession.summary?.text == summaryText)
    }

    @Test("Ending a task keeps its saved summary in history")
    func endingTaskPreservesSummary() async {
        let store = InMemoryTaskStore()
        let viewModel = makeViewModel(store: store)
        await viewModel.beginTask()
        viewModel.accept(Utterance(language: .zhHans, text: "把预算确认一下。", isFinal: true))
        await viewModel.requestSummary()
        #expect(viewModel.summary != nil)

        await viewModel.beginTask()

        let listed = await store.list(filter: .meeting)
        #expect(listed.first?.summary?.text == "双方约定喝咖啡。")
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

    private func makeViewModel(
        store: any TaskStoreV2 = InMemoryTaskStore(),
        speech: any SpeechRecognizing = MockSpeechEngine(),
        gate: (any SpeechSessionGating)? = nil,
        userLanguage: AppLanguage = .zhHans,
        meetingLanguage: AppLanguage = .zhHans
    ) -> MeetingViewModel {
        let preferences = PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString) ?? .standard)
        preferences.userLanguage = userLanguage
        preferences.meetingLanguage = meetingLanguage
        if let gate {
            return MeetingViewModel(
                gate: gate,
                permissions: MockPermissions(),
                preferences: preferences,
                summarizer: MockSummarizer(),
                taskStore: store
            )
        }
        return MeetingViewModel(
            speech: speech,
            permissions: MockPermissions(),
            preferences: preferences,
            summarizer: MockSummarizer(),
            taskStore: store
        )
    }
}

@MainActor
private final class MeetingEventLog {
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
private final class MeetingFakeGate: SpeechSessionGating {
    struct Start: Equatable {
        var owner: FeatureID
        var languages: [AppLanguage]
        var fallbackLanguage: AppLanguage
        var style: SpeechRecognitionStyle
    }

    private let log: MeetingEventLog
    private var generation: UInt64 = 0
    private var currentGeneration: UInt64?
    private var continuation: AsyncStream<Utterance>.Continuation?
    private(set) var starts: [Start] = []
    private(set) var stopCount = 0
    var nextStartError: (any Error)?
    var finalOnStop: Utterance?

    init(log: MeetingEventLog) {
        self.log = log
    }

    func start(
        owner: FeatureID,
        languages: [AppLanguage],
        fallbackLanguage: AppLanguage,
        style: SpeechRecognitionStyle
    ) async throws -> SpeechSessionHandle {
        if let nextStartError {
            self.nextStartError = nil
            throw nextStartError
        }
        generation += 1
        let next = generation
        currentGeneration = next
        let (stream, continuation) = AsyncStream<Utterance>.makeStream()
        self.continuation = continuation
        log.record("gate-start")
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
        stopCount += 1
        log.record("gate-stop")
        guard currentGeneration == handle.generation else { return }
        currentGeneration = nil
        if let final = finalOnStop {
            finalOnStop = nil
            continuation?.yield(final)
        }
        continuation?.finish()
        continuation = nil
    }

    func isCurrent(_ handle: SpeechSessionHandle) async -> Bool {
        currentGeneration == handle.generation
    }
}
