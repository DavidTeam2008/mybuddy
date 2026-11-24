import Foundation

/// Shared translation-job pump used by both translation hosts.
///
/// The `translate` closure is injected so the loop can be exercised without a
/// live `TranslationSession`; production passes a thin adapter over
/// `TranslationSession.translate`.
struct TranslationJobPump {
    let translate: (String) async throws -> String
    let onSuccess: @MainActor (TranslationJob, String) -> Void
    let onFailure: @MainActor (TranslationJob, Error) -> Void

    func run(_ jobs: AsyncStream<TranslationJob>) async {
        for await job in jobs {
            let text = job.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            do {
                let translatedText = try await translate(text)
                await onSuccess(job, translatedText)
            } catch {
                await onFailure(job, error)
            }
        }
    }
}
