import SwiftUI

/// Detail-style chrome: inline title, the system back button, and a trailing
/// home button. The system toolbar supplies the Liquid Glass surface.
struct DetailToolbar: ViewModifier {
    let title: String
    let language: AppLanguage
    let onHome: () -> Void

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HomeToolbarButton(language: language, action: onHome)
                }
            }
    }
}

extension View {
    func detailToolbar(
        title: String,
        language: AppLanguage,
        onHome: @escaping () -> Void
    ) -> some View {
        modifier(DetailToolbar(title: title, language: language, onHome: onHome))
    }
}
