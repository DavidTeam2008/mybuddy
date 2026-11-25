import Foundation

enum TaskStatusText {
    static func make(hasTask: Bool, startedAt: Date?, language: AppLanguage) -> String {
        guard hasTask else { return Copy.taskIdle(for: language) }
        guard let startedAt else { return Copy.taskRunning(for: language) }
        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed < 90 {
            return "\(Copy.taskRunning(for: language)) · \(Copy.justNow(for: language))"
        }
        return "\(Copy.taskRunning(for: language)) · \(TaskFormatting.durationText(seconds: elapsed, language: language))"
    }
}
