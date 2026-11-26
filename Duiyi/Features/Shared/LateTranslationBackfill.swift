import Foundation

/// Routes final translation results that can no longer reach the live
/// projection into the finished task's transcript.
///
/// Post-reset results are drained through `TaskLifecycle.backfillTranslation`
/// in submission order. While an end or new-task write is awaiting the store,
/// the projection is still alive but the transcript snapshot handed to the
/// store may already be stale, so finals are parked and flushed once the ended
/// task exists.
@MainActor
final class LateTranslationBackfill {
    private let lifecycle: TaskLifecycle
    private var pending: [(entryID: UUID, text: String)] = []
    private var drainTask: Task<Void, Never>?
    private(set) var isEnding = false

    init(lifecycle: TaskLifecycle) {
        self.lifecycle = lifecycle
    }

    /// Opens the end window; finals seen until `endEnding()` are parked even
    /// though the live projection still owns them.
    func beginEnding() {
        isEnding = true
        pending.removeAll()
    }

    func endEnding() {
        isEnding = false
    }

    /// A final result was accepted by the pipeline. A live record normally
    /// keeps it; during an end write the snapshot may already be stale, and
    /// after a reset there is no record at all.
    func finalArrived(entryID: UUID, text: String, hasLiveRecord: Bool) {
        guard isEnding || !hasLiveRecord else { return }
        pending.append((entryID, text))
        guard !isEnding else { return }
        startDrainIfNeeded()
    }

    /// Flushes results parked during the end write. Call after the ended task
    /// exists and before the projection resets.
    func flushPending() async {
        guard !pending.isEmpty else { return }
        let items = pending
        pending.removeAll()
        for item in items {
            await lifecycle.backfillTranslation(entryID: item.entryID, text: item.text)
        }
    }

    func discardPending() {
        pending.removeAll()
    }

    /// Test seam: waits for the post-reset drain started by `finalArrived`.
    func waitForDrain() async {
        await drainTask?.value
    }

    private func startDrainIfNeeded() {
        guard drainTask == nil else { return }
        drainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.pending.isEmpty {
                let next = self.pending.removeFirst()
                await self.lifecycle.backfillTranslation(entryID: next.entryID, text: next.text)
            }
            self.drainTask = nil
        }
    }
}
