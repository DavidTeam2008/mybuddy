import Foundation
import Testing
@testable import Duiyi

/// Waits for one buffered wakeup. The sleep is only a failure watchdog so a
/// regression cannot hang the suite; the passing path resolves immediately.
private func receivesWakeup(
    _ consumer: TranslationJobBridge.Consumer,
    timeout: Duration = .milliseconds(500)
) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            var iterator = consumer.wakeups.makeAsyncIterator()
            let wakeup: Void? = await iterator.next()
            return wakeup != nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return false
        }
        let received = await group.next() ?? false
        group.cancelAll()
        return received
    }
}

@MainActor
struct TranslationJobBridgeTests {
    @Test("Submitting the same utterance repeatedly keeps only the newest job")
    func sameUtteranceCoalescesToNewest() {
        let bridge = TranslationJobBridge()
        let utteranceID = UUID()
        let first = makeTranslationJob(utteranceID: utteranceID, text: "A1")
        let second = makeTranslationJob(utteranceID: utteranceID, text: "A2")
        let third = makeTranslationJob(utteranceID: utteranceID, text: "A3")

        bridge.submit(first)
        bridge.submit(second)
        bridge.submit(third)

        let consumer = bridge.makeConsumer()
        #expect(consumer.takeNext() == third)
        #expect(consumer.takeNext() == nil)
    }

    @Test("Different utterances stay FIFO while a refreshed utterance keeps its first slot")
    func crossUtteranceOrdering() {
        let bridge = TranslationJobBridge()
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        let first = makeTranslationJob(utteranceID: firstID, text: "A1")
        let second = makeTranslationJob(utteranceID: secondID, text: "B1")
        let firstUpdate = makeTranslationJob(utteranceID: firstID, text: "A2")
        let third = makeTranslationJob(utteranceID: thirdID, text: "C1")

        bridge.submit(first)
        bridge.submit(second)
        bridge.submit(firstUpdate)
        bridge.submit(third)

        let consumer = bridge.makeConsumer()
        #expect(consumer.takeNext() == firstUpdate)
        #expect(consumer.takeNext() == second)
        #expect(consumer.takeNext() == third)
        #expect(consumer.takeNext() == nil)
    }

    @Test("A queued final is never replaced by a newer non-final")
    func queuedFinalSurvivesNonFinalUpdate() {
        let bridge = TranslationJobBridge()
        let utteranceID = UUID()
        let final = makeTranslationJob(utteranceID: utteranceID, text: "final text", isFinal: true)
        let trailingVolatile = makeTranslationJob(utteranceID: utteranceID, text: "volatile tail", isFinal: false)

        bridge.submit(final)
        bridge.submit(trailingVolatile)

        let consumer = bridge.makeConsumer()
        #expect(consumer.takeNext() == final)
        #expect(consumer.takeNext() == nil)
    }

    @Test("A newer final replaces a queued non-final or final for the same utterance")
    func newerFinalReplacesQueuedJob() {
        let bridge = TranslationJobBridge()
        let volatileID = UUID()
        let finalID = UUID()
        let volatile = makeTranslationJob(utteranceID: volatileID, text: "partial", isFinal: false)
        let firstFinal = makeTranslationJob(utteranceID: volatileID, text: "complete", isFinal: true)
        let olderFinal = makeTranslationJob(utteranceID: finalID, text: "old final", isFinal: true)
        let newerFinal = makeTranslationJob(utteranceID: finalID, text: "new final", isFinal: true)

        bridge.submit(volatile)
        bridge.submit(firstFinal)
        bridge.submit(olderFinal)
        bridge.submit(newerFinal)

        let consumer = bridge.makeConsumer()
        #expect(consumer.takeNext() == firstFinal)
        #expect(consumer.takeNext() == newerFinal)
        #expect(consumer.takeNext() == nil)
    }

    @Test("Jobs queued before a consumer installs wake it and drain in order")
    func queuedJobsWakeNewConsumer() async {
        let bridge = TranslationJobBridge()
        let first = makeTranslationJob(utteranceID: UUID(), text: "A1")
        let second = makeTranslationJob(utteranceID: UUID(), text: "B1")

        bridge.submit(first)
        bridge.submit(second)

        let consumer = bridge.makeConsumer()
        #expect(await receivesWakeup(consumer))
        #expect(consumer.takeNext() == first)
        #expect(consumer.takeNext() == second)
        #expect(consumer.takeNext() == nil)
    }

    @Test("One wakeup is enough to drain several jobs submitted after install")
    func oneWakeupDrainsMultipleJobs() async {
        let bridge = TranslationJobBridge()
        let consumer = bridge.makeConsumer()
        let first = makeTranslationJob(utteranceID: UUID(), text: "A1")
        let second = makeTranslationJob(utteranceID: UUID(), text: "B1")

        bridge.submit(first)
        bridge.submit(second)

        #expect(await receivesWakeup(consumer))
        #expect(consumer.takeNext() == first)
        #expect(consumer.takeNext() == second)
        #expect(consumer.takeNext() == nil)
    }

    @Test("A superseded consumer can no longer take jobs")
    func supersededConsumerCannotTakeJobs() {
        let bridge = TranslationJobBridge()
        let job = makeTranslationJob(utteranceID: UUID(), text: "hello", isFinal: true)
        bridge.submit(job)

        let superseded = bridge.makeConsumer()
        let current = bridge.makeConsumer()

        #expect(superseded.takeNext() == nil)
        #expect(current.takeNext() == job)
    }

    @Test("A superseded consumer's termination does not detach the new consumer")
    func supersededTerminationKeepsNewConsumerAttached() async {
        let bridge = TranslationJobBridge()
        let superseded = bridge.makeConsumer()
        let current = bridge.makeConsumer()
        let job = makeTranslationJob(utteranceID: UUID(), text: "hello", isFinal: true)

        bridge.submit(job)

        #expect(superseded.takeNext() == nil)
        #expect(await receivesWakeup(current))
        #expect(current.takeNext() == job)
    }

    @Test("A requeued job returns to the front of the queue")
    func requeuedJobGoesToFront() {
        let bridge = TranslationJobBridge()
        let first = makeTranslationJob(utteranceID: UUID(), text: "A1")
        let second = makeTranslationJob(utteranceID: UUID(), text: "B1")
        bridge.submit(first)
        bridge.submit(second)

        let consumer = bridge.makeConsumer()
        #expect(consumer.takeNext() == first)
        consumer.requeue(first)

        #expect(consumer.takeNext() == first)
        #expect(consumer.takeNext() == second)
        #expect(consumer.takeNext() == nil)
    }

    @Test("A requeued job is discarded when its utterance already has a pending job")
    func requeueDiscardsWhenNewerSameUtterancePending() {
        let bridge = TranslationJobBridge()
        let utteranceID = UUID()
        let original = makeTranslationJob(utteranceID: utteranceID, text: "A1")
        let other = makeTranslationJob(utteranceID: UUID(), text: "B1")
        let newer = makeTranslationJob(utteranceID: utteranceID, text: "A2")
        bridge.submit(original)
        bridge.submit(other)

        let consumer = bridge.makeConsumer()
        #expect(consumer.takeNext() == original)
        bridge.submit(newer)
        consumer.requeue(original)

        #expect(consumer.takeNext() == other)
        #expect(consumer.takeNext() == newer)
        #expect(consumer.takeNext() == nil)
    }

    @Test("A superseded consumer cannot requeue a job")
    func supersededConsumerCannotRequeue() {
        let bridge = TranslationJobBridge()
        let superseded = bridge.makeConsumer()
        let current = bridge.makeConsumer()
        let job = makeTranslationJob(utteranceID: UUID(), text: "hello", isFinal: true)

        superseded.requeue(job)
        #expect(current.takeNext() == nil)

        current.requeue(job)
        #expect(current.takeNext() == job)
        #expect(current.takeNext() == nil)
    }

    @Test("A whitespace-only job never enters the queue")
    func whitespaceOnlyJobIsIgnored() {
        let bridge = TranslationJobBridge()
        bridge.submit(makeTranslationJob(utteranceID: UUID(), text: " \n\t ", isFinal: true))

        let consumer = bridge.makeConsumer()
        #expect(consumer.takeNext() == nil)
    }

    @Test("A whitespace-only update does not evict the queued job for its utterance")
    func whitespaceUpdateDoesNotEvictQueuedJob() {
        let bridge = TranslationJobBridge()
        let utteranceID = UUID()
        let queued = makeTranslationJob(utteranceID: utteranceID, text: "hello", isFinal: true)
        bridge.submit(queued)
        bridge.submit(makeTranslationJob(utteranceID: utteranceID, text: "   ", isFinal: false))

        let consumer = bridge.makeConsumer()
        #expect(consumer.takeNext() == queued)
        #expect(consumer.takeNext() == nil)
    }
}
