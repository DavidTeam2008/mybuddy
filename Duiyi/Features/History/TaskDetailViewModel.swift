import Foundation

/// Read/write state for one saved task. Every store call goes through the v2
/// result contract so a failure is shown to the user instead of being silently
/// swallowed.
@MainActor
@Observable
final class TaskDetailViewModel {
    let taskID: UUID
    private let store: any TaskStoreV2
    private let summarizer: any ConversationSummarizing

    private(set) var task: TaskSession?
    /// The last detail read failed. A previously loaded task stays visible.
    private(set) var readFailure: TaskStoreFailureReason?
    private(set) var summaryAvailability: SummaryAvailability = .unavailable
    private(set) var isSummarizing = false
    private(set) var summaryError: String?
    /// `saveSummary` failed after the summary was produced.
    private(set) var summarySaveFailure: TaskStoreFailureReason?
    /// Translation backfill failed after the translation was produced.
    private(set) var translationSaveFailure: TaskStoreFailureReason?
    private(set) var deleteFailure: TaskStoreFailureReason?
    private(set) var pendingDelete = false

    init(
        taskID: UUID,
        store: any TaskStoreV2,
        summarizer: any ConversationSummarizing
    ) {
        self.taskID = taskID
        self.store = store
        self.summarizer = summarizer
    }

    var showsStorageBanner: Bool {
        readFailure != nil || store.availability.isUnavailable
    }

    func load() async {
        switch await store.readTask(id: taskID) {
        case let .value(loaded):
            task = loaded
            readFailure = nil
        case let .unavailable(reason):
            readFailure = reason
        }
        summaryAvailability = await summarizer.availability()
    }

    /// Reopens a failed store and re-reads the task. Never backfills tasks that
    /// only exist in memory.
    func retry() async {
        await store.retry()
        await load()
    }

    func summarize(language: AppLanguage) async {
        guard var current = task, current.hasTranscript, !isSummarizing else { return }
        isSummarizing = true
        summaryError = nil
        summarySaveFailure = nil
        defer { isSummarizing = false }
        guard summaryAvailability == .available else { return }
        do {
            let summary = try await summarizer.summarize(
                entries: current.entries,
                outputLanguage: language
            )
            current.summary = summary
            task = current
            if case let .notPersisted(reason) = await store.saveSummary(summary, for: current.id) {
                summarySaveFailure = reason
            }
        } catch let error as DuiyiError {
            summaryError = error.userMessage(for: language)
        } catch {
            summaryError = DuiyiError.summaryEmpty.userMessage(for: language)
        }
    }

    /// Applies a translated line in memory, then persists it. Returns `false`
    /// when the backfill could not be saved; the in-memory text is kept so the
    /// user still sees the translation.
    @discardableResult
    func applyTranslation(entryID: UUID, text: String) async -> Bool {
        guard var current = task,
              let index = current.entries.firstIndex(where: { $0.id == entryID }) else {
            return false
        }
        current.entries[index].translatedText = text
        task = current
        translationSaveFailure = nil
        if case let .notPersisted(reason) = await store.updateTranslations(
            [current.entries[index]],
            for: current.id
        ) {
            translationSaveFailure = reason
            return false
        }
        return true
    }

    func requestDelete() {
        deleteFailure = nil
        pendingDelete = true
    }

    func cancelDelete() {
        pendingDelete = false
    }

    /// Deletes the task. Returns `true` only when the store confirmed the
    /// delete; the caller then navigates back to history.
    @discardableResult
    func confirmDelete() async -> Bool {
        pendingDelete = false
        switch await store.deleteTask(id: taskID) {
        case .persisted:
            deleteFailure = nil
            return true
        case let .notPersisted(reason):
            deleteFailure = reason
            return false
        }
    }
}
