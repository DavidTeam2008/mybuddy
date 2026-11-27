import Foundation

/// Default diagnostics sink for tests and previews. Production injects the
/// shared `DiagnosticsRecorder` from `AppEnvironment`.
final class NoOpDiagnosticsRecorder: DiagnosticsRecording, @unchecked Sendable {
    var hasSession: Bool { false }

    func beginSession(feature: FeatureID, taskID: UUID?) {}
    func endSession(taskID: UUID?) {}
    func record(_ record: ASRDiagnosticsRecord) {}
    func record(_ record: SpeechFailureRecord) {}
    func recordSubmit(_ record: TranslationSubmitRecord) {}
    func recordApply(_ record: TranslationApplyRecord) {}
    func recordResponse(_ record: TranslationResponseRecord) {}
    func recordFailure(_ record: TranslationFailureRecord) {}

    func snapshot() -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            schemaVersion: DiagnosticsRecorder.schemaVersion,
            session: nil,
            summary: DiagnosticsSummary(),
            events: []
        )
    }

    func makeExportJSON() -> Data? { nil }
    func makeExportFile() -> URL? { nil }
}
