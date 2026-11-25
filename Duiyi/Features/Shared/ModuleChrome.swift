import SwiftUI

struct ModuleChrome: View {
    let title: String
    let language: AppLanguage
    let onHome: () -> Void
    let onHistory: () -> Void

    var body: some View {
        HStack {
            Button(action: onHome) {
                Text(Copy.homeButton(for: language))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Tokens.accentText)
                    .minHitTarget()
            }
            .accessibilityIdentifier("nav-home")
            Spacer()
            Text(title)
                .font(.headline)
                .foregroundStyle(Tokens.textPrimary)
            Spacer()
            Button(action: onHistory) {
                Text(Copy.historyTitle(for: language))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Tokens.accentText)
                    .minHitTarget()
            }
            .accessibilityIdentifier("nav-history")
        }
        .padding(.horizontal, Tokens.horizontalPadding)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
    }
}
