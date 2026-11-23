import Foundation
@testable import Duiyi

/// Deterministic `TranslationScheduler` for tests: time only moves when the
/// test advances it, and every requested delay is recorded so wiring tests can
/// assert what a ViewModel submitted without driving the debounce themselves.
@MainActor
final class ManualTranslationScheduler: TranslationScheduler {
    @MainActor
    private final class Work: TranslationScheduledTask {
        let delay: Duration
        let deadline: Duration
        var action: (@MainActor @Sendable () -> Void)?

        init(delay: Duration, deadline: Duration, action: @escaping @MainActor @Sendable () -> Void) {
            self.delay = delay
            self.deadline = deadline
            self.action = action
        }

        func cancel() {
            action = nil
        }
    }

    private var work: [Work] = []
    private(set) var now: Duration = .zero

    /// Every delay requested so far, in submission order. Cancelled work stays
    /// in this history; use `pendingDelays` for work that can still fire.
    private(set) var scheduledDelays: [Duration] = []

    var pendingDelays: [Duration] {
        work.compactMap { $0.action == nil ? nil : $0.delay }
    }

    func schedule(
        after delay: Duration,
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> any TranslationScheduledTask {
        scheduledDelays.append(delay)
        let item = Work(delay: delay, deadline: now + delay, action: action)
        work.append(item)
        return item
    }

    func advance(by duration: Duration) {
        now += duration
        while let index = work.firstIndex(where: { $0.action != nil && $0.deadline <= now }) {
            let item = work.remove(at: index)
            let action = item.action
            item.action = nil
            action?()
        }
    }
}
