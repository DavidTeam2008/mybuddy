import Foundation
import Testing
@testable import Duiyi

@MainActor
struct HomeViewModelTests {
    @Test("A failed unfinished read shows the storage banner, not no tasks")
    func failedReadShowsStorageBanner() async throws {
        let store = ScriptedTaskStore()
        let running = try await store.base.seedRunningTask()
        let viewModel = HomeViewModel(store: store)
        await viewModel.load()
        #expect(viewModel.unfinished.map(\.id) == [running.id])

        store.readFailure = .readFailed
        await viewModel.load()

        #expect(viewModel.unfinished.map(\.id) == [running.id])
        #expect(viewModel.readFailure == .readFailed)
        #expect(viewModel.showsStorageBanner)
    }

    @Test("No unfinished tasks and a failed read are distinct states")
    func emptyAndFailedAreDistinct() async {
        let store = ScriptedTaskStore()
        let viewModel = HomeViewModel(store: store)

        await viewModel.load()
        #expect(viewModel.unfinished.isEmpty)
        #expect(viewModel.readFailure == nil)
        #expect(!viewModel.showsStorageBanner)

        store.readFailure = .readFailed
        await viewModel.load()
        #expect(viewModel.unfinished.isEmpty)
        #expect(viewModel.readFailure == .readFailed)
        #expect(viewModel.showsStorageBanner)
    }

    @Test("Retry reopens storage and reloads unfinished tasks")
    func retryReopensStorageAndReloads() async throws {
        let store = ScriptedTaskStore(availability: .unavailable(.openFailed))
        let viewModel = HomeViewModel(store: store)
        await viewModel.load()
        #expect(viewModel.readFailure == .openFailed)
        #expect(viewModel.unfinished.isEmpty)

        let running = try await store.base.seedRunningTask()
        store.retryAvailability = .ready
        await viewModel.retry()

        #expect(store.retryCalls == 1)
        #expect(viewModel.readFailure == nil)
        #expect(viewModel.unfinished.map(\.id) == [running.id])
    }
}
