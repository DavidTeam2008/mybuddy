import SwiftUI

/// History-style chrome: large navigation title and a leading home button.
/// The system toolbar supplies the Liquid Glass surface.
struct HistoryToolbar: ViewModifier {
    let title: String
    let language: AppLanguage
    let onHome: () -> Void

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HomeToolbarButton(language: language, action: onHome)
                }
            }
    }
}

extension View {
    func historyToolbar(
        title: String,
        language: AppLanguage,
        onHome: @escaping () -> Void
    ) -> some View {
        modifier(HistoryToolbar(title: title, language: language, onHome: onHome))
    }
}
