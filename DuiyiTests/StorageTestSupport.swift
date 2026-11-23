import Foundation
import Testing
@testable import Duiyi

/// A `TaskStoreV2` that can report an unavailable open, fail reads, and fail
/// individual writes. Reads and writes otherwise forward to an in-memory store
/// so tests can seed real task history.
@MainActor
final class ScriptedTaskStore: TaskStoreV2 {
    let base: InMemoryTaskStore

    var availability: TaskStoreAvailability
    /// When set, every read returns `.unavailable` with this reason even while
    /// `availability` is `.ready` (models a SwiftData fetch failure).
    var readFailure: TaskStoreFailureReason?
    var deleteFailure: TaskStoreFailureReason?
    var saveSummaryFailure: TaskStoreFailureReason?
    var updateTranslationsFailure: TaskStoreFailureReason?
    var startNewFailure: TaskStoreFailureReason?
    var appendFailure: TaskStoreFailureReason?
    var endFailure: TaskStoreFailureReason?
    var setStatusFailure: TaskStoreFailureReason?

    /// Availability applied by `retry()`; set to `.ready` to model recovery.
    var retryAvailability: TaskStoreAvailability = .ready

    /// Optional observer for cross-seam ordering tests. Receives stable event
    /// names such as `store-start-new`, `store-append`, and `store-end`.
    var eventSink: ((String) -> Void)?

    private(set) var prepareCalls = 0
    private(set) var retryCalls = 0
    private(set) var deleteCalls = 0
    private(set) var saveSummaryCalls = 0
    private(set) var updateTranslationsCalls = 0
    private(set) var startNewCalls = 0
    private(set) var appendCalls = 0
    private(set) var endCalls = 0

    init(
        availability: TaskStoreAvailability = .ready,
        base: InMemoryTaskStore = InMemoryTaskStore()
    ) {
        self.availability = availability
        self.base = base
    }

    func prepare() async {
        prepareCalls += 1
    }

    func retry() async {
        retryCalls += 1
        availability = retryAvailability
    }

    /// The reason reads currently fail, if any.
    private var readBlock: TaskStoreFailureReason? {
        if let readFailure { return readFailure }
        if case let .unavailable(reason) = availability { return reason }
        return nil
    }

    // MARK: - TaskStoreV2 reads

    func readActiveTask(for feature: FeatureID) async -> TaskStoreReadResult<TaskSession?> {
        if let readBlock { return .unavailable(readBlock) }
        return await base.readActiveTask(for: feature)
    }

    func readUnfinishedTasks() async -> TaskStoreReadResult<[TaskSession]> {
        if let readBlock { return .unavailable(readBlock) }
        return await base.readUnfinishedTasks()
    }

    func readList(filter: FeatureID?) async -> TaskStoreReadResult<[TaskSession]> {
        if let readBlock { return .unavailable(readBlock) }
        return await base.readList(filter: filter)
    }

    func readTask(id: UUID) async -> TaskStoreReadResult<TaskSession?> {
        if let readBlock { return .unavailable(readBlock) }
        return await base.readTask(id: id)
    }

    // MARK: - TaskStoreV2 writes

    func startNew(_ draft: TaskDraft) async -> TaskStoreWriteResult<TaskSession> {
        startNewCalls += 1
        eventSink?("store-start-new")
        if let startNewFailure { return .notPersisted(startNewFailure) }
        return await base.startNew(draft)
    }

    func append(_ entries: [TranscriptEntry], to taskID: UUID) async -> TaskStoreWriteOutcome {
        appendCalls += 1
        eventSink?("store-append")
        if let appendFailure { return .notPersisted(appendFailure) }
        return await base.append(entries, to: taskID)
    }

    func updateTranslations(_ entries: [TranscriptEntry], for taskID: UUID) async -> TaskStoreWriteOutcome {
        updateTranslationsCalls += 1
        if let updateTranslationsFailure { return .notPersisted(updateTranslationsFailure) }
        return await base.updateTranslations(entries, for: taskID)
    }

    func setStatus(_ status: TaskStatus, for taskID: UUID) async -> TaskStoreWriteOutcome {
        if let setStatusFailure { return .notPersisted(setStatusFailure) }
        return await base.setStatus(status, for: taskID)
    }

    func saveSummary(_ summary: ConversationSummary, for taskID: UUID) async -> TaskStoreWriteOutcome {
        saveSummaryCalls += 1
        if let saveSummaryFailure { return .notPersisted(saveSummaryFailure) }
        return await base.saveSummary(summary, for: taskID)
    }

    func end(
        taskID: UUID,
        entries: [TranscriptEntry],
        summary: ConversationSummary?
    ) async -> TaskStoreEndResult {
        endCalls += 1
        eventSink?("store-end")
        if let endFailure { return .notPersisted(endFailure) }
        return await base.end(taskID: taskID, entries: entries, summary: summary)
    }

    func deleteTask(id: UUID) async -> TaskStoreWriteOutcome {
        deleteCalls += 1
        if let deleteFailure { return .notPersisted(deleteFailure) }
        return await base.deleteTask(id: id)
    }
}

// MARK: - Test-only read helpers

/// The production success-only read methods were removed in ticket #12.
/// ViewModel tests assert stored state with those read shapes; these helpers
/// express the same reads through the v2 result contract. An unavailable read
/// is a test bug (silently mapping it to nil/empty would hide real failures),
/// so it records a test issue instead. Tests that assert failure use the
/// `read*` results directly.
@MainActor
extension TaskStoreV2 {
    func activeTask(for feature: FeatureID) async -> TaskSession? {
        switch await readActiveTask(for: feature) {
        case let .value(task):
            return task
        case let .unavailable(reason):
            Issue.record("Test-only activeTask(for:) read hit an unavailable store: \(reason)")
            return nil
        }
    }

    func unfinishedTasks() async -> [TaskSession] {
        switch await readUnfinishedTasks() {
        case let .value(tasks):
            return tasks
        case let .unavailable(reason):
            Issue.record("Test-only unfinishedTasks() read hit an unavailable store: \(reason)")
            return []
        }
    }

    func list(filter: FeatureID?) async -> [TaskSession] {
        switch await readList(filter: filter) {
        case let .value(tasks):
            return tasks
        case let .unavailable(reason):
            Issue.record("Test-only list(filter:) read hit an unavailable store: \(reason)")
            return []
        }
    }

    func task(id: UUID) async -> TaskSession? {
        switch await readTask(id: id) {
        case let .value(task):
            return task
        case let .unavailable(reason):
            Issue.record("Test-only task(id:) read hit an unavailable store: \(reason)")
            return nil
        }
    }
}

// MARK: - Seeding helpers

extension InMemoryTaskStore {
    /// Creates a real ended task with one usable transcript entry.
    func seedEndedTask(
        feature: FeatureID = .meeting,
        entryText: String = "预算确认一下"
    ) async throws -> TaskSession {
        let draft = TaskDraft(
            feature: feature,
            sourceLanguage: .zhHans,
            targetLanguage: feature == .meeting ? nil : .english,
            multilingual: false,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            title: "测试任务"
        )
        guard case let .persisted(session) = await startNew(draft) else {
            throw SeedError.startFailed
        }
        let entry = TranscriptEntry(
            id: UUID(),
            speaker: .user,
            source: .zhHans,
            sourceText: entryText,
            translatedText: "",
            isFinal: true
        )
        guard await append([entry], to: session.id) == .persisted else {
            throw SeedError.appendFailed
        }
        guard case let .ended(ended) = await end(taskID: session.id, entries: [], summary: nil) else {
            throw SeedError.endFailed
        }
        return ended
    }

    /// Creates a running task with one usable transcript entry.
    func seedRunningTask(
        feature: FeatureID = .meeting,
        entryText: String = "预算确认一下"
    ) async throws -> TaskSession {
        let draft = TaskDraft(
            feature: feature,
            sourceLanguage: .zhHans,
            targetLanguage: feature == .meeting ? nil : .english,
            multilingual: false,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            title: "测试任务"
        )
        guard case let .persisted(session) = await startNew(draft) else {
            throw SeedError.startFailed
        }
        let entry = TranscriptEntry(
            id: UUID(),
            speaker: .user,
            source: .zhHans,
            sourceText: entryText,
            translatedText: "",
            isFinal: true
        )
        guard await append([entry], to: session.id) == .persisted else {
            throw SeedError.appendFailed
        }
        guard case let .value(stored?) = await readTask(id: session.id) else {
            throw SeedError.startFailed
        }
        return stored
    }
}

enum SeedError: Error {
    case startFailed
    case appendFailed
    case endFailed
}
