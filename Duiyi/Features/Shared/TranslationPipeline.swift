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
/// It owns job formation, per-utterance debounce, duplicate suppression, the
/// ordered outbound queue, and the stale-result tables.
/// Features keep language routing, pane/transcript projection, and TTS.
@MainActor
@Observable
final class TranslationPipeline {
    private let scheduler: any TranslationScheduler
    private var outboundQueue: [TranslationJob] = []
    /// Bumps whenever a job is handed to the outbound queue. Hosts observe it
    /// and drain `takeNextOutboundJob()`; a plain "latest job" value would let
    /// SwiftUI coalesce two jobs into one render and lose the first.
    private(set) var outboundRevision = 0
    /// The newest job that has not been drained yet. Tests read it as the
    /// current slot; live hosts drain the queue instead.
    var outboundJob: TranslationJob? { outboundQueue.last }
    /// One debounce per utterance: a new line must not cancel another line's
    /// pending preview, and a final cancels only its own line's preview.
    private var scheduled: [UUID: any TranslationScheduledTask] = [:]
    private var sentSourceText: [UUID: String] = [:]
    private var lastAppliedSourceCount: [UUID: Int] = [:]
    private var lastAppliedSequence: [UUID: Int] = [:]
    private var appliedJobIDs: Set<UUID> = []
    private var appliedJobIDOrder: [UUID] = []
    private var nextSequence = 0

    /// Preview backlog cap. Finals are never evicted; the queue can only grow
    /// past this while it holds nothing but finals, which the host drains.
    static let outboundQueueLimit = 64
    static let appliedJobIDLimit = 256

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

        nextSequence += 1
        let job = TranslationJob(
            utteranceID: submission.line.id,
            source: submission.line.source,
            target: submission.target,
            text: text,
            isFinal: submission.isFinal,
            sequence: nextSequence
        )
        let lineID = submission.line.id
        let isFirst = sentSourceText[lineID] == nil
        let action: TranslationTrigger.Action = submission.isFinal
            ? .sendNow
            : TranslationTrigger.action(for: text, language: submission.line.source)

        scheduled[lineID]?.cancel()
        scheduled[lineID] = nil
        switch action {
        case .drop:
            // A too-short preview never forms a job; the next volatile or the
            // final will carry the line.
            return
        case .sendNow:
            commit(job, text: text, lineID: lineID)
        case .debounce:
            let delay = isFirst ? submission.firstDelay : submission.subsequentDelay
            scheduled[lineID] = scheduler.schedule(after: delay) { [weak self] in
                guard let self else { return }
                self.scheduled[lineID] = nil
                self.commit(job, text: text, lineID: lineID)
            }
        }
    }

    private func commit(_ job: TranslationJob, text: String, lineID: UUID) {
        sentSourceText[lineID] = text
        enqueue(job)
    }

    /// Hands the oldest queued job to the host and removes it from the queue.
    /// Jobs are dequeued in enqueue order; a newer job for the same utterance
    /// replaces the older one in place.
    func takeNextOutboundJob() -> TranslationJob? {
        guard !outboundQueue.isEmpty else { return nil }
        return outboundQueue.removeFirst()
    }

    private func enqueue(_ job: TranslationJob) {
        if let index = outboundQueue.firstIndex(where: { $0.utteranceID == job.utteranceID }) {
            let queued = outboundQueue[index]
            // A final already waiting for the host is never cancelled by a
            // preview that fired late; a newer final still replaces it.
            guard !queued.isFinal || job.isFinal else { return }
            outboundQueue[index] = job
        } else {
            outboundQueue.append(job)
        }
        trimPreviewBacklog()
        outboundRevision += 1
    }

    private func trimPreviewBacklog() {
        while outboundQueue.count > Self.outboundQueueLimit,
              let index = outboundQueue.firstIndex(where: { !$0.isFinal }) {
            outboundQueue.remove(at: index)
        }
    }

    private func removeQueuedJob(id: UUID) {
        outboundQueue.removeAll { $0.id == id }
    }

    /// Applies the result to the job's utterance. Empty, duplicated, or stale
    /// results return `nil`; a final is always applied, even when its source is
    /// shorter than an earlier preview. Staleness is by monotonic sequence for
    /// pipeline jobs (a result must be newer than the last applied one) and by
    /// source length for previews, so a late result can neither overwrite a
    /// newer job nor be replayed twice.
    func accept(job: TranslationJob, text: String) -> TranslationUpdate? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !appliedJobIDs.contains(job.id) else { return nil }

        let utteranceID = job.utteranceID
        if job.sequence > 0,
           let appliedSequence = lastAppliedSequence[utteranceID],
           job.sequence <= appliedSequence {
            return nil
        }
        if let applied = lastAppliedSourceCount[utteranceID],
           !job.isFinal,
           applied > job.text.count {
            return nil
        }
        lastAppliedSourceCount[utteranceID] = max(
            lastAppliedSourceCount[utteranceID] ?? 0,
            job.text.count
        )
        if job.sequence > 0 {
            lastAppliedSequence[utteranceID] = max(
                lastAppliedSequence[utteranceID] ?? 0,
                job.sequence
            )
        }
        rememberApplied(job.id)
        removeQueuedJob(id: job.id)
        return TranslationUpdate(job: job, utteranceID: utteranceID, translatedText: trimmed)
    }

    private func rememberApplied(_ id: UUID) {
        appliedJobIDs.insert(id)
        appliedJobIDOrder.append(id)
        if appliedJobIDOrder.count > Self.appliedJobIDLimit {
            appliedJobIDs.remove(appliedJobIDOrder.removeFirst())
        }
    }

    /// A failed job is removed from the queue only if it has not been drained
    /// yet; a late failure cannot drop a newer job.
    func fail(job: TranslationJob) {
        removeQueuedJob(id: job.id)
    }

    /// Full translation reset for a new task, an ended task, or a language or
    /// direction change.
    func reset() {
        for task in scheduled.values {
            task.cancel()
        }
        scheduled.removeAll()
        outboundQueue.removeAll()
        sentSourceText.removeAll()
        lastAppliedSourceCount.removeAll()
        lastAppliedSequence.removeAll()
        appliedJobIDs.removeAll()
        appliedJobIDOrder.removeAll()
    }
}
