import SwiftUI
import UIKit

struct ListeningControl: View {
    let sessionState: SessionState
    let label: String
    let swapLabel: String
    let settingsLabel: String
    let settingsHint: String
    var isEnabled: Bool = true
    var showsSwap: Bool = true
    let onTap: () -> Void
    let onOpenSettings: () -> Void
    let onSwap: () -> Void

    @State private var pulse = false
    @State private var openedSettingsThisTouch = false
    @State private var longPressTask: Task<Void, Never>?
    @State private var isTouching = false

    private var isListening: Bool { sessionState.isListening }

    var body: some View {
        ZStack {
            HStack {
                if showsSwap {
                    Button(action: onSwap) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Tokens.textSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(swapLabel)
                    .padding(.leading, 14)
                }

                Spacer()

                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Tokens.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-open")
                .accessibilityLabel(settingsLabel)
                .padding(.trailing, 14)
            }

            controlButton
        }
        .frame(height: Tokens.midBarHeight)
        .background(Tokens.canvas)
        .onAppear(perform: syncPulse)
        .onChange(of: isListening) { _, _ in
            syncPulse()
        }
        .onDisappear {
            longPressTask?.cancel()
        }
    }

    private var controlButton: some View {
        let symbolColor: Color = {
            if sessionState.isFailed { return Tokens.onDanger }
            if !isEnabled { return Tokens.textPrimary }
            return Tokens.onAccent
        }()

        return ZStack {
            Circle()
                .fill(isListening ? Tokens.listen.opacity(0.18) : Color.clear)
                .frame(width: Tokens.micHitSize, height: Tokens.micHitSize)
                .scaleEffect(isListening && pulse ? 1.08 : 1)
            micFill
            Image(systemName: symbolName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(symbolColor)
        }
        .frame(width: Tokens.micHitSize, height: Tokens.micHitSize)
        .contentShape(Circle())
        .gesture(pressGesture)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityIdentifier("listening-control")
        .accessibilityLabel(label)
        .accessibilityHint(settingsHint)
        .accessibilityAddTraits(.isButton)
    }

    /// The microphone is the only custom Liquid Glass control in a module.
    /// Failures, disabled states, and Reduce Transparency fall back to opaque fills.
    private var micFill: some View {
        Group {
            if sessionState.isFailed {
                Circle()
                    .fill(Tokens.danger)
            } else if !isEnabled {
                Circle()
                    .fill(Tokens.controlIdle.opacity(0.7))
            } else if UIAccessibility.isReduceTransparencyEnabled {
                Circle()
                    .fill(Tokens.listen)
            } else {
                Circle()
                    .fill(Color.clear)
                    .glassEffect(
                        .regular.tint(Tokens.listen).interactive(),
                        in: Circle()
                    )
            }
        }
        .frame(width: Tokens.micSize, height: Tokens.micSize)
    }

    private var symbolName: String {
        switch sessionState {
        case .listening:
            return "waveform"
        case .paused:
            return "mic.fill"
        case .failed:
            return "exclamationmark"
        case .preparing:
            return "ellipsis"
        case .ready, .idle:
            return "mic"
        }
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isTouching else { return }
                isTouching = true
                openedSettingsThisTouch = false
                longPressTask?.cancel()
                longPressTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !Task.isCancelled else { return }
                    openedSettingsThisTouch = true
                    onOpenSettings()
                }
            }
            .onEnded { _ in
                longPressTask?.cancel()
                longPressTask = nil
                let shouldTap = isTouching && !openedSettingsThisTouch
                isTouching = false
                openedSettingsThisTouch = false
                if shouldTap, isEnabled {
                    onTap()
                }
            }
    }

    private func syncPulse() {
        guard ReduceMotion.allowed else {
            pulse = false
            return
        }
        if isListening {
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                pulse = true
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                pulse = false
            }
        }
    }
}
