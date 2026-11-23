import Foundation
import SwiftData

/// Defers SwiftData `ModelContainer` creation off the launch critical path.
///
/// `AppEnvironment.init` runs synchronously on the main thread during first-frame
/// construction. Opening the SQLite store there (file I/O, migration checks,
/// model introspection) directly delays `HomeView` paint. This wrapper starts
/// with zero I/O and resolves the real store on first actual use — which happens
/// after the first frame (`HomeView.task`, `HistoryViewModel.reload`, restores).
///
/// A background warm is kicked off at init so the store is usually ready by the
/// time the user navigates, without blocking the first frame.
///
/// Wave 1 (ticket #2): availability is explicit (`opening` / `ready` /
/// `unavailable`); a failed open never masquerades as ready. `prepare()` awaits
/// the deferred open and `retry()` attempts it again. Legacy calls during the
/// expand step keep working through an in-memory fallback, but that fallback is
/// reported as `unavailable` and is removed in ticket #12.
@MainActor
@Observable
final class DeferredTaskStore: TaskStoreV2 {
    private(set) var availability: TaskStoreAvailability = .opening

    @ObservationIgnored private var durable: (any TaskStoreV2)?
    @ObservationIgnored private var legacyFallback: InMemoryTaskStore?
    @ObservationIgnored private var containerTask: Task<ModelContainer?, Never>?
    @ObservationIgnored private var openGeneration = 0
    @ObservationIgnored private let openContainer: @Sendable () async -> ModelContainer?
    @ObservationIgnored private let makeStore: @MainActor (ModelContainer) -> any TaskStoreV2

    init(
        warmImmediately: Bool = true,
        openContainer: @escaping @Sendable () async -> ModelContainer? = { DeferredTaskStore.openContainer() },
        makeStore: @escaping @MainActor (ModelContainer) -> any TaskStoreV2 = { SwiftDataTaskStore(container: $0) }
    ) {
        self.openContainer = openContainer
        self.makeStore = makeStore
        if warmImmediately {
            containerTask = makeOpenTask()
        }
    }

    /// Awaits the deferred open. Safe to call concurrently or repeatedly.
    func prepare() async {
        guard availability == .opening else { return }
        await resolveOpen()
    }

    /// Retries opening after an `unavailable` state. No-op when already ready.
    func retry() async {
        guard availability != .ready else { return }
        availability = .opening
        containerTask = makeOpenTask()
        await resolveOpen()
    }

    // MARK: - TaskStore (all delegate after lazy resolve)

    func activeTask(for feature: FeatureID) async -> TaskSession? {
        await legacyStore().activeTask(for: feature)
    }

    func unfinishedTasks() async -> [TaskSession] {
        await legacyStore().unfinishedTasks()
    }

    func startNew(
        feature: FeatureID,
        source: AppLanguage,
        target: AppLanguage?,
        multilingual: Bool
    ) async throws -> TaskSession {
        let store = await legacyStore()
        return try await store.startNew(feature: feature, source: source, target: target, multilingual: multilingual)
    }

    func append(taskID: UUID, entries: [TranscriptEntry]) async {
        await legacyStore().append(taskID: taskID, entries: entries)
    }

    func updateTranslations(taskID: UUID, entries: [TranscriptEntry]) async {
        await legacyStore().updateTranslations(taskID: taskID, entries: entries)
    }

    func setStatus(taskID: UUID, status: TaskStatus) async {
        await legacyStore().setStatus(taskID: taskID, status: status)
    }

    func saveSummary(taskID: UUID, summary: ConversationSummary) async {
        await legacyStore().saveSummary(taskID: taskID, summary: summary)
    }

    func end(taskID: UUID, summary: ConversationSummary?) async throws -> TaskSession {
        let store = await legacyStore()
        return try await store.end(taskID: taskID, summary: summary)
    }

    func list(filter: FeatureID?) async -> [TaskSession] {
        await legacyStore().list(filter: filter)
    }

    func task(id: UUID) async -> TaskSession? {
        await legacyStore().task(id: id)
    }

    func delete(id: UUID) async throws {
        let store = await legacyStore()
        try await store.delete(id: id)
    }

    // MARK: - TaskStoreV2 reads

    func readActiveTask(for feature: FeatureID) async -> TaskStoreReadResult<TaskSession?> {
        await performRead { await $0.readActiveTask(for: feature) }
    }

    func readUnfinishedTasks() async -> TaskStoreReadResult<[TaskSession]> {
        await performRead { await $0.readUnfinishedTasks() }
    }

    func readList(filter: FeatureID?) async -> TaskStoreReadResult<[TaskSession]> {
        await performRead { await $0.readList(filter: filter) }
    }

    func readTask(id: UUID) async -> TaskStoreReadResult<TaskSession?> {
        await performRead { await $0.readTask(id: id) }
    }

    // MARK: - TaskStoreV2 writes

    func startNew(_ draft: TaskDraft) async -> TaskStoreWriteResult<TaskSession> {
        await performWrite { await $0.startNew(draft) }
    }

    func append(_ entries: [TranscriptEntry], to taskID: UUID) async -> TaskStoreWriteOutcome {
        await performWrite { await $0.append(entries, to: taskID) }
    }

    func updateTranslations(_ entries: [TranscriptEntry], for taskID: UUID) async -> TaskStoreWriteOutcome {
        await performWrite { await $0.updateTranslations(entries, for: taskID) }
    }

    func setStatus(_ status: TaskStatus, for taskID: UUID) async -> TaskStoreWriteOutcome {
        await performWrite { await $0.setStatus(status, for: taskID) }
    }

    func saveSummary(_ summary: ConversationSummary, for taskID: UUID) async -> TaskStoreWriteOutcome {
        await performWrite { await $0.saveSummary(summary, for: taskID) }
    }

    func end(
        taskID: UUID,
        entries: [TranscriptEntry],
        summary: ConversationSummary?
    ) async -> TaskStoreEndResult {
        guard let store = await readyStore() else { return .notPersisted(unavailableReason) }
        return await retryingOnce(
            { await store.end(taskID: taskID, entries: entries, summary: summary) },
            isTransient: { result in
                if case .notPersisted(.saveFailed) = result { return true }
                return false
            }
        )
    }

    func deleteTask(id: UUID) async -> TaskStoreWriteOutcome {
        await performWrite { await $0.deleteTask(id: id) }
    }

    // MARK: - Private

    private var unavailableReason: TaskStoreFailureReason {
        if case let .unavailable(reason) = availability { return reason }
        return .unavailable
    }

    private func readyStore() async -> (any TaskStoreV2)? {
        await prepare()
        guard availability == .ready, let durable else { return nil }
        return durable
    }

    private func performRead<Value: Sendable>(
        _ operation: @MainActor (any TaskStoreV2) async -> TaskStoreReadResult<Value>
    ) async -> TaskStoreReadResult<Value> {
        guard let store = await readyStore() else { return .unavailable(unavailableReason) }
        return await operation(store)
    }

    private func performWrite(
        _ operation: @MainActor (any TaskStoreV2) async -> TaskStoreWriteOutcome
    ) async -> TaskStoreWriteOutcome {
        guard let store = await readyStore() else { return .notPersisted(unavailableReason) }
        return await retryingOnce(
            { await operation(store) },
            isTransient: { $0 == .notPersisted(.saveFailed) }
        )
    }

    private func performWrite<Value: Sendable>(
        _ operation: @MainActor (any TaskStoreV2) async -> TaskStoreWriteResult<Value>
    ) async -> TaskStoreWriteResult<Value> {
        guard let store = await readyStore() else { return .notPersisted(unavailableReason) }
        return await retryingOnce(
            { await operation(store) },
            isTransient: { result in
                if case .notPersisted(.saveFailed) = result { return true }
                return false
            }
        )
    }

    /// The seam retries a write that failed transiently exactly once. A second
    /// failure is returned to the caller; nothing polls or retries in the
    /// background.
    private func retryingOnce<T>(
        _ operation: @MainActor () async -> T,
        isTransient: (T) -> Bool
    ) async -> T {
        let first = await operation()
        guard isTransient(first) else { return first }
        return await operation()
    }

    /// Legacy call sites keep compiling during the expand step. They use the
    /// durable store once it is ready; on open failure they keep the pre-v2
    /// in-memory behavior (removed in ticket #12). The fallback is sticky so
    /// in-memory tasks do not disappear if a later retry succeeds.
    private func legacyStore() async -> any TaskStore {
        await prepare()
        if let legacyFallback { return legacyFallback }
        if let durable { return durable }
        DuiyiLog.session.error("SwiftData store unavailable, legacy calls continue in memory")
        let fallback = InMemoryTaskStore()
        legacyFallback = fallback
        return fallback
    }

    private func resolveOpen() async {
        if containerTask == nil {
            containerTask = makeOpenTask()
        }
        guard let task = containerTask else { return }
        let generation = openGeneration
        let container = await task.value
        guard generation == openGeneration, availability == .opening else { return }
        containerTask = nil
        if let container {
            durable = makeStore(container)
            availability = .ready
            AppLaunchTracker.shared.begin(.storeReady)
        } else {
            availability = .unavailable(.openFailed)
            DuiyiLog.session.error("SwiftData store unavailable; retry required before persistence can resume")
        }
    }

    private func makeOpenTask() -> Task<ModelContainer?, Never> {
        openGeneration += 1
        let opener = openContainer
        return Task.detached(priority: .utility) {
            await opener()
        }
    }

    /// Blocking file I/O: runs on a detached background task, never on MainActor.
    nonisolated static func openContainer() -> ModelContainer? {
        do {
            let schema = Schema([TaskEntity.self, TranscriptEntity.self])
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            let t0 = CFAbsoluteTimeGetCurrent()
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let dt = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            DuiyiLog.session.info("STORE open took \(Int(dt), privacy: .public)ms (background task)")
            return container
        } catch {
            return nil
        }
    }
}
