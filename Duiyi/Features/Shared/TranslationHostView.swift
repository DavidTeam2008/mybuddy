@preconcurrency import Translation
import SwiftUI

struct TranslationHostView: View {
    let userLanguage: AppLanguage
    let peerLanguage: AppLanguage
    private let latestJob: TranslationJob?
    private let outboundRevision: Int
    private let takeNextOutboundJob: (@MainActor () -> TranslationJob?)?
    let onSuccess: @MainActor (TranslationJob, String) -> Void
    let onFailure: @MainActor (TranslationJob, Error) -> Void

    @State private var userToPeer: TranslationSession.Configuration
    @State private var peerToUser: TranslationSession.Configuration
    @State private var userJobs = TranslationJobBridge()
    @State private var peerJobs = TranslationJobBridge()

    /// Sequential host: the caller advances one job at a time and rebuilds the
    /// host per job (history detail).
    init(
        userLanguage: AppLanguage,
        peerLanguage: AppLanguage,
        job: TranslationJob?,
        onSuccess: @escaping @MainActor (TranslationJob, String) -> Void,
        onFailure: @escaping @MainActor (TranslationJob, Error) -> Void
    ) {
        self.userLanguage = userLanguage
        self.peerLanguage = peerLanguage
        self.latestJob = job
        self.outboundRevision = 0
        self.takeNextOutboundJob = nil
        self.onSuccess = onSuccess
        self.onFailure = onFailure
        _userToPeer = State(initialValue: translationConfiguration(from: userLanguage, to: peerLanguage))
        _peerToUser = State(initialValue: translationConfiguration(from: peerLanguage, to: userLanguage))
    }

    /// Live host: drains every queued job on each revision bump. Observing a
    /// single "latest job" would let SwiftUI coalesce two finals produced
    /// between renders and silently drop the first.
    init(
        userLanguage: AppLanguage,
        peerLanguage: AppLanguage,
        outboundRevision: Int,
        takeNextOutboundJob: @escaping @MainActor () -> TranslationJob?,
        onSuccess: @escaping @MainActor (TranslationJob, String) -> Void,
        onFailure: @escaping @MainActor (TranslationJob, Error) -> Void
    ) {
        self.userLanguage = userLanguage
        self.peerLanguage = peerLanguage
        self.latestJob = nil
        self.outboundRevision = outboundRevision
        self.takeNextOutboundJob = takeNextOutboundJob
        self.onSuccess = onSuccess
        self.onFailure = onFailure
        _userToPeer = State(initialValue: translationConfiguration(from: userLanguage, to: peerLanguage))
        _peerToUser = State(initialValue: translationConfiguration(from: peerLanguage, to: userLanguage))
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .translationTask(userToPeer) { session in
                await TranslationJobPump(session: session, onSuccess: onSuccess, onFailure: onFailure)
                    .run(userJobs.makeConsumer())
            }
            .translationTask(peerToUser) { session in
                await TranslationJobPump(session: session, onSuccess: onSuccess, onFailure: onFailure)
                    .run(peerJobs.makeConsumer())
            }
            .onChange(of: latestJob) { _, newJob in
                submit(newJob)
            }
            .onChange(of: outboundRevision) { _, _ in
                drainQueuedJobs()
            }
            .onAppear {
                submit(latestJob)
                drainQueuedJobs()
            }
    }

    private func submit(_ job: TranslationJob?) {
        guard let job else { return }
        if job.source == userLanguage {
            userJobs.submit(job)
        } else if job.source == peerLanguage {
            peerJobs.submit(job)
        }
    }

    private func drainQueuedJobs() {
        guard let takeNextOutboundJob else { return }
        while let job = takeNextOutboundJob() {
            submit(job)
        }
    }
}

struct OneWayTranslationHostView: View {
    let sourceLanguage: AppLanguage
    let targetLanguage: AppLanguage
    private let latestJob: TranslationJob?
    private let outboundRevision: Int
    private let takeNextOutboundJob: (@MainActor () -> TranslationJob?)?
    let onSuccess: @MainActor (TranslationJob, String) -> Void
    let onFailure: @MainActor (TranslationJob, Error) -> Void

    @State private var configuration: TranslationSession.Configuration
    @State private var jobs = TranslationJobBridge()

    /// Sequential host: the caller advances one job at a time and rebuilds the
    /// host per job (history detail).
    init(
        sourceLanguage: AppLanguage,
        targetLanguage: AppLanguage,
        job: TranslationJob?,
        onSuccess: @escaping @MainActor (TranslationJob, String) -> Void,
        onFailure: @escaping @MainActor (TranslationJob, Error) -> Void
    ) {
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.latestJob = job
        self.outboundRevision = 0
        self.takeNextOutboundJob = nil
        self.onSuccess = onSuccess
        self.onFailure = onFailure
        _configuration = State(initialValue: translationConfiguration(from: sourceLanguage, to: targetLanguage))
    }

    /// Live host: drains every queued job on each revision bump. Observing a
    /// single "latest job" would let SwiftUI coalesce two finals produced
    /// between renders and silently drop the first.
    init(
        sourceLanguage: AppLanguage,
        targetLanguage: AppLanguage,
        outboundRevision: Int,
        takeNextOutboundJob: @escaping @MainActor () -> TranslationJob?,
        onSuccess: @escaping @MainActor (TranslationJob, String) -> Void,
        onFailure: @escaping @MainActor (TranslationJob, Error) -> Void
    ) {
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.latestJob = nil
        self.outboundRevision = outboundRevision
        self.takeNextOutboundJob = takeNextOutboundJob
        self.onSuccess = onSuccess
        self.onFailure = onFailure
        _configuration = State(initialValue: translationConfiguration(from: sourceLanguage, to: targetLanguage))
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .translationTask(configuration) { session in
                await TranslationJobPump(session: session, onSuccess: onSuccess, onFailure: onFailure)
                    .run(jobs.makeConsumer())
            }
            .onChange(of: latestJob) { _, newJob in
                submit(newJob)
            }
            .onChange(of: outboundRevision) { _, _ in
                drainQueuedJobs()
            }
            .onAppear {
                submit(latestJob)
                drainQueuedJobs()
            }
    }

    private func submit(_ job: TranslationJob?) {
        guard let job else { return }
        guard job.source == sourceLanguage, job.target == targetLanguage else { return }
        jobs.submit(job)
    }

    private func drainQueuedJobs() {
        guard let takeNextOutboundJob else { return }
        while let job = takeNextOutboundJob() {
            submit(job)
        }
    }
}

private extension TranslationJobPump {
    init(
        session: TranslationSession,
        onSuccess: @escaping @MainActor (TranslationJob, String) -> Void,
        onFailure: @escaping @MainActor (TranslationJob, Error) -> Void
    ) {
        self.init(
            translate: { try await session.translate($0).targetText },
            onSuccess: onSuccess,
            onFailure: onFailure
        )
    }
}

/// Coalescing translation-job queue shared by both translation hosts.
///
/// Producers `submit` jobs; the queue keeps at most one pending job per
/// `utteranceID` while preserving that ID's first-appearance slot. Consumers
/// are generation-scoped for draining: only the newest `makeConsumer()` can
/// take jobs, and installing a replacement finishes the superseded stream
/// outside the lock. A superseded consumer can still requeue a job that
/// remains the latest submission for its utterance.
final class TranslationJobBridge: @unchecked Sendable {
    final class Consumer: @unchecked Sendable {
        let wakeups: AsyncStream<Void>
        private let takeNextJob: () -> TranslationJob?
        private let requeueJob: (TranslationJob) -> Void

        init(
            wakeups: AsyncStream<Void>,
            takeNext: @escaping () -> TranslationJob?,
            requeue: @escaping (TranslationJob) -> Void
        ) {
            self.wakeups = wakeups
            self.takeNextJob = takeNext
            self.requeueJob = requeue
        }

        func takeNext() -> TranslationJob? {
            takeNextJob()
        }

        /// Returns a job that was already taken but not translated. The job is
        /// discarded when a newer job for the same utterance was submitted or
        /// is still pending, so a cancelled pump never resurrects superseded
        /// text. A superseded consumer may still requeue the latest job; the
        /// bridge inserts it at the front and wakes the current consumer.
        func requeue(_ job: TranslationJob) {
            requeueJob(job)
        }
    }

    private let lock = NSLock()
    private var generation = 0
    private var continuation: AsyncStream<Void>.Continuation?
    private var queue: [TranslationJob] = []
    /// The newest job actually admitted for each utterance. Final precedence
    /// can reject a non-final update, in which case the queued final stays the
    /// latest job and may still be requeued after cancellation.
    private var latestJobIDByUtterance: [UUID: UUID] = [:]

    func submit(_ job: TranslationJob) {
        guard !job.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        lock.lock()
        if let index = queue.firstIndex(where: { $0.utteranceID == job.utteranceID }) {
            let queued = queue[index]
            if !queued.isFinal || job.isFinal {
                queue[index] = job
                latestJobIDByUtterance[job.utteranceID] = job.id
            }
        } else {
            queue.append(job)
            latestJobIDByUtterance[job.utteranceID] = job.id
        }
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(())
    }

    func makeConsumer() -> Consumer {
        let (wakeups, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        lock.lock()
        generation += 1
        let consumerGeneration = generation
        let previousContinuation = self.continuation
        self.continuation = continuation
        let hasPendingJobs = !queue.isEmpty
        lock.unlock()

        continuation.onTermination = { [weak self] _ in
            self?.clearContinuation(for: consumerGeneration)
        }
        previousContinuation?.finish()
        if hasPendingJobs {
            continuation.yield(())
        }

        return Consumer(
            wakeups: wakeups,
            takeNext: { [weak self] in
                self?.takeNext(for: consumerGeneration)
            },
            requeue: { [weak self] job in
                self?.requeue(job)
            }
        )
    }

    private func takeNext(for generation: Int) -> TranslationJob? {
        lock.lock()
        defer { lock.unlock() }
        guard generation == self.generation, !queue.isEmpty else { return nil }
        return queue.removeFirst()
    }

    private func requeue(_ job: TranslationJob) {
        lock.lock()
        guard latestJobIDByUtterance[job.utteranceID] == job.id else {
            lock.unlock()
            return
        }
        guard !queue.contains(where: { $0.utteranceID == job.utteranceID }) else {
            lock.unlock()
            return
        }
        queue.insert(job, at: 0)
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(())
    }

    private func clearContinuation(for generation: Int) {
        lock.lock()
        if generation == self.generation {
            continuation = nil
        }
        lock.unlock()
    }
}

struct TranslationPrepareHost: View {
    let userLanguage: AppLanguage
    let peerLanguage: AppLanguage
    let shouldPrepare: Bool
    var oneWay = false
    let onFinished: @MainActor (Result<Void, Error>) -> Void

    @State private var userToPeer: TranslationSession.Configuration
    @State private var peerToUser: TranslationSession.Configuration
    @State private var preparedPairs: Set<String> = []

    init(
        userLanguage: AppLanguage,
        peerLanguage: AppLanguage,
        shouldPrepare: Bool,
        oneWay: Bool = false,
        onFinished: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        self.userLanguage = userLanguage
        self.peerLanguage = peerLanguage
        self.shouldPrepare = shouldPrepare
        self.oneWay = oneWay
        self.onFinished = onFinished
        _userToPeer = State(initialValue: translationConfiguration(from: userLanguage, to: peerLanguage))
        _peerToUser = State(initialValue: translationConfiguration(from: peerLanguage, to: userLanguage))
    }

    var body: some View {
        prepareRoot
            .onChange(of: shouldPrepare) { _, prepare in
                guard prepare else { return }
                preparedPairs = []
                userToPeer.invalidate()
                if !oneWay {
                    peerToUser.invalidate()
                }
            }
    }

    @ViewBuilder
    private var prepareRoot: some View {
        if oneWay {
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .translationTask(userToPeer) { session in
                    await prepare(session, pair: "forward")
                }
        } else {
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .translationTask(userToPeer) { session in
                    await prepare(session, pair: "user-to-peer")
                }
                .translationTask(peerToUser) { session in
                    await prepare(session, pair: "peer-to-user")
                }
        }
    }

    private func prepare(_ session: TranslationSession, pair: String) async {
        guard shouldPrepare else { return }
        do {
            try await session.prepareTranslation()
            await markPrepared(pair)
        } catch {
            await onFinished(.failure(error))
        }
    }

    @MainActor
    private func markPrepared(_ pair: String) {
        preparedPairs.insert(pair)
        let required = oneWay ? 1 : 2
        if preparedPairs.count >= required {
            onFinished(.success(()))
        }
    }
}

private func translationConfiguration(from: AppLanguage, to: AppLanguage) -> TranslationSession.Configuration {
    TranslationSession.Configuration(
        source: from.localeLanguage,
        target: to.localeLanguage,
        preferredStrategy: .lowLatency
    )
}
