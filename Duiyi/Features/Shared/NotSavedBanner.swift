import SwiftUI

/// The one "this content won't be saved" banner shared by the three live
/// modules. Callers supply the module-specific accessibility identifier.
struct NotSavedBanner: View {
    let language: AppLanguage
    let accessibilityIdentifier: String

    var body: some View {
        Text(Copy.notSavedBanner(for: language))
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Tokens.warningText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                Tokens.warningBackground,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .padding(.horizontal, Tokens.horizontalPadding)
            .padding(.bottom, 8)
            .accessibilityIdentifier(accessibilityIdentifier)
    }
}
