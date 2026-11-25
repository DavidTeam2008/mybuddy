import SwiftUI

struct VoiceOutControl: View {
    let label: String
    let isEnabled: Bool
    let isBlocked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(isEnabled || isBlocked ? .semibold : .regular))
                .foregroundStyle(foreground)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(background, in: Capsule())
                .minHitTarget()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("voice-out")
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
    }

    private var foreground: Color {
        if isBlocked { return Tokens.danger }
        if isEnabled { return Tokens.onAccent }
        return Tokens.textPrimary
    }

    private var background: Color {
        if isBlocked { return Tokens.blockedBackground }
        if isEnabled { return Tokens.listen }
        return Tokens.controlIdle
    }
}
