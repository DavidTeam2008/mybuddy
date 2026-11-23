import Foundation
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

    /// Availability applied by `retry()`; set to `.ready` to model recovery.
    var retryAvailability: TaskStoreAvailability = .ready

    private(set) var prepareCalls = 0
    private(set) var retryCalls = 0
    private(set) var deleteCalls = 0
    private(set) var saveSummaryCalls = 0
    private(set) var updateTranslationsCalls = 0

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

    // MARK: - TaskStore (legacy, forwarded)

    func activeTask(for feature: FeatureID) async -> TaskSession? {
        await base.activeTask(for: feature)
    }

    func unfinishedTasks() async -> [TaskSession] {
        await base.unfinishedTasks()
    }

    func startNew(
        feature: FeatureID,
        source: AppLanguage,
        target: AppLanguage?,
        multilingual: Bool
    ) async throws -> TaskSession {
        try await base.startNew(
            feature: feature,
            source: source,
            target: target,
            multilingual: multilingual
        )
    }

    func append(taskID: UUID, entries: [TranscriptEntry]) async {
        await base.append(taskID: taskID, entries: entries)
    }

    func updateTranslations(taskID: UUID, entries: [TranscriptEntry]) async {
        await base.updateTranslations(taskID: taskID, entries: entries)
    }

    func setStatus(taskID: UUID, status: TaskStatus) async {
        await base.setStatus(taskID: taskID, status: status)
    }

    func saveSummary(taskID: UUID, summary: ConversationSummary) async {
        await base.saveSummary(taskID: taskID, summary: summary)
    }

    func end(taskID: UUID, summary: ConversationSummary?) async throws -> TaskSession {
        try await base.end(taskID: taskID, summary: summary)
    }

    func list(filter: FeatureID?) async -> [TaskSession] {
        await base.list(filter: filter)
    }

    func task(id: UUID) async -> TaskSession? {
        await base.task(id: id)
    }

    func delete(id: UUID) async throws {
        try await base.delete(id: id)
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
        await base.startNew(draft)
    }

    func append(_ entries: [TranscriptEntry], to taskID: UUID) async -> TaskStoreWriteOutcome {
        await base.append(entries, to: taskID)
    }

    func updateTranslations(_ entries: [TranscriptEntry], for taskID: UUID) async -> TaskStoreWriteOutcome {
        updateTranslationsCalls += 1
        if let updateTranslationsFailure { return .notPersisted(updateTranslationsFailure) }
        return await base.updateTranslations(entries, for: taskID)
    }

    func setStatus(_ status: TaskStatus, for taskID: UUID) async -> TaskStoreWriteOutcome {
        await base.setStatus(status, for: taskID)
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
        await base.end(taskID: taskID, entries: entries, summary: summary)
    }

    func deleteTask(id: UUID) async -> TaskStoreWriteOutcome {
        deleteCalls += 1
        if let deleteFailure { return .notPersisted(deleteFailure) }
        return await base.deleteTask(id: id)
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
