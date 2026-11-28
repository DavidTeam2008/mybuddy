import Foundation

/// Diagnostics sink shared by the speech engine, translation pipeline, and
/// translation pump. Implementations must be thread-safe: ASR events arrive
/// from the speech actor while translation events arrive on the main actor.
protocol DiagnosticsRecording: AnyObject, Sendable {
    /// True once a task session exists; cheap enough to read from a view body.
    var hasSession: Bool { get }

    func beginSession(feature: FeatureID, taskID: UUID?)
    func endSession(taskID: UUID?)
    func record(_ record: ASRDiagnosticsRecord)
    func record(_ record: ASRDropRecord)
    func record(_ record: SpeechPreemptionRecord)
    func record(_ record: SpeechStartRecord)
    func record(_ record: SpeechFailureRecord)
    func recordSubmit(_ record: TranslationSubmitRecord)
    func recordApply(_ record: TranslationApplyRecord)
    func recordResponse(_ record: TranslationResponseRecord)
    func recordFailure(_ record: TranslationFailureRecord)
    func snapshot() -> DiagnosticsSnapshot
    /// JSON for the DEBUG export, or nil when the build or session has nothing
    /// to export. Never uploads anything.
    func makeExportJSON() -> Data?
    /// Writes the export JSON to the app's Documents directory and returns the
    /// file URL so the device can pull it with `devicectl` or share it.
    func makeExportFile() -> URL?
}
