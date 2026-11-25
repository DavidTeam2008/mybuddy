import SwiftUI

/// System navigation toolbar shared by the three modules: home, history,
/// new task, end task. The system toolbar supplies the Liquid Glass surface;
/// no custom background is drawn here.
struct ModuleToolbar: ViewModifier {
    let title: String
    let language: AppLanguage
    let isTaskActive: Bool
    let onHome: () -> Void
    let onHistory: () -> Void
    let onNewTask: () -> Void
    let onEndTask: () -> Void

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HomeToolbarButton(language: language, action: onHome)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(action: onHistory) {
                        ToolbarGlyph(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityIdentifier("nav-history")
                    .accessibilityLabel(Copy.historyTitle(for: language))
                    Button(action: onNewTask) {
                        ToolbarGlyph(systemName: "plus")
                    }
                    .accessibilityIdentifier("taskbar-new-task")
                    .accessibilityLabel(Copy.newTask(for: language))
                    Button(action: onEndTask) {
                        ToolbarGlyph(systemName: "stop.fill")
                    }
                    .tint(isTaskActive ? Tokens.danger : Tokens.textSecondary)
                    .accessibilityIdentifier("taskbar-end-task")
                    .accessibilityLabel(Copy.endTask(for: language))
                    .disabled(!isTaskActive)
                }
            }
    }
}

extension View {
    func moduleToolbar(
        title: String,
        language: AppLanguage,
        isTaskActive: Bool,
        onHome: @escaping () -> Void,
        onHistory: @escaping () -> Void,
        onNewTask: @escaping () -> Void,
        onEndTask: @escaping () -> Void
    ) -> some View {
        modifier(
            ModuleToolbar(
                title: title,
                language: language,
                isTaskActive: isTaskActive,
                onHome: onHome,
                onHistory: onHistory,
                onNewTask: onNewTask,
                onEndTask: onEndTask
            )
        )
    }
}
