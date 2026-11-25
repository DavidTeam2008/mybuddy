#if DEBUG
import Foundation

/// Seeds ended history tasks for UI reproduction of list updates.
/// Launch with `-duiyi.seedHistory`. Debug builds only.
@MainActor
enum DebugHistorySeed {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-duiyi.seedHistory")
    }

    /// Optional `-duiyi.seedEntryCount <n>`: entries per seeded task, so device
    /// runs can reproduce a real task's cascade-delete and transcript length.
    static var entryCount: Int {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-duiyi.seedEntryCount") else { return 1 }
        let valueIndex = arguments.index(after: flag)
        guard valueIndex < arguments.endIndex,
              let count = Int(arguments[valueIndex]),
              count > 0
        else { return 1 }
        return count
    }

    static func seedIfRequested(into store: any TaskStoreV2, language: AppLanguage) async {
        guard isRequested else { return }
        // Deterministic fixture: clear prior ended tasks before seeding four.
        if case let .value(existing) = await store.readList(filter: nil) {
            for task in existing {
                _ = await store.deleteTask(id: task.id)
            }
        }

        let now = Date()
        // Two face-to-face tasks so the face-to-face filter shows the two-row
        // list shape from the device crash reports.
        let specs: [(FeatureID, AppLanguage, AppLanguage?)] = [
            (.faceToFace, .zhHans, .english),
            (.faceToFace, .english, .zhHans),
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
            let entries = (1...entryCount).map { line in
                TranscriptEntry(
                    id: UUID(),
                    speaker: line.isMultiple(of: 2) ? .user : .peer,
                    source: spec.1,
                    sourceText: "测试台词 \(index + 1)-\(line)",
                    translatedText: "Test line \(index + 1)-\(line)",
                    isFinal: true,
                    recordedAt: started.addingTimeInterval(Double(line))
                )
            }
            _ = await store.end(taskID: task.id, entries: entries, summary: nil)
        }
    }
}
#endif
