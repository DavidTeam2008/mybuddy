import Foundation
import SwiftData
import Testing
@testable import Duiyi

@MainActor
struct TaskStoreV2Tests {
    @Test("In-memory store is ready without preparation")
    func memoryStoreIsReady() async {
        let store = InMemoryTaskStore()
        #expect(store.availability == .ready)
        await store.prepare()
        #expect(store.availability == .ready)
        await store.retry()
        #expect(store.availability == .ready)
    }

    @Test("Empty reads are values, not failures")
    func emptyReadsAreValues() async {
        let store = InMemoryTaskStore()
        #expect(await store.readActiveTask(for: .meeting) == .value(nil))
        #expect(await store.readUnfinishedTasks() == .value([]))
        #expect(await store.readList(filter: nil) == .value([]))
        #expect(await store.readTask(id: UUID()) == .value(nil))
    }

    @Test("A draft creates a task with the provided localized title")
    func draftCreatesTask() async throws {
        let store = InMemoryTaskStore()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let draft = TaskDraft(
            feature: .faceToFace,
            sourceLanguage: .zhHans,
            targetLanguage: .english,
            multilingual: false,
            startedAt: startedAt,
            title: "本地化标题"
        )
        let session = try #require(await store.startNew(draft).persistedValue)
        #expect(session.feature == .faceToFace)
        #expect(session.title == "本地化标题")
        #expect(session.sourceLanguage == .zhHans)
        #expect(session.targetLanguage == .english)
        #expect(session.startedAt == startedAt)
        #expect(session.status == .running)
        #expect(await store.readActiveTask(for: .faceToFace) == .value(session))
    }

    @Test("Appending the same entry id upserts once")
    func appendUpsertsByID() async throws {
        let store = InMemoryTaskStore()
        let session = try #require(await store.startNew(makeDraft()).persistedValue)
        let entryID = UUID()
        var entry = TranscriptEntry(
            id: entryID,
            speaker: .user,
            source: .zhHans,
            sourceText: "你好",
            translatedText: "",
            isFinal: false
        )
        #expect(await store.append([entry], to: session.id) == .persisted)
        entry.sourceText = "你好，世界"
        entry.translatedText = "Hello, world"
        entry.isFinal = true
        #expect(await store.append([entry], to: session.id) == .persisted)

        let reloaded = try storedTask(await store.readTask(id: session.id))
        #expect(reloaded.entries.count == 1)
        #expect(reloaded.entries.first?.sourceText == "你好，世界")
        #expect(reloaded.entries.first?.translatedText == "Hello, world")
    }

    @Test("Status, summary, translation backfill and delete report persisted")
    func writesReportPersisted() async throws {
        let store = InMemoryTaskStore()
        let session = try #require(await store.startNew(makeDraft()).persistedValue)
        let entry = TranscriptEntry(
            id: UUID(),
            speaker: .user,
            source: .zhHans,
            sourceText: "预算确认一下",
            translatedText: "",
            isFinal: true
        )
        #expect(await store.append([entry], to: session.id) == .persisted)
        #expect(await store.setStatus(.pausedListening, for: session.id) == .persisted)
        #expect(await store.saveSummary(ConversationSummary(text: "总结", usedAppleIntelligence: true), for: session.id) == .persisted)
        var translated = entry
        translated.translatedText = "Confirm the budget"
        #expect(await store.updateTranslations([translated], for: session.id) == .persisted)

        let reloaded = try storedTask(await store.readTask(id: session.id))
        #expect(reloaded.status == .pausedListening)
        #expect(reloaded.summary?.text == "总结")
        #expect(reloaded.entries.first?.translatedText == "Confirm the budget")

        #expect(await store.deleteTask(id: session.id) == .persisted)
        #expect(await store.readTask(id: session.id) == .value(nil))
    }

    @Test("Writes to an unknown task report notFound")
    func writesToUnknownTaskReportNotFound() async {
        let store = InMemoryTaskStore()
        let missing = UUID()
        let entry = TranscriptEntry(
            id: UUID(),
            speaker: .user,
            source: .zhHans,
            sourceText: "你好",
            translatedText: "",
            isFinal: true
        )
        #expect(await store.append([entry], to: missing) == .notPersisted(.notFound))
        #expect(await store.updateTranslations([entry], for: missing) == .notPersisted(.notFound))
        #expect(await store.setStatus(.running, for: missing) == .notPersisted(.notFound))
        #expect(await store.saveSummary(ConversationSummary(text: "总结", usedAppleIntelligence: true), for: missing) == .notPersisted(.notFound))
        #expect(await store.deleteTask(id: missing) == .notPersisted(.notFound))
    }

    @Test("Ending appends pending entries and returns the ended session")
    func endPersistsPendingEntries() async throws {
        let store = InMemoryTaskStore()
        let session = try #require(await store.startNew(makeDraft(feature: .simultaneous, source: .english, target: .zhHans)).persistedValue)
        let persisted = TranscriptEntry(
            id: UUID(),
            speaker: .peer,
            source: .english,
            sourceText: "See you at six",
            translatedText: "六点见",
            isFinal: true
        )
        #expect(await store.append([persisted], to: session.id) == .persisted)
        let pending = TranscriptEntry(
            id: UUID(),
            speaker: .peer,
            source: .english,
            sourceText: "Bring the notes",
            translatedText: "带上笔记",
            isFinal: true
        )
        let summary = ConversationSummary(text: "总结", usedAppleIntelligence: true)

        let result = await store.end(taskID: session.id, entries: [pending], summary: summary)
        let ended = try #require(result.endedSession)
        #expect(ended.status == .ended)
        #expect(ended.endedAt != nil)
        #expect(ended.summary == summary)
        #expect(ended.entries.map(\.id) == [persisted.id, pending.id])
        #expect(await store.readUnfinishedTasks() == .value([]))
        #expect(await store.readList(filter: .simultaneous) == .value([ended]))
    }

    @Test("Ending a task whose only content is whitespace discards it")
    func endDiscardsWhitespaceOnlyTask() async throws {
        let store = InMemoryTaskStore()
        let session = try #require(await store.startNew(makeDraft()).persistedValue)
        let blank = TranscriptEntry(
            id: UUID(),
            speaker: .user,
            source: .zhHans,
            sourceText: "   \n",
            translatedText: "ignored",
            isFinal: true
        )

        let result = await store.end(taskID: session.id, entries: [blank], summary: nil)
        #expect(result == .discardedEmpty)
        #expect(await store.readTask(id: session.id) == .value(nil))
        #expect(await store.readList(filter: nil) == .value([]))
    }

    @Test("Ending judges emptiness from the persisted transcript")
    func endUsesPersistedTranscript() async throws {
        let store = InMemoryTaskStore()
        let session = try #require(await store.startNew(makeDraft(feature: .meeting)).persistedValue)
        let persisted = TranscriptEntry(
            id: UUID(),
            speaker: .user,
            source: .zhHans,
            sourceText: "预算确认一下",
            translatedText: "",
            isFinal: true
        )
        #expect(await store.append([persisted], to: session.id) == .persisted)

        let result = await store.end(taskID: session.id, entries: [], summary: nil)
        let ended = try #require(result.endedSession)
        #expect(ended.entries.map(\.id) == [persisted.id])
        #expect(await store.readList(filter: .meeting) == .value([ended]))
    }

    @Test("Ending an unknown task reports notFound and deletes nothing")
    func endUnknownTaskReportsNotFound() async {
        let store = InMemoryTaskStore()
        let result = await store.end(taskID: UUID(), entries: [], summary: nil)
        #expect(result == .notPersisted(.notFound))
        #expect(await store.readList(filter: nil) == .value([]))
    }

    @Test("SwiftData adapter implements the v2 read and write contract")
    func swiftDataContract() async throws {
        let store = try makeSwiftDataStore()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let draft = TaskDraft(
            feature: .simultaneous,
            sourceLanguage: .english,
            targetLanguage: .zhHans,
            multilingual: false,
            startedAt: startedAt,
            title: "本地化标题"
        )
        let session = try #require(await store.startNew(draft).persistedValue)
        #expect(session.title == "本地化标题")
        #expect(session.startedAt == startedAt)
        #expect(await store.readActiveTask(for: .simultaneous) == .value(session))

        let entry = TranscriptEntry(
            id: UUID(),
            speaker: .peer,
            source: .english,
            sourceText: "See you at six",
            translatedText: "",
            isFinal: true
        )
        #expect(await store.append([entry], to: session.id) == .persisted)
        #expect(await store.setStatus(.pausedListening, for: session.id) == .persisted)
        #expect(await store.saveSummary(ConversationSummary(text: "总结", usedAppleIntelligence: true), for: session.id) == .persisted)
        var translated = entry
        translated.translatedText = "六点见"
        #expect(await store.updateTranslations([translated], for: session.id) == .persisted)

        let pending = TranscriptEntry(
            id: UUID(),
            speaker: .peer,
            source: .english,
            sourceText: "Bring the notes",
            translatedText: "带上笔记",
            isFinal: true
        )
        let result = await store.end(taskID: session.id, entries: [pending], summary: nil)
        let ended = try #require(result.endedSession)
        #expect(ended.status == .ended)
        #expect(ended.entries.map(\.id) == [entry.id, pending.id])
        #expect(ended.entries.first?.translatedText == "六点见")
        #expect(ended.summary?.text == "总结")
        #expect(await store.readUnfinishedTasks() == .value([]))
        #expect(await store.readList(filter: .simultaneous) == .value([ended]))

        #expect(await store.deleteTask(id: session.id) == .persisted)
        #expect(await store.readTask(id: session.id) == .value(nil))
        #expect(await store.deleteTask(id: session.id) == .notPersisted(.notFound))
        #expect(await store.end(taskID: UUID(), entries: [], summary: nil) == .notPersisted(.notFound))
    }

    @Test("SwiftData adapter discards an empty task on end")
    func swiftDataDiscardsEmptyTask() async throws {
        let store = try makeSwiftDataStore()
        let session = try #require(await store.startNew(makeDraft()).persistedValue)
        let blank = TranscriptEntry(
            id: UUID(),
            speaker: .user,
            source: .zhHans,
            sourceText: " \n",
            translatedText: "",
            isFinal: true
        )
        #expect(await store.end(taskID: session.id, entries: [blank], summary: nil) == .discardedEmpty)
        #expect(await store.readTask(id: session.id) == .value(nil))
    }

    @Test("SwiftData writes are saved explicitly for other contexts")
    func swiftDataExplicitSave() async throws {
        let schema = Schema([TaskEntity.self, TranscriptEntity.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let writer = SwiftDataTaskStore(container: container)
        let reader = SwiftDataTaskStore(container: container)

        let session = try #require(await writer.startNew(makeDraft()).persistedValue)
        #expect(await reader.readTask(id: session.id) == .value(session))

        let entry = TranscriptEntry(
            id: UUID(),
            speaker: .user,
            source: .zhHans,
            sourceText: "预算确认一下",
            translatedText: "",
            isFinal: true
        )
        #expect(await writer.append([entry], to: session.id) == .persisted)
        let reloaded = try storedTask(await reader.readTask(id: session.id))
        #expect(reloaded.entries.first?.sourceText == "预算确认一下")
    }

    @Test("A v1 store reopens and round-trips task and transcript")
    func v1StoreRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "duiyi-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "store.sqlite")
        let schema = Schema([TaskEntity.self, TranscriptEntity.self])

        let sessionID: UUID
        do {
            // Write through the pre-v2 (v1) API to model an existing store.
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
            let legacyStore = SwiftDataTaskStore(container: container)
            let session = try await legacyStore.startNew(
                feature: .meeting,
                source: .zhHans,
                target: nil,
                multilingual: false
            )
            sessionID = session.id
            await legacyStore.append(
                taskID: session.id,
                entries: [
                    TranscriptEntry(
                        id: UUID(),
                        speaker: .user,
                        source: .zhHans,
                        sourceText: "预算确认一下",
                        translatedText: "",
                        isFinal: true
                    )
                ]
            )
            _ = try await legacyStore.end(taskID: session.id, summary: nil)
        }

        let reopenedContainer = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        let reopened = SwiftDataTaskStore(container: reopenedContainer)
        let task = try storedTask(await reopened.readTask(id: sessionID))
        #expect(task.feature == .meeting)
        #expect(task.status == .ended)
        #expect(task.entries.first?.sourceText == "预算确认一下")
        #expect(await reopened.readList(filter: .meeting) == .value([task]))

        var descriptor = FetchDescriptor<TaskEntity>()
        descriptor.fetchLimit = 1
        let entity = try #require(try reopenedContainer.mainContext.fetch(descriptor).first)
        #expect(entity.schemaVersion == 1)
    }

    @Test("Deferred store reports open failure and becomes ready after retry")
    func deferredOpenFailureAndRetry() async throws {
        let container = try makeInMemoryContainer()
        let opener = ScriptedOpener([nil, container])
        let store = DeferredTaskStore(
            warmImmediately: false,
            openContainer: { await opener.next() },
            makeStore: { _ in InMemoryTaskStore() }
        )
        #expect(store.availability == .opening)

        await store.prepare()
        #expect(store.availability == .unavailable(.openFailed))
        #expect(await store.readTask(id: UUID()) == .unavailable(.openFailed))
        #expect(await store.readUnfinishedTasks() == .unavailable(.openFailed))
        #expect(await store.startNew(makeDraft()) == .notPersisted(.openFailed))

        await store.retry()
        #expect(store.availability == .ready)
        #expect(await store.readTask(id: UUID()) == .value(nil))
    }

    @Test("Deferred store retries a transient write failure once")
    func deferredRetriesWriteOnce() async throws {
        let container = try makeInMemoryContainer()
        let fake = FailureInjectingTaskStore(writeFailures: 1)
        let store = DeferredTaskStore(
            warmImmediately: false,
            openContainer: { container },
            makeStore: { _ in fake }
        )

        let result = await store.startNew(makeDraft(feature: .faceToFace, source: .zhHans, target: .english))
        let session = try #require(result.persistedValue)
        #expect(fake.writeAttempts == 2)
        #expect(await fake.base.readTask(id: session.id) == .value(session))
    }

    @Test("Deferred store stops after one retry when saving keeps failing")
    func deferredStopsAfterOneRetry() async throws {
        let container = try makeInMemoryContainer()
        let fake = FailureInjectingTaskStore(writeFailures: .max)
        let store = DeferredTaskStore(
            warmImmediately: false,
            openContainer: { container },
            makeStore: { _ in fake }
        )
        let seeded = try #require(await fake.base.startNew(makeDraft()).persistedValue)
        let pending = TranscriptEntry(
            id: UUID(),
            speaker: .user,
            source: .zhHans,
            sourceText: "预算确认一下",
            translatedText: "",
            isFinal: true
        )

        let result = await store.end(taskID: seeded.id, entries: [pending], summary: nil)
        #expect(result == .notPersisted(.saveFailed))
        #expect(fake.writeAttempts == 2)

        // The task stays running and undeleted; the pending entry is not lost
        // from the persisted transcript because the failed write did not happen.
        let stored = try storedTask(await fake.base.readTask(id: seeded.id))
        #expect(stored.status == .running)
        #expect(stored.entries.isEmpty)
    }

    @Test("Deferred store ends the task when the retried save succeeds")
    func deferredEndSucceedsAfterRetry() async throws {
        let container = try makeInMemoryContainer()
        let fake = FailureInjectingTaskStore(writeFailures: 1)
        let store = DeferredTaskStore(
            warmImmediately: false,
            openContainer: { container },
            makeStore: { _ in fake }
        )
        let seeded = try #require(await fake.base.startNew(makeDraft()).persistedValue)
        let pending = TranscriptEntry(
            id: UUID(),
            speaker: .user,
            source: .zhHans,
            sourceText: "预算确认一下",
            translatedText: "",
            isFinal: true
        )

        let result = await store.end(taskID: seeded.id, entries: [pending], summary: nil)
        #expect(fake.writeAttempts == 2)
        let ended = try #require(result.endedSession)
        #expect(ended.status == .ended)
        #expect(ended.entries.map(\.id) == [pending.id])
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([TaskEntity.self, TranscriptEntity.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func makeSwiftDataStore() throws -> SwiftDataTaskStore {
        let schema = Schema([TaskEntity.self, TranscriptEntity.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return SwiftDataTaskStore(container: container)
    }

    private func storedTask(_ result: TaskStoreReadResult<TaskSession?>) throws -> TaskSession {
        let optional = try #require(result.readValue)
        return try #require(optional)
    }

    private func makeDraft(
        feature: FeatureID = .meeting,
        source: AppLanguage = .zhHans,
        target: AppLanguage? = nil
    ) -> TaskDraft {
        TaskDraft(
            feature: feature,
            sourceLanguage: source,
            targetLanguage: target,
            multilingual: false,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            title: "测试任务"
        )
    }
}

private actor ScriptedOpener {
    private var containers: [ModelContainer?]

    init(_ containers: [ModelContainer?]) {
        self.containers = containers
    }

    func next() -> ModelContainer? {
        containers.isEmpty ? nil : containers.removeFirst()
    }
}

/// A fake store that can fail a number of consecutive writes, to exercise the
/// seam's one-retry rule and the notPersisted path.
@MainActor
private final class FailureInjectingTaskStore: TaskStoreV2 {
    let base = InMemoryTaskStore()
    private var writeFailuresRemaining: Int
    private(set) var writeAttempts = 0

    var availability: TaskStoreAvailability { .ready }

    init(writeFailures: Int) {
        writeFailuresRemaining = writeFailures
    }

    func prepare() async {}
    func retry() async {}

    // MARK: - TaskStore (legacy) forwarding

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
        try await base.startNew(feature: feature, source: source, target: target, multilingual: multilingual)
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
        await base.readActiveTask(for: feature)
    }

    func readUnfinishedTasks() async -> TaskStoreReadResult<[TaskSession]> {
        await base.readUnfinishedTasks()
    }

    func readList(filter: FeatureID?) async -> TaskStoreReadResult<[TaskSession]> {
        await base.readList(filter: filter)
    }

    func readTask(id: UUID) async -> TaskStoreReadResult<TaskSession?> {
        await base.readTask(id: id)
    }

    // MARK: - TaskStoreV2 writes with injected failures

    func startNew(_ draft: TaskDraft) async -> TaskStoreWriteResult<TaskSession> {
        guard !consumeFailure() else { return .notPersisted(.saveFailed) }
        return await base.startNew(draft)
    }

    func append(_ entries: [TranscriptEntry], to taskID: UUID) async -> TaskStoreWriteOutcome {
        guard !consumeFailure() else { return .notPersisted(.saveFailed) }
        return await base.append(entries, to: taskID)
    }

    func updateTranslations(_ entries: [TranscriptEntry], for taskID: UUID) async -> TaskStoreWriteOutcome {
        guard !consumeFailure() else { return .notPersisted(.saveFailed) }
        return await base.updateTranslations(entries, for: taskID)
    }

    func setStatus(_ status: TaskStatus, for taskID: UUID) async -> TaskStoreWriteOutcome {
        guard !consumeFailure() else { return .notPersisted(.saveFailed) }
        return await base.setStatus(status, for: taskID)
    }

    func saveSummary(_ summary: ConversationSummary, for taskID: UUID) async -> TaskStoreWriteOutcome {
        guard !consumeFailure() else { return .notPersisted(.saveFailed) }
        return await base.saveSummary(summary, for: taskID)
    }

    func end(
        taskID: UUID,
        entries: [TranscriptEntry],
        summary: ConversationSummary?
    ) async -> TaskStoreEndResult {
        guard !consumeFailure() else { return .notPersisted(.saveFailed) }
        return await base.end(taskID: taskID, entries: entries, summary: summary)
    }

    func deleteTask(id: UUID) async -> TaskStoreWriteOutcome {
        guard !consumeFailure() else { return .notPersisted(.saveFailed) }
        return await base.deleteTask(id: id)
    }

    private func consumeFailure() -> Bool {
        writeAttempts += 1
        guard writeFailuresRemaining > 0 else { return false }
        writeFailuresRemaining -= 1
        return true
    }
}

private extension TaskStoreWriteResult {
    var persistedValue: Value? {
        guard case let .persisted(value) = self else { return nil }
        return value
    }
}

private extension TaskStoreReadResult {
    var readValue: Value? {
        guard case let .value(value) = self else { return nil }
        return value
    }
}

private extension TaskStoreEndResult {
    var endedSession: TaskSession? {
        guard case let .ended(session) = self else { return nil }
        return session
    }
}
