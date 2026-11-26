import Foundation

/// A translation result that failed the text-integrity check twice.
enum TranslationIntegrityError: Error, Equatable {
    case corruptedOutput
}

/// What the pump needs from one translation attempt: the text plus the
/// framework's reported language pair (diagnostics only, P1-4a).
struct TranslationPumpResult: Equatable, Sendable {
    var text: String
    var responseSourceLanguage: String?
    var responseTargetLanguage: String?

    init(
        text: String,
        responseSourceLanguage: String? = nil,
        responseTargetLanguage: String? = nil
    ) {
        self.text = text
        self.responseSourceLanguage = responseSourceLanguage
        self.responseTargetLanguage = responseTargetLanguage
    }
}

/// Shared translation-job pump used by both translation hosts.
///
/// Each wakeup drains the bridge consumer until it has no jobs left, so a
/// coalesced queue never builds up one translation per submit. The `translate`
/// closure is injected so the loop can be exercised without a live
/// `TranslationSession`; production passes a thin adapter over
/// `TranslationSession.translate`.
struct TranslationJobPump {
    let translate: (String) async throws -> TranslationPumpResult
    let onSuccess: @MainActor (TranslationJob, String) -> Void
    let onFailure: @MainActor (TranslationJob, Error) -> Void
    private let diagnostics: any DiagnosticsRecording

    /// String-only seam kept for existing call sites and tests.
    init(
        translate: @escaping (String) async throws -> String,
        onSuccess: @escaping @MainActor (TranslationJob, String) -> Void,
        onFailure: @escaping @MainActor (TranslationJob, Error) -> Void,
        diagnostics: any DiagnosticsRecording = NoOpDiagnosticsRecorder()
    ) {
        self.init(
            translateResponse: { text in
                TranslationPumpResult(text: try await translate(text))
            },
            onSuccess: onSuccess,
            onFailure: onFailure,
            diagnostics: diagnostics
        )
    }

    /// Production seam: the host returns the framework response's language pair
    /// so the diagnostics payload can prove which languages the response used.
    init(
        translateResponse: @escaping (String) async throws -> TranslationPumpResult,
        onSuccess: @escaping @MainActor (TranslationJob, String) -> Void,
        onFailure: @escaping @MainActor (TranslationJob, Error) -> Void,
        diagnostics: any DiagnosticsRecording = NoOpDiagnosticsRecorder()
    ) {
        self.translate = translateResponse
        self.onSuccess = onSuccess
        self.onFailure = onFailure
        self.diagnostics = diagnostics
    }

    func run(_ consumer: TranslationJobBridge.Consumer) async {
        for await _ in consumer.wakeups {
            while let job = consumer.takeNext() {
                if Task.isCancelled {
                    consumer.requeue(job)
                    return
                }
                // Empty-text filtering lives in the bridge, the only
                // production producer; trimming here only normalizes the
                // text handed to the session.
                let text = job.text.trimmingCharacters(in: .whitespacesAndNewlines)
                do {
                    let first = try await translate(text)
                    let result: TranslationPumpResult
                    let retryCount: Int
                    if TextIntegrity.isCorrupted(first.text) {
                        // A corrupted framework result is retried once with the
                        // same source before it is treated as a failure. A
                        // cancelled pump must requeue instead of reporting a
                        // permanent failure.
                        if Task.isCancelled {
                            consumer.requeue(job)
                            return
                        }
                        #if DEBUG
                        logIntegrity("retry", job: job, source: text, translated: first.text)
                        #endif
                        let retry = try await translate(text)
                        if Task.isCancelled {
                            consumer.requeue(job)
                            return
                        }
                        guard !TextIntegrity.isCorrupted(retry.text) else {
                            #if DEBUG
                            logIntegrity("rejected", job: job, source: text, translated: retry.text)
                            #endif
                            recordFailure(job: job, failure: "corruptedOutput", retryCount: 1)
                            await onFailure(job, TranslationIntegrityError.corruptedOutput)
                            continue
                        }
                        result = retry
                        retryCount = 1
                    } else {
                        result = first
                        retryCount = 0
                    }
                    recordResponse(job: job, result: result, retryCount: retryCount)
                    await onSuccess(job, result.text)
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        // A CancellationError that arrives without task
                        // cancellation still ends this pump. The bridge keeps
                        // the job when it is still the latest submission, and
                        // the host's next `.translationTask` restart installs
                        // a new consumer whose pump drains it.
                        consumer.requeue(job)
                        return
                    }
                    recordFailure(job: job, failure: Self.failureName(error), retryCount: 0)
                    await onFailure(job, error)
                }
            }
        }
    }

    private func recordResponse(
        job: TranslationJob,
        result: TranslationPumpResult,
        retryCount: Int
    ) {
        diagnostics.recordResponse(
            TranslationResponseRecord(
                jobID: job.id,
                utteranceID: job.utteranceID,
                sequence: job.sequence,
                isFinal: job.isFinal,
                translatedLength: result.text.count,
                replacementCharacterCount: TextIntegrity.replacementCharacterCount(result.text),
                responseSourceLanguage: result.responseSourceLanguage,
                responseTargetLanguage: result.responseTargetLanguage,
                retryCount: retryCount
            )
        )
    }

    private func recordFailure(job: TranslationJob, failure: String, retryCount: Int) {
        diagnostics.recordFailure(
            TranslationFailureRecord(
                jobID: job.id,
                utteranceID: job.utteranceID,
                sequence: job.sequence,
                isFinal: job.isFinal,
                failure: failure,
                retryCount: retryCount
            )
        )
    }

    private static func failureName(_ error: Error) -> String {
        if let integrity = error as? TranslationIntegrityError {
            switch integrity {
            case .corruptedOutput: return "corruptedOutput"
            }
        }
        let nsError = error as NSError
        return "\(nsError.domain):\(nsError.code)"
    }

    #if DEBUG
    private func logIntegrity(
        _ outcome: String,
        job: TranslationJob,
        source: String,
        translated: String
    ) {
        DuiyiLog.translation.debug(
            "translation integrity \(outcome, privacy: .public) job=\(job.id.uuidString, privacy: .public) utterance=\(job.utteranceID.uuidString, privacy: .public) sourceLen=\(source.count, privacy: .public) translatedLen=\(translated.count, privacy: .public) fffd=\(TextIntegrity.replacementCharacterCount(translated), privacy: .public)"
        )
    }
    #endif
}
