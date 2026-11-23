import Foundation
import SwiftData

@MainActor
final class SwiftDataTaskStore: TaskStoreV2 {
    /// The container is already open when this adapter is constructed.
    var availability: TaskStoreAvailability { .ready }

    func prepare() async {}
    func retry() async {}

    private let context: ModelContext

    init(container: ModelContainer) {
        context = ModelContext(container)
        // Every mutation saves explicitly and reports its result to the seam.
        context.autosaveEnabled = false
    }

    // MARK: - TaskStoreV2 reads

    func readActiveTask(for feature: FeatureID) async -> TaskStoreReadResult<TaskSession?> {
        let raw = feature.rawValue
        let ended = TaskStatus.ended.rawValue
        var descriptor = FetchDescriptor<TaskEntity>(
            predicate: #Predicate { entity in
                entity.featureRaw == raw && entity.statusRaw != ended
            },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        do {
            return .value(try context.fetch(descriptor).first.flatMap(TaskMapping.session(from:)))
        } catch {
            logReadFailure(error)
            return .unavailable(.readFailed)
        }
    }

    func readUnfinishedTasks() async -> TaskStoreReadResult<[TaskSession]> {
        let ended = TaskStatus.ended.rawValue
        let descriptor = FetchDescriptor<TaskEntity>(
            predicate: #Predicate { entity in
                entity.statusRaw != ended
            },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        do {
            return .value(try context.fetch(descriptor).compactMap(TaskMapping.session(from:)))
        } catch {
            logReadFailure(error)
            return .unavailable(.readFailed)
        }
    }

    func readList(filter: FeatureID?) async -> TaskStoreReadResult<[TaskSession]> {
        do {
            return .value(try context.fetch(listDescriptor(filter: filter)).compactMap(TaskMapping.session(from:)))
        } catch {
            logReadFailure(error)
            return .unavailable(.readFailed)
        }
    }

    func readTask(id: UUID) async -> TaskStoreReadResult<TaskSession?> {
        do {
            return .value(try fetchEntity(id: id).flatMap(TaskMapping.session(from:)))
        } catch {
            logReadFailure(error)
            return .unavailable(.readFailed)
        }
    }

    // MARK: - TaskStoreV2 writes

    func startNew(_ draft: TaskDraft) async -> TaskStoreWriteResult<TaskSession> {
        let entity = TaskEntity(
            id: UUID(),
            featureRaw: draft.feature.rawValue,
            statusRaw: TaskStatus.running.rawValue,
            startedAt: draft.startedAt,
            title: draft.title,
            sourceLanguageRaw: draft.sourceLanguage.rawValue,
            targetLanguageRaw: draft.targetLanguage?.rawValue
        )
        context.insert(entity)
        do {
            try context.save()
        } catch {
            context.rollback()
            return .notPersisted(.saveFailed)
        }
        guard let session = TaskMapping.session(from: entity) else {
            return .notPersisted(.saveFailed)
        }
        return .persisted(session)
    }

    func append(_ entries: [TranscriptEntry], to taskID: UUID) async -> TaskStoreWriteOutcome {
        let entity: TaskEntity
        do {
            guard let found = try fetchEntity(id: taskID) else { return .notPersisted(.notFound) }
            entity = found
        } catch {
            return .notPersisted(.readFailed)
        }
        // The transcript of an ended task is final; a late flush is a no-op,
        // not a persistence failure that would mark the task unsaved.
        guard entity.statusRaw != TaskStatus.ended.rawValue else { return .persisted }
        upsert(entries, into: entity)
        do {
            try context.save()
        } catch {
            context.rollback()
            return .notPersisted(.saveFailed)
        }
        return .persisted
    }

    func updateTranslations(_ entries: [TranscriptEntry], for taskID: UUID) async -> TaskStoreWriteOutcome {
        let entity: TaskEntity
        do {
            guard let found = try fetchEntity(id: taskID) else { return .notPersisted(.notFound) }
            entity = found
        } catch {
            return .notPersisted(.readFailed)
        }
        applyTranslations(entries, to: entity)
        do {
            try context.save()
        } catch {
            context.rollback()
            return .notPersisted(.saveFailed)
        }
        return .persisted
    }

    func setStatus(_ status: TaskStatus, for taskID: UUID) async -> TaskStoreWriteOutcome {
        let entity: TaskEntity
        do {
            guard let found = try fetchEntity(id: taskID) else { return .notPersisted(.notFound) }
            entity = found
        } catch {
            return .notPersisted(.readFailed)
        }
        guard entity.statusRaw != TaskStatus.ended.rawValue else { return .persisted }
        entity.statusRaw = status.rawValue
        do {
            try context.save()
        } catch {
            context.rollback()
            return .notPersisted(.saveFailed)
        }
        return .persisted
    }

    func saveSummary(_ summary: ConversationSummary, for taskID: UUID) async -> TaskStoreWriteOutcome {
        let entity: TaskEntity
        do {
            guard let found = try fetchEntity(id: taskID) else { return .notPersisted(.notFound) }
            entity = found
        } catch {
            return .notPersisted(.readFailed)
        }
        entity.summaryText = summary.text
        entity.usedAppleIntelligence = summary.usedAppleIntelligence
        do {
            try context.save()
        } catch {
            context.rollback()
            return .notPersisted(.saveFailed)
        }
        return .persisted
    }

    func end(
        taskID: UUID,
        entries: [TranscriptEntry],
        summary: ConversationSummary?
    ) async -> TaskStoreEndResult {
        let entity: TaskEntity
        do {
            guard let found = try fetchEntity(id: taskID) else { return .notPersisted(.notFound) }
            entity = found
        } catch {
            return .notPersisted(.readFailed)
        }

        // Append pending entries first, then judge emptiness from the store's
        // transcript (existing + just-appended) before ending or deleting.
        upsert(entries, into: entity)
        let hasUsableContent = entity.entries.contains {
            TranscriptEntry.hasUsableText($0.sourceText)
        }
        if hasUsableContent {
            finish(entity, summary: summary)
        } else {
            context.delete(entity)
        }
        do {
            try context.save()
        } catch {
            // Roll back the pending append and the end/delete: the task stays
            // running (and undeleted) so the caller can retry or export.
            context.rollback()
            return .notPersisted(.saveFailed)
        }
        guard hasUsableContent else { return .discardedEmpty }
        guard let session = TaskMapping.session(from: entity) else {
            return .notPersisted(.saveFailed)
        }
        return .ended(session)
    }

    func deleteTask(id: UUID) async -> TaskStoreWriteOutcome {
        let entity: TaskEntity
        do {
            guard let found = try fetchEntity(id: id) else { return .notPersisted(.notFound) }
            entity = found
        } catch {
            return .notPersisted(.readFailed)
        }
        context.delete(entity)
        do {
            try context.save()
        } catch {
            context.rollback()
            return .notPersisted(.saveFailed)
        }
        return .persisted
    }

    // MARK: - Private

    private func fetchEntity(id: UUID) throws -> TaskEntity? {
        var descriptor = FetchDescriptor<TaskEntity>(
            predicate: #Predicate { entity in
                entity.id == id
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func listDescriptor(filter: FeatureID?) -> FetchDescriptor<TaskEntity> {
        let ended = TaskStatus.ended.rawValue
        if let filter {
            let raw = filter.rawValue
            return FetchDescriptor<TaskEntity>(
                predicate: #Predicate { entity in
                    entity.statusRaw == ended && entity.featureRaw == raw
                },
                sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
            )
        }
        return FetchDescriptor<TaskEntity>(
            predicate: #Predicate { entity in
                entity.statusRaw == ended
            },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
    }

    private func upsert(_ entries: [TranscriptEntry], into entity: TaskEntity) {
        var existing = Dictionary(uniqueKeysWithValues: entity.entries.map { ($0.id, $0) })
        var nextIndex = (entity.entries.map(\.sortIndex).max() ?? -1) + 1
        for entry in entries {
            if let current = existing[entry.id] {
                current.speakerRaw = entry.speaker.rawValue
                current.sourceRaw = entry.source.rawValue
                current.sourceText = entry.sourceText
                current.translatedText = entry.translatedText
                current.isFinal = entry.isFinal
                current.recordedAt = entry.recordedAt
            } else {
                let created = TranscriptEntity(
                    id: entry.id,
                    speakerRaw: entry.speaker.rawValue,
                    sourceRaw: entry.source.rawValue,
                    sourceText: entry.sourceText,
                    translatedText: entry.translatedText,
                    isFinal: entry.isFinal,
                    recordedAt: entry.recordedAt,
                    sortIndex: nextIndex
                )
                created.task = entity
                entity.entries.append(created)
                existing[entry.id] = created
                nextIndex += 1
            }
        }
    }

    private func applyTranslations(_ entries: [TranscriptEntry], to entity: TaskEntity) {
        var translations: [UUID: String] = [:]
        for entry in entries {
            translations[entry.id] = entry.translatedText
        }
        for stored in entity.entries {
            if let translatedText = translations[stored.id] {
                stored.translatedText = translatedText
            }
        }
    }

    private func finish(_ entity: TaskEntity, summary: ConversationSummary?) {
        entity.statusRaw = TaskStatus.ended.rawValue
        entity.endedAt = Date()
        if let summary {
            entity.summaryText = summary.text
            entity.usedAppleIntelligence = summary.usedAppleIntelligence
        }
        if entity.featureRaw == FeatureID.meeting.rawValue, entity.subtitle == nil {
            let session = TaskMapping.session(from: entity)
            entity.subtitle = session.flatMap { TaskTitle.subtitle(from: $0.entries) }
        }
    }

    private func logReadFailure(_ error: Error) {
        DuiyiLog.session.error("SwiftData read failed: \(error, privacy: .public)")
    }
}
