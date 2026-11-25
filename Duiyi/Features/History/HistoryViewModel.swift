import Foundation

@MainActor
@Observable
final class HistoryViewModel {
    private let store: any TaskStoreV2

    private(set) var tasks: [TaskSession] = []
    var filter: FeatureID?
    /// Invalidates in-flight reloads so a stale snapshot cannot overwrite a
    /// newer delete or reload.
    private var loadGeneration = 0

    /// The last history read failed. Loaded tasks stay visible; the view shows
    /// the shared storage banner instead of pretending history is empty.
    private(set) var readFailure: TaskStoreFailureReason?
    /// A delete reported by the user is waiting for confirmation.
    private(set) var pendingDeletion: TaskSession?
    /// The last confirmed delete failed; the list is unchanged.
    private(set) var deleteFailure: TaskStoreFailureReason?

    init(store: any TaskStoreV2) {
        self.store = store
    }

    var showsStorageBanner: Bool {
        readFailure != nil || store.availability.isUnavailable
    }

    func reload() async {
        loadGeneration += 1
        let generation = loadGeneration
        let result = await store.readList(filter: filter)
        guard generation == loadGeneration else { return }
        switch result {
        case let .value(loaded):
            tasks = loaded
            readFailure = nil
        case let .unavailable(reason):
            readFailure = reason
        }
    }

    func setFilter(_ filter: FeatureID?) async {
        self.filter = filter
        await reload()
    }

    /// Reopens a failed store and re-reads history. Never backfills tasks.
    func retry() async {
        await store.retry()
        await reload()
    }

    func requestDelete(_ task: TaskSession) {
        deleteFailure = nil
        pendingDeletion = task
    }

    func cancelDelete() {
        pendingDeletion = nil
    }

    func dismissDeleteFailure() {
        deleteFailure = nil
    }

    /// Confirms the pending delete. The view passes the dialog's captured task
    /// so dismissing the dialog cannot race the delete away.
    func confirmDelete(_ task: TaskSession? = nil) async {
        guard let target = task ?? pendingDeletion else { return }
        pendingDeletion = nil
        switch await store.deleteTask(id: target.id) {
        case .persisted:
            // One list mutation for one delete; invalidates any in-flight reload.
            removeDeletedTask(target.id)
        case let .notPersisted(reason):
            deleteFailure = reason
        }
    }

    /// Applies a confirmed delete (history swipe or detail screen) in a single
    /// mutation and invalidates stale reloads so the row cannot reappear.
    func removeDeletedTask(_ id: UUID) {
        loadGeneration += 1
        tasks.removeAll { $0.id == id }
        deleteFailure = nil
    }
}
