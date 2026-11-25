import Foundation

/// One caption line handed to the pipeline. The feature computes the target
/// language and the two debounce delays at submission time.
struct TranslationSubmission: Equatable, Sendable {
    var line: CaptionLine
    var isFinal: Bool
    var target: AppLanguage
    var firstDelay: Duration
    var subsequentDelay: Duration
}

/// An accepted translation result. `utteranceID` is the job's id and is the
/// identity the feature should write to.
struct TranslationUpdate: Equatable, Sendable {
    let job: TranslationJob
    let utteranceID: UUID
    let translatedText: String
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
    private let scheduler: any TranslationScheduler
    private(set) var outboundJob: TranslationJob?
    private var scheduled: (any TranslationScheduledTask)?
    private var sentSourceText: [UUID: String] = [:]
    private var lastAppliedSourceCount: [UUID: Int] = [:]

    init() {
        self.scheduler = TaskTranslationScheduler()
    }

    init(scheduler: any TranslationScheduler) {
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

        let delay = isFirst ? submission.firstDelay : submission.subsequentDelay
        let lineID = submission.line.id
        scheduled = scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            self.scheduled = nil
            self.sentSourceText[lineID] = text
            self.outboundJob = job
        }
    }

    /// Applies the result to the job's utterance. Empty or stale preview text
    /// returns `nil` without touching the outbound slot; a final is always
    /// applied, even when its source is shorter than an earlier preview. An
    /// accepted result clears the slot only when it belongs to the matching
    /// job.
    func accept(job: TranslationJob, text: String) -> TranslationUpdate? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let utteranceID = job.utteranceID
        if let applied = lastAppliedSourceCount[utteranceID],
           !job.isFinal,
           applied > job.text.count {
            return nil
        }
        lastAppliedSourceCount[utteranceID] = max(
            lastAppliedSourceCount[utteranceID] ?? 0,
            job.text.count
        )
        if outboundJob?.id == job.id {
            outboundJob = nil
        }
        return TranslationUpdate(job: job, utteranceID: utteranceID, translatedText: trimmed)
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
    }
}
