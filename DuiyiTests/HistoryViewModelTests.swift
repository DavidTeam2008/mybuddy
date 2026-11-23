import Foundation
import Testing
@testable import Duiyi

@MainActor
struct HistoryViewModelTests {
    @Test("A failed history read keeps the last loaded list visible")
    func failedReadKeepsLoadedHistory() async throws {
        let store = ScriptedTaskStore()
        let ended = try await store.base.seedEndedTask()
        let viewModel = HistoryViewModel(store: store)
        await viewModel.reload()
        #expect(viewModel.tasks.map(\.id) == [ended.id])

        store.readFailure = .readFailed
        await viewModel.reload()

        #expect(viewModel.tasks.map(\.id) == [ended.id])
        #expect(viewModel.readFailure == .readFailed)
        #expect(viewModel.showsStorageBanner)
    }

    @Test("An empty history and a failed read are distinct states")
    func emptyAndFailedAreDistinct() async {
        let store = ScriptedTaskStore()
        let viewModel = HistoryViewModel(store: store)

        await viewModel.reload()
        #expect(viewModel.tasks.isEmpty)
        #expect(viewModel.readFailure == nil)
        #expect(!viewModel.showsStorageBanner)

        store.readFailure = .readFailed
        await viewModel.reload()
        #expect(viewModel.tasks.isEmpty)
        #expect(viewModel.readFailure == .readFailed)
        #expect(viewModel.showsStorageBanner)
    }

    @Test("Retry reopens storage and reloads history")
    func retryReopensStorageAndReloads() async throws {
        let store = ScriptedTaskStore(availability: .unavailable(.openFailed))
        let viewModel = HistoryViewModel(store: store)
        await viewModel.reload()
        #expect(viewModel.readFailure == .openFailed)
        #expect(viewModel.tasks.isEmpty)

        let ended = try await store.base.seedEndedTask()
        store.retryAvailability = .ready
        await viewModel.retry()

        #expect(store.retryCalls == 1)
        #expect(viewModel.readFailure == nil)
        #expect(viewModel.tasks.map(\.id) == [ended.id])
    }

    @Test("Swipe delete waits for confirmation before deleting")
    func deleteWaitsForConfirmation() async throws {
        let store = ScriptedTaskStore()
        let ended = try await store.base.seedEndedTask()
        let viewModel = HistoryViewModel(store: store)
        await viewModel.reload()

        viewModel.requestDelete(ended)
        #expect(viewModel.pendingDeletion?.id == ended.id)
        #expect(store.deleteCalls == 0)
        #expect(viewModel.tasks.map(\.id) == [ended.id])

        await viewModel.confirmDelete()

        #expect(store.deleteCalls == 1)
        #expect(viewModel.pendingDeletion == nil)
        #expect(viewModel.deleteFailure == nil)
        #expect(viewModel.tasks.isEmpty)
        #expect(await store.base.readTask(id: ended.id) == .value(nil))
    }

    @Test("A failed delete keeps the task visible and reports the failure")
    func deleteFailureStaysVisible() async throws {
        let store = ScriptedTaskStore()
        let ended = try await store.base.seedEndedTask()
        let viewModel = HistoryViewModel(store: store)
        await viewModel.reload()

        store.deleteFailure = .saveFailed
        viewModel.requestDelete(ended)
        await viewModel.confirmDelete()

        #expect(store.deleteCalls == 1)
        #expect(viewModel.tasks.map(\.id) == [ended.id])
        #expect(viewModel.deleteFailure == .saveFailed)
        #expect(viewModel.pendingDeletion == nil)
        #expect(await store.base.readTask(id: ended.id) != .value(nil))
    }
}
