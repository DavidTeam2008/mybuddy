import Foundation
import SwiftData
import Testing
@testable import Duiyi

@MainActor
struct TaskStoreTests {
    @Test("Ending a task with captions writes history")
    func endWritesHistory() async throws {
        let store = InMemoryTaskStore()
        let session = try await startDraft(
            on: store,
            feature: .simultaneous,
            source: .english,
            target: .zhHans
        )
        let entry = TranscriptEntry(
            id: UUID(),
            speaker: .peer,
            source: .english,
            sourceText: "See you at six",
            translatedText: "六点见",
            isFinal: true
        )
        #expect(await store.append([entry], to: session.id) == .persisted)
        guard case let .ended(saved) = await store.end(taskID: session.id, entries: [], summary: nil) else {
            Issue.record("Expected the task to end")
            return
        }
        #expect(saved.status == .ended)
        guard case let .value(listed) = await store.readList(filter: .simultaneous) else {
            Issue.record("Expected history to be readable")
            return
        }
        #expect(listed.count == 1)
        #expect(listed.first?.entries.first?.translatedText == "六点见")
    }

    @Test("Deleting one task leaves the other")
    func deleteDoesNotAffectOther() async throws {
        let store = InMemoryTaskStore()
        let first = try await startDraft(
            on: store,
            feature: .faceToFace,
            source: .zhHans,
            target: .english
        )
        #expect(
            await store.append(
                [
                    TranscriptEntry(
                        id: UUID(),
                        speaker: .user,
                        source: .zhHans,
                        sourceText: "好的",
                        translatedText: "Okay",
                        isFinal: true
                    )
                ],
                to: first.id
            ) == .persisted
        )
        _ = await store.end(taskID: first.id, entries: [], summary: nil)
        let second = try await startDraft(
            on: store,
            feature: .meeting,
            source: .zhHans,
            target: nil,
            multilingual: true
        )
        #expect(
            await store.append(
                [
                    TranscriptEntry(
                        id: UUID(),
                        speaker: .user,
                        source: .zhHans,
                        sourceText: "预算确认一下",
                        translatedText: "",
                        isFinal: true
                    )
                ],
                to: second.id
            ) == .persisted
        )
        _ = await store.end(taskID: second.id, entries: [], summary: nil)
        #expect(await store.deleteTask(id: first.id) == .persisted)
        guard case let .value(remaining) = await store.readList(filter: nil) else {
            Issue.record("Expected history to be readable")
            return
        }
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == second.id)
    }

    @Test("Unfinished tasks survive as running")
    func unfinishedStayActive() async throws {
        let store = InMemoryTaskStore()
        let session = try await startDraft(
            on: store,
            feature: .faceToFace,
            source: .zhHans,
            target: .english
        )
        guard case let .value(active) = await store.readActiveTask(for: .faceToFace) else {
            Issue.record("Expected the active task to be readable")
            return
        }
        #expect(active?.id == session.id)
        #expect(active?.status == .running)
        guard case let .value(unfinished) = await store.readUnfinishedTasks() else {
            Issue.record("Expected unfinished tasks to be readable")
            return
        }
        #expect(unfinished.count == 1)
    }

    @Test("Ended task translation backfill survives reload in memory")
    func endedTaskTranslationBackfillInMemory() async throws {
        try await assertEndedTranslationBackfill(InMemoryTaskStore())
    }

    @Test("Ended task translation backfill survives reload in SwiftData")
    func endedTaskTranslationBackfillInSwiftData() async throws {
        let schema = Schema([TaskEntity.self, TranscriptEntity.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        try await assertEndedTranslationBackfill(SwiftDataTaskStore(container: container))
    }

    private func assertEndedTranslationBackfill(_ store: any TaskStoreV2) async throws {
        let session = try await startDraft(
            on: store,
            feature: .simultaneous,
            source: .english,
            target: .zhHans
        )
        let entry = TranscriptEntry(
            id: UUID(),
            speaker: .peer,
            source: .english,
            sourceText: "See you at six",
            translatedText: "",
            isFinal: true
        )
        #expect(await store.append([entry], to: session.id) == .persisted)
        guard case .ended = await store.end(taskID: session.id, entries: [], summary: nil) else {
            Issue.record("Expected the task to end")
            return
        }

        var ignoredMutation = entry
        ignoredMutation.sourceText = "must not mutate ended transcript"
        #expect(await store.append([ignoredMutation], to: session.id) == .persisted)
        guard case let .value(afterAppend?) = await store.readTask(id: session.id) else {
            Issue.record("Expected the ended task to be readable")
            return
        }
        #expect(afterAppend.entries.first?.sourceText == "See you at six")

        var translated = entry
        translated.translatedText = "六点见"
        #expect(await store.updateTranslations([translated], for: session.id) == .persisted)

        guard case let .value(reloaded?) = await store.readTask(id: session.id) else {
            Issue.record("Expected the ended task to be readable")
            return
        }
        #expect(reloaded.entries.first?.translatedText == "六点见")
    }

    private func startDraft(
        on store: any TaskStoreV2,
        feature: FeatureID,
        source: AppLanguage,
        target: AppLanguage?,
        multilingual: Bool = false
    ) async throws -> TaskSession {
        let draft = TaskDraft(
            feature: feature,
            sourceLanguage: source,
            targetLanguage: target,
            multilingual: multilingual,
            startedAt: Date(),
            title: "测试任务"
        )
        guard case let .persisted(session) = await store.startNew(draft) else {
            Issue.record("Expected the draft to persist")
            throw TestStoreError.startFailed
        }
        return session
    }
}

private enum TestStoreError: Error {
    case startFailed
}
