import Foundation

@MainActor
@Observable
final class HomeViewModel {
    private let store: any TaskStoreV2

    private(set) var unfinished: [TaskSession] = []
    /// The last unfinished-task read failed. Previously loaded tasks stay
    /// visible; the view shows the shared storage banner instead of pretending
    /// there is nothing in progress.
    private(set) var readFailure: TaskStoreFailureReason?

    init(store: any TaskStoreV2) {
        self.store = store
    }

    var showsStorageBanner: Bool {
        readFailure != nil || store.availability.isUnavailable
    }

    func load() async {
        switch await store.readUnfinishedTasks() {
        case let .value(loaded):
            unfinished = loaded
            readFailure = nil
        case let .unavailable(reason):
            readFailure = reason
        }
    }

    /// Reopens a failed store and re-reads unfinished tasks. Never backfills
    /// memory-only tasks into history.
    func retry() async {
        await store.retry()
        await load()
    }
}
