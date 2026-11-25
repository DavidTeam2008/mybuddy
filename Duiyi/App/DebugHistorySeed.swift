#if DEBUG
import Foundation

/// Seeds ended history tasks for UI reproduction of list updates.
/// Launch with `-duiyi.seedHistory`. Debug builds only.
@MainActor
enum DebugHistorySeed {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-duiyi.seedHistory")
    }

    static func seedIfRequested(into store: any TaskStoreV2, language: AppLanguage) async {
        guard isRequested else { return }
        // Deterministic fixture: clear prior ended tasks before seeding three.
        if case let .value(existing) = await store.readList(filter: nil) {
            for task in existing {
                _ = await store.deleteTask(id: task.id)
            }
        }

        let now = Date()
        let specs: [(FeatureID, AppLanguage, AppLanguage?)] = [
            (.faceToFace, .zhHans, .english),
            (.simultaneous, .english, .zhHans),
            (.meeting, .zhHans, nil),
        ]

        for (index, spec) in specs.enumerated() {
            let started = now.addingTimeInterval(-Double(index + 1) * 1800)
            let multilingual = spec.0 == .meeting
            let draft = TaskDraft(
                feature: spec.0,
                sourceLanguage: spec.1,
                targetLanguage: spec.2,
                multilingual: multilingual,
                startedAt: started,
                title: TaskTitle.make(
                    feature: spec.0,
                    source: spec.1,
                    target: spec.2,
                    startedAt: started,
                    language: language,
                    multilingual: multilingual
                )
            )
            guard case let .persisted(task) = await store.startNew(draft) else { continue }
            let entries = [
                TranscriptEntry(
                    id: UUID(),
                    speaker: .user,
                    source: spec.1,
                    sourceText: "测试台词 \(index + 1)",
                    translatedText: "Test line \(index + 1)",
                    isFinal: true,
                    recordedAt: started.addingTimeInterval(5)
                ),
            ]
            _ = await store.end(taskID: task.id, entries: entries, summary: nil)
        }
    }
}
#endif
