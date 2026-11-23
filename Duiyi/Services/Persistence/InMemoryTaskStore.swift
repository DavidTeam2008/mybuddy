import Foundation

/// Process-local adapter used by tests, previews, and ephemeral compositions.
/// Every operation reports success through the v2 result contract, so it can
/// stand in for a durable store without hiding failures.
@MainActor
final class InMemoryTaskStore: TaskStoreV2 {
    var availability: TaskStoreAvailability { .ready }

    func prepare() async {}
    func retry() async {}

    private var tasks: [UUID: TaskSession] = [:]

    // MARK: - TaskStoreV2 reads

    func readActiveTask(for feature: FeatureID) async -> TaskStoreReadResult<TaskSession?> {
        .value(
            tasks.values
                .filter { $0.feature == feature && $0.status != .ended }
                .sorted { $0.startedAt > $1.startedAt }
                .first
        )
    }

    func readUnfinishedTasks() async -> TaskStoreReadResult<[TaskSession]> {
        .value(
            tasks.values
                .filter { $0.status != .ended }
                .sorted { $0.startedAt > $1.startedAt }
        )
    }

    func readList(filter: FeatureID?) async -> TaskStoreReadResult<[TaskSession]> {
        .value(
            tasks.values
                .filter { $0.status == .ended }
                .filter { filter == nil || $0.feature == filter }
                .sorted { $0.startedAt > $1.startedAt }
        )
    }

    func readTask(id: UUID) async -> TaskStoreReadResult<TaskSession?> {
        .value(tasks[id])
    }

    // MARK: - TaskStoreV2 writes

    func startNew(_ draft: TaskDraft) async -> TaskStoreWriteResult<TaskSession> {
        let session = TaskSession(
            id: UUID(),
            feature: draft.feature,
            status: .running,
            startedAt: draft.startedAt,
            endedAt: nil,
            title: draft.title,
            subtitle: nil,
            sourceLanguage: draft.sourceLanguage,
            targetLanguage: draft.targetLanguage,
            entries: [],
            summary: nil
        )
        tasks[session.id] = session
        return .persisted(session)
    }

    func append(_ entries: [TranscriptEntry], to taskID: UUID) async -> TaskStoreWriteOutcome {
        guard var task = tasks[taskID] else { return .notPersisted(.notFound) }
        // The transcript of an ended task is final; a late flush is a no-op,
        // not a persistence failure.
        guard task.status != .ended else { return .persisted }
        upsert(entries, into: &task)
        tasks[taskID] = task
        return .persisted
    }

    /// 只回填已有条目的译文；允许用于已结束任务，避免放宽 transcript 写入规则。
    func updateTranslations(_ entries: [TranscriptEntry], for taskID: UUID) async -> TaskStoreWriteOutcome {
        guard var task = tasks[taskID] else { return .notPersisted(.notFound) }
        var translations: [UUID: String] = [:]
        for entry in entries {
            translations[entry.id] = entry.translatedText
        }
        for index in task.entries.indices {
            if let translatedText = translations[task.entries[index].id] {
                task.entries[index].translatedText = translatedText
            }
        }
        tasks[taskID] = task
        return .persisted
    }

    func setStatus(_ status: TaskStatus, for taskID: UUID) async -> TaskStoreWriteOutcome {
        guard var task = tasks[taskID] else { return .notPersisted(.notFound) }
        guard task.status != .ended else { return .persisted }
        task.status = status
        tasks[taskID] = task
        return .persisted
    }

    func saveSummary(_ summary: ConversationSummary, for taskID: UUID) async -> TaskStoreWriteOutcome {
        guard var task = tasks[taskID] else { return .notPersisted(.notFound) }
        task.summary = summary
        tasks[taskID] = task
        return .persisted
    }

    func end(
        taskID: UUID,
        entries: [TranscriptEntry],
        summary: ConversationSummary?
    ) async -> TaskStoreEndResult {
        guard var task = tasks[taskID] else { return .notPersisted(.notFound) }
        upsert(entries, into: &task)
        let usable = task.entries.contains {
            !$0.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard usable else {
            tasks.removeValue(forKey: taskID)
            return .discardedEmpty
        }
        task.status = .ended
        task.endedAt = Date()
        if let summary {
            task.summary = summary
        }
        if task.feature == .meeting, task.subtitle == nil {
            task.subtitle = TaskTitle.subtitle(from: task.entries)
        }
        tasks[taskID] = task
        return .ended(task)
    }

    func deleteTask(id: UUID) async -> TaskStoreWriteOutcome {
        tasks.removeValue(forKey: id) != nil ? .persisted : .notPersisted(.notFound)
    }

    // MARK: - Private

    /// Upserts by entry id: same-id volatile updates replace in place, new ids
    /// append in order.
    private func upsert(_ entries: [TranscriptEntry], into task: inout TaskSession) {
        var map = Dictionary(uniqueKeysWithValues: task.entries.map { ($0.id, $0) })
        for entry in entries {
            map[entry.id] = entry
        }
        var seen = Set<UUID>()
        var ordered: [TranscriptEntry] = []
        for existing in task.entries {
            if let updated = map[existing.id] {
                ordered.append(updated)
                seen.insert(existing.id)
            }
        }
        for entry in entries where !seen.contains(entry.id) {
            ordered.append(entry)
        }
        task.entries = ordered
    }
}
