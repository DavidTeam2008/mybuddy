import Foundation

/// A translation result that failed the text-integrity check twice.
enum TranslationIntegrityError: Error, Equatable {
    case corruptedOutput
}

/// Shared translation-job pump used by both translation hosts.
///
/// Each wakeup drains the bridge consumer until it has no jobs left, so a
/// coalesced queue never builds up one translation per submit. The `translate`
/// closure is injected so the loop can be exercised without a live
/// `TranslationSession`; production passes a thin adapter over
/// `TranslationSession.translate`.
struct TranslationJobPump {
    let translate: (String) async throws -> String
    let onSuccess: @MainActor (TranslationJob, String) -> Void
    let onFailure: @MainActor (TranslationJob, Error) -> Void

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
                    let translatedText: String
                    if TextIntegrity.isCorrupted(first) {
                        // A corrupted framework result is retried once with the
                        // same source before it is treated as a failure. A
                        // cancelled pump must requeue instead of reporting a
                        // permanent failure.
                        if Task.isCancelled {
                            consumer.requeue(job)
                            return
                        }
                        #if DEBUG
                        logIntegrity("retry", job: job, source: text, translated: first)
                        #endif
                        let retry = try await translate(text)
                        if Task.isCancelled {
                            consumer.requeue(job)
                            return
                        }
                        guard !TextIntegrity.isCorrupted(retry) else {
                            #if DEBUG
                            logIntegrity("rejected", job: job, source: text, translated: retry)
                            #endif
                            await onFailure(job, TranslationIntegrityError.corruptedOutput)
                            continue
                        }
                        translatedText = retry
                    } else {
                        translatedText = first
                    }
                    await onSuccess(job, translatedText)
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
                    await onFailure(job, error)
                }
            }
        }
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
