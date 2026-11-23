import Foundation
import Testing
@testable import Duiyi

@MainActor
struct TaskDetailViewModelTests {
    @Test("A failed detail read shows the storage banner and keeps the loaded task")
    func failedReadShowsBanner() async throws {
        let store = ScriptedTaskStore()
        let ended = try await store.base.seedEndedTask()
        let viewModel = TaskDetailViewModel(
            taskID: ended.id,
            store: store,
            summarizer: MockSummarizer()
        )
        await viewModel.load()
        #expect(viewModel.task?.id == ended.id)

        store.readFailure = .readFailed
        await viewModel.load()

        #expect(viewModel.task?.id == ended.id)
        #expect(viewModel.readFailure == .readFailed)
        #expect(viewModel.showsStorageBanner)
    }

    @Test("Retry reopens storage and reloads the detail")
    func retryReopensStorageAndReloads() async throws {
        let store = ScriptedTaskStore(availability: .unavailable(.openFailed))
        let ended = try await store.base.seedEndedTask()
        let viewModel = TaskDetailViewModel(
            taskID: ended.id,
            store: store,
            summarizer: MockSummarizer()
        )
        await viewModel.load()
        #expect(viewModel.task == nil)
        #expect(viewModel.readFailure == .openFailed)
        #expect(viewModel.showsStorageBanner)

        store.retryAvailability = .ready
        await viewModel.retry()

        #expect(store.retryCalls == 1)
        #expect(viewModel.readFailure == nil)
        #expect(viewModel.task?.id == ended.id)
        #expect(!viewModel.showsStorageBanner)
    }

    @Test("Detail delete waits for confirmation before deleting")
    func deleteWaitsForConfirmation() async throws {
        let store = ScriptedTaskStore()
        let ended = try await store.base.seedEndedTask()
        let viewModel = TaskDetailViewModel(
            taskID: ended.id,
            store: store,
            summarizer: MockSummarizer()
        )
        await viewModel.load()

        viewModel.requestDelete()
        #expect(viewModel.pendingDelete)
        #expect(store.deleteCalls == 0)
        #expect(viewModel.task?.id == ended.id)

        let deleted = await viewModel.confirmDelete()

        #expect(deleted)
        #expect(!viewModel.pendingDelete)
        #expect(store.deleteCalls == 1)
        #expect(viewModel.deleteFailure == nil)
        #expect(await store.base.readTask(id: ended.id) == .value(nil))
    }

    @Test("A failed detail delete is visible and keeps the task")
    func deleteFailureIsVisible() async throws {
        let store = ScriptedTaskStore()
        let ended = try await store.base.seedEndedTask()
        let viewModel = TaskDetailViewModel(
            taskID: ended.id,
            store: store,
            summarizer: MockSummarizer()
        )
        await viewModel.load()

        store.deleteFailure = .saveFailed
        viewModel.requestDelete()
        let deleted = await viewModel.confirmDelete()

        #expect(!deleted)
        #expect(viewModel.deleteFailure == .saveFailed)
        #expect(viewModel.task?.id == ended.id)
        #expect(await store.base.readTask(id: ended.id) != .value(nil))
    }

    @Test("A failed summary save is visible and the summary stays in memory")
    func summarySaveFailureIsVisible() async throws {
        let store = ScriptedTaskStore()
        let running = try await store.base.seedRunningTask()
        let viewModel = TaskDetailViewModel(
            taskID: running.id,
            store: store,
            summarizer: MockSummarizer()
        )
        await viewModel.load()

        store.saveSummaryFailure = .saveFailed
        await viewModel.summarize(language: .zhHans)

        #expect(store.saveSummaryCalls == 1)
        #expect(viewModel.summarySaveFailure == .saveFailed)
        #expect(viewModel.summaryError == nil)
        #expect(viewModel.task?.summary?.text == MockSummarizer().summary.text)
    }

    @Test("A failed translation backfill is visible")
    func translationSaveFailureIsVisible() async throws {
        let store = ScriptedTaskStore()
        let running = try await store.base.seedRunningTask()
        let entryID = try #require(running.entries.first?.id)
        let viewModel = TaskDetailViewModel(
            taskID: running.id,
            store: store,
            summarizer: MockSummarizer()
        )
        await viewModel.load()

        store.updateTranslationsFailure = .saveFailed
        let saved = await viewModel.applyTranslation(entryID: entryID, text: "Confirm the budget")

        #expect(!saved)
        #expect(store.updateTranslationsCalls == 1)
        #expect(viewModel.translationSaveFailure == .saveFailed)
        #expect(viewModel.task?.entries.first?.translatedText == "Confirm the budget")
    }
}
