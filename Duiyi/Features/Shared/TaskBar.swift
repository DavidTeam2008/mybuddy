import SwiftUI

struct TaskBar: View {
    let language: AppLanguage
    let statusText: String
    let isActive: Bool
    let onNewTask: () -> Void
    let onEndTask: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(statusText)
                .font(.caption.weight(.medium))
                .foregroundStyle(isActive ? Tokens.accentText : Tokens.textSecondary)
                .accessibilityLabel(statusText)
            Spacer(minLength: 8)
            Button(action: onNewTask) {
                Text(Copy.newTask(for: language))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Tokens.accentText)
                    .minHitTarget()
            }
            .accessibilityIdentifier("taskbar-new-task")
            Button(action: onEndTask) {
                Text(Copy.endTask(for: language))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isActive ? Tokens.danger : Tokens.textSecondary)
                    .minHitTarget()
            }
            .disabled(!isActive)
            .accessibilityIdentifier("taskbar-end-task")
        }
        .padding(.horizontal, Tokens.horizontalPadding)
        .padding(.bottom, 8)
    }
}

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
