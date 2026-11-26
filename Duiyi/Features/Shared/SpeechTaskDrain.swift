import Foundation

/// Bounded wait for a feature's speech consumer after the gate has stopped
/// its stream. The consumer normally finishes as soon as the stream ends; the
/// timeout keeps stop/end/new-task from hanging on a stuck consumer.
@MainActor
enum SpeechTaskDrain {
    static let timeout: Duration = .milliseconds(500)

    @discardableResult
    static func wait(for task: Task<Void, Never>?) async -> Bool {
        guard let task else { return true }
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await task.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        if !finished {
            task.cancel()
        }
        return finished
    }
}
