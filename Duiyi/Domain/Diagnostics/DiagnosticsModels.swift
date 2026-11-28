import Foundation

/// Pure diagnostics records for the DEVICE-ONLY quality fixture (P1-4).
///
/// The payloads carry identifiers, durations, and lengths — never caption text,
/// audio, or user identifiers — so a DEBUG export can be pulled off the device
/// and compared against a known fixture without leaking transcript content.
struct ASRDiagnosticsRecord: Equatable, Sendable {
    var language: AppLanguage
    var textLength: Int
    var isFinal: Bool
    /// A final synthesized by the silence timer instead of the transcriber.
    var synthetic: Bool
    /// The result's script does not strictly match the transcriber locale.
    var scriptMismatch: Bool
    /// The assembler accepted the result into a row.
    var accepted: Bool
    /// The engine's duplicate-final filter let the update through.
    var published: Bool
    var utteranceID: UUID?
    /// A final/revision for an utterance that was already published.
    var revision: Bool
    var rangeStartSeconds: Double?
    var rangeDurationSeconds: Double?
    var resultsFinalizationTimeSeconds: Double?
    var style: String
    /// Character-weighted confidence aggregates. Kept as primitives so Domain
    /// does not import Speech; nil when the framework omitted the attribute.
    var confidenceRunCount: Int? = nil
    var confidenceMinimum: Double? = nil
    var confidenceMean: Double? = nil
    var confidenceBuckets: [Int]? = nil
}

struct TranslationSubmitRecord: Equatable, Sendable {
    var jobID: UUID
    var utteranceID: UUID
    var sequence: Int
    var isFinal: Bool
    var source: AppLanguage
    var target: AppLanguage
    var sourceLength: Int
    var strategy: String
    var sourceHash: String? = nil
}

struct TranslationApplyRecord: Equatable, Sendable {
    var jobID: UUID
    var utteranceID: UUID
    var sequence: Int
    var isFinal: Bool
    var applied: Bool
    /// Why a result was not applied: `staleSequence`, `duplicate`, `empty`,
    /// or `shorterPreview`.
    var reason: String?
    var translatedLength: Int
    var replacementCharacterCount: Int
}

struct TranslationResponseRecord: Equatable, Sendable {
    var jobID: UUID
    var utteranceID: UUID
    var sequence: Int
    var isFinal: Bool
    var translatedLength: Int
    var replacementCharacterCount: Int
    var responseSourceLanguage: String?
    var responseTargetLanguage: String?
    /// 0 = first attempt accepted, 1 = the pump retried after a corrupted result.
    var retryCount: Int
}

struct TranslationFailureRecord: Equatable, Sendable {
    var jobID: UUID
    var utteranceID: UUID
    var sequence: Int
    var isFinal: Bool
    /// `corruptedOutput`, the error's domain/code, or its type name.
    var failure: String
    var retryCount: Int
}

/// What the speech engine did after a transcriber consumer threw.
enum SpeechFailureRecovery: String, Equatable, Sendable {
    /// A dual-locale session restarted the failed transcriber's language as
    /// the only transcriber.
    case singleFallback
    /// No new recovery was attempted: the session was already single-locale
    /// or stopping, so the stream ended, or another failure already scheduled
    /// the fallback that owns the outcome.
    case none
    /// The single-locale fallback was attempted but its pipeline failed to
    /// start, so the stream ended.
    case restartFailed
}

/// A speech-pipeline failure. It carries only the failed language, the
/// error's domain/code, and the recovery decision — never the error message,
/// caption text, audio, or a device identifier.
struct SpeechFailureRecord: Equatable, Sendable {
    var language: AppLanguage
    /// The `NSError` domain, for example `kAFAssistantErrorDomain`.
    var errorDomain: String
    /// The `NSError` code.
    var errorCode: Int
    var recovery: SpeechFailureRecovery
    var style: String
}

/// One JSON event. Fields are optional by kind; synthesized `Codable` omits
/// them when nil.
struct DiagnosticsEvent: Codable, Equatable, Sendable {
    var kind: String
    var at: Date
    var feature: String?
    var utteranceID: String?
    var jobID: String?
    var sequence: Int?
    var language: String?
    var isFinal: Bool?
    var textLength: Int?
    var synthetic: Bool?
    var scriptMismatch: Bool?
    var accepted: Bool?
    var published: Bool?
    var revision: Bool?
    var rangeStart: Double?
    var rangeDuration: Double?
    var resultsFinalizationTime: Double?
    var confidenceRunCount: Int?
    var confidenceMinimum: Double?
    var confidenceMean: Double?
    var confidenceBuckets: [Int]?
    var style: String?
    var sourceLanguage: String?
    var targetLanguage: String?
    var sourceLength: Int?
    var sourceHash: String?
    var translatedLength: Int?
    var replacementCharacters: Int?
    var responseSourceLanguage: String?
    var responseTargetLanguage: String?
    var latencyMilliseconds: Double?
    var retryCount: Int?
    var failure: String?
    var reason: String?
    var errorDomain: String?
    var errorCode: Int?
    var recovery: String?
}

/// Aggregate counters for one task. They are maintained incrementally so a
/// ring-buffer eviction never rewrites history.
struct DiagnosticsSummary: Codable, Equatable, Sendable {
    var asrResultCount = 0
    /// Distinct utterances that reached a finalized row (synthetic or real).
    var settledUtterances = 0
    var translationSubmitCount = 0
    var finalJobCount = 0
    var translationResponseCount = 0
    var finalAppliedCount = 0
    var permanentFailureCount = 0
    var rejectedCorruptionCount = 0
    var droppedEventCount = 0
}

struct DiagnosticsSessionInfo: Codable, Equatable, Sendable {
    var feature: String
    var taskID: String?
    var startedAt: Date
    var endedAt: Date?
}

struct DiagnosticsSnapshot: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var session: DiagnosticsSessionInfo?
    var summary: DiagnosticsSummary
    var events: [DiagnosticsEvent]
}
