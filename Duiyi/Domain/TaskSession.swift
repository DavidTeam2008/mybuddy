import Foundation

enum TaskStatus: String, Codable, Sendable, Hashable {
    case running
    case pausedListening
    case ended
}

struct TaskSession: Identifiable, Equatable, Sendable {
    var id: UUID
    var feature: FeatureID
    var status: TaskStatus
    var startedAt: Date
    var endedAt: Date?
    var title: String
    var subtitle: String?
    var sourceLanguage: AppLanguage
    var targetLanguage: AppLanguage?
    var entries: [TranscriptEntry]
    var summary: ConversationSummary?

    var hasTranscript: Bool {
        entries.contains(where: \.hasUsableText)
    }

    var duration: TimeInterval {
        (endedAt ?? .now).timeIntervalSince(startedAt)
    }
}

enum TaskTitle {
    static func make(
        feature: FeatureID,
        source: AppLanguage,
        target: AppLanguage?,
        startedAt: Date,
        language: AppLanguage,
        multilingual: Bool = false
    ) -> String {
        let day = startedAt.formatted(
            Date.FormatStyle(date: .abbreviated, time: .omitted)
                .month()
                .day()
                .locale(language.locale)
        )
        let module = Copy.featureTitle(feature, for: language)
        switch feature {
        case .faceToFace:
            let pair = target ?? source.defaultPeer
            return "\(day) \(module) · \(source.nativeName) ↔ \(pair.nativeName)"
        case .simultaneous:
            let pair = target ?? source.defaultPeer
            return "\(day) \(module) · \(source.nativeName) → \(pair.nativeName)"
        case .meeting:
            let label = multilingual
                ? Copy.meetingMultilingual(for: language)
                : source.nativeName
            return "\(day) \(module) · \(label)"
        }
    }

    static func subtitle(from entries: [TranscriptEntry]) -> String? {
        guard let first = entries.first(where: {
            !$0.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            return nil
        }
        let text = first.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count <= 16 {
            return text
        }
        return String(text.prefix(16))
    }
}

enum MeetingLayout {
    static let transcriptCharacterLimit = 20_000
}

enum MeetingRecognition {
    static func languages(
        multilingual: Bool,
        pinned: AppLanguage,
        display: AppLanguage
    ) -> [AppLanguage] {
        guard multilingual else { return [pinned] }
        let peer = display.defaultPeer
        if peer == display {
            return [display]
        }
        return [display, peer]
    }
}

/// Why a storage operation could not complete.
enum TaskStoreFailureReason: String, Equatable, Sendable {
    /// The store is not open yet (or a previous open attempt failed).
    case unavailable
    /// Opening the underlying container failed.
    case openFailed
    /// Reading from the underlying store failed.
    case readFailed
    /// Persisting a change failed.
    case saveFailed
    /// The addressed task does not exist.
    case notFound
}

enum TaskStoreAvailability: Equatable, Sendable {
    case opening
    case ready
    case unavailable(TaskStoreFailureReason)

    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

/// A read that distinguishes "empty" from "storage unavailable".
enum TaskStoreReadResult<Value: Sendable>: Sendable {
    case value(Value)
    case unavailable(TaskStoreFailureReason)
}

extension TaskStoreReadResult: Equatable where Value: Equatable {}

enum TaskStoreWriteOutcome: Equatable, Sendable {
    case persisted
    case notPersisted(TaskStoreFailureReason)
}

/// A write that also returns the created/updated value.
enum TaskStoreWriteResult<Value: Sendable>: Sendable {
    case persisted(Value)
    case notPersisted(TaskStoreFailureReason)
}

extension TaskStoreWriteResult: Equatable where Value: Equatable {}

/// The single verdict of `end`: history (`ended`), empty discard, or failure.
enum TaskStoreEndResult: Equatable, Sendable {
    case ended(TaskSession)
    case discardedEmpty
    case notPersisted(TaskStoreFailureReason)
}

/// Everything the adapters need to create a task. The localized title is
/// composed by the lifecycle/UI; adapters never choose the title language.
struct TaskDraft: Equatable, Sendable {
    var feature: FeatureID
    var sourceLanguage: AppLanguage
    var targetLanguage: AppLanguage?
    var multilingual: Bool
    var startedAt: Date
    var title: String
}

/// The storage seam's availability/lifecycle contract, shared by every
/// adapter. Reads and writes live on `TaskStoreV2` and always report their
/// outcome, so "empty" is never confused with "storage unavailable".
@MainActor
protocol TaskStore: AnyObject {
    /// Single observable availability shared by every consumer of the seam.
    var availability: TaskStoreAvailability { get }
    /// Resolves the deferred open at most once. Safe to call repeatedly.
    func prepare() async
    /// Retries a failed open. No-op when already ready.
    func retry() async
}

/// Result-carrying storage seam (Wave 1).
///
/// Reads distinguish a value from an unavailable store; writes report
/// `persisted` / `notPersisted`. `end` is atomic and returns ended, empty
/// discard, or failure. There are no success-only variants.
@MainActor
protocol TaskStoreV2: TaskStore {
    func readActiveTask(for feature: FeatureID) async -> TaskStoreReadResult<TaskSession?>
    func readUnfinishedTasks() async -> TaskStoreReadResult<[TaskSession]>
    func readList(filter: FeatureID?) async -> TaskStoreReadResult<[TaskSession]>
    func readTask(id: UUID) async -> TaskStoreReadResult<TaskSession?>

    func startNew(_ draft: TaskDraft) async -> TaskStoreWriteResult<TaskSession>
    func append(_ entries: [TranscriptEntry], to taskID: UUID) async -> TaskStoreWriteOutcome
    func updateTranslations(_ entries: [TranscriptEntry], for taskID: UUID) async -> TaskStoreWriteOutcome
    func setStatus(_ status: TaskStatus, for taskID: UUID) async -> TaskStoreWriteOutcome
    func saveSummary(_ summary: ConversationSummary, for taskID: UUID) async -> TaskStoreWriteOutcome
    /// Atomic end: appends `entries`, then decides from the store's persisted
    /// transcript whether to end into history or discard an empty task. On
    /// `notPersisted` the task stays running and is not deleted.
    func end(
        taskID: UUID,
        entries: [TranscriptEntry],
        summary: ConversationSummary?
    ) async -> TaskStoreEndResult
    func deleteTask(id: UUID) async -> TaskStoreWriteOutcome
}

protocol ExportSharing: Sendable {
    func makeTranscriptFile(task: TaskSession, language: AppLanguage) throws -> URL
}
