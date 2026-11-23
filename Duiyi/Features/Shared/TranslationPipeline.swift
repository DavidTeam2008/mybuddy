import Foundation

/// How an incoming translation result compares with the last result applied
/// for the same canonical utterance.
enum StalePolicy: Sendable, Equatable {
    /// Face-to-face: a shorter result is dropped only while it is non-final,
    /// so a settled line can still correct a longer volatile one.
    case dropShorterNonFinal
    /// Interpretation: any shorter result is dropped, including a final one.
    case dropShorterAny
}

/// One caption line handed to the pipeline. The feature computes the target
/// language and the two debounce delays at submission time.
struct TranslationSubmission: Equatable, Sendable {
    var line: CaptionLine
    var isFinal: Bool
    var target: AppLanguage
    var firstDelay: Duration
    var delay: Duration
}

/// An accepted translation result. `utteranceID` is resolved through the
/// pipeline's alias table and is the ID the feature should write to.
struct TranslationUpdate: Equatable, Sendable {
    let job: TranslationJob
    let utteranceID: UUID
    let text: String
}

/// Debounce scheduling seam. Production waits with `Task.sleep`; tests drive a
/// manual scheduler so cancellation and replacement are deterministic.
@MainActor
protocol TranslationScheduler {
    @discardableResult
    func schedule(
        after delay: Duration,
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> any TranslationScheduledTask
}

@MainActor
protocol TranslationScheduledTask {
    func cancel()
}

/// Production scheduler: one cancellable `Task.sleep` per scheduled action.
@MainActor
final class TaskTranslationScheduler: TranslationScheduler {
    @MainActor
    private final class Handle: TranslationScheduledTask {
        private let task: Task<Void, Never>

        init(task: Task<Void, Never>) {
            self.task = task
        }

        func cancel() {
            task.cancel()
        }
    }

    func schedule(
        after delay: Duration,
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> any TranslationScheduledTask {
        let task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
        return Handle(task: task)
    }
}

/// Shared translation job lifecycle for the two live translation modules.
///
/// It owns job formation, debounce cancellation, duplicate suppression, the
/// single outbound job slot, the stale-result table, and utterance aliases.
/// Features keep language routing, pane/transcript projection, and TTS.
@MainActor
@Observable
final class TranslationPipeline {
    let stalePolicy: StalePolicy
    private let scheduler: any TranslationScheduler
    private(set) var outboundJob: TranslationJob?
    private var scheduled: (any TranslationScheduledTask)?
    private var sentSourceText: [UUID: String] = [:]
    private var lastAppliedSourceCount: [UUID: Int] = [:]
    private var utteranceAliases: [UUID: UUID] = [:]

    init(stalePolicy: StalePolicy) {
        self.stalePolicy = stalePolicy
        self.scheduler = TaskTranslationScheduler()
    }

    init(stalePolicy: StalePolicy, scheduler: any TranslationScheduler) {
        self.stalePolicy = stalePolicy
        self.scheduler = scheduler
    }

    func submit(_ submission: TranslationSubmission) {
        let text = submission.line.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if sentSourceText[submission.line.id] == text, !submission.isFinal {
            return
        }

        let job = TranslationJob(
            utteranceID: submission.line.id,
            source: submission.line.source,
            target: submission.target,
            text: text,
            isFinal: submission.isFinal
        )
        let isFirst = sentSourceText[submission.line.id] == nil
        let shouldSendNow = submission.isFinal
            || TranslationTrigger.shouldSendNow(
                text: text,
                isFirst: isFirst,
                language: submission.line.source
            )

        scheduled?.cancel()
        scheduled = nil
        if shouldSendNow {
            sentSourceText[submission.line.id] = text
            outboundJob = job
            return
        }

        let delay = isFirst ? submission.firstDelay : submission.delay
        let lineID = submission.line.id
        scheduled = scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            self.scheduled = nil
            self.sentSourceText[lineID] = text
            self.outboundJob = job
        }
    }

    /// Resolves the job's utterance through the alias table and applies the
    /// stale policy. Empty or stale text returns `nil` without touching the
    /// outbound slot; an accepted result clears the slot only when it belongs
    /// to the matching job.
    func accept(job: TranslationJob, text: String) -> TranslationUpdate? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let utteranceID = canonicalID(job.utteranceID)
        if let applied = lastAppliedSourceCount[utteranceID] {
            let isStale: Bool
            switch stalePolicy {
            case .dropShorterNonFinal:
                isStale = !job.isFinal && applied > job.text.count
            case .dropShorterAny:
                isStale = applied > job.text.count
            }
            if isStale {
                return nil
            }
        }
        lastAppliedSourceCount[utteranceID] = max(
            lastAppliedSourceCount[utteranceID] ?? 0,
            job.text.count
        )
        if outboundJob?.id == job.id {
            outboundJob = nil
        }
        return TranslationUpdate(job: job, utteranceID: utteranceID, text: trimmed)
    }

    /// A failed job only clears the outbound slot when it is still the current
    /// job, so a late failure cannot drop a newer job.
    func fail(job: TranslationJob) {
        if outboundJob?.id == job.id {
            outboundJob = nil
        }
    }

    /// Full translation reset for a new task, an ended task, or a language or
    /// direction change.
    func reset() {
        scheduled?.cancel()
        scheduled = nil
        outboundJob = nil
        sentSourceText.removeAll()
        lastAppliedSourceCount.removeAll()
        utteranceAliases.removeAll()
    }

    /// Registers a transcript line alias (for example a continuation packet)
    /// so later results land on the canonical caption ID.
    func registerAlias(_ alias: UUID, to canonical: UUID) {
        utteranceAliases[alias] = canonical
    }

    private func canonicalID(_ id: UUID) -> UUID {
        utteranceAliases[id] ?? id
    }
}
