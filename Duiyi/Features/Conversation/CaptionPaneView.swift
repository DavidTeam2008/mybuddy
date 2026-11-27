import SwiftUI
import UIKit

struct CaptionPaneView: View {
    let viewerLanguage: AppLanguage
    let pane: PaneState
    let fontSize: CaptionFontSize
    let isPeer: Bool
    let sessionState: SessionState
    let errorText: String?
    var isPickingLanguage = false
    var onChooseLanguage: (() -> Void)?
    var onSelectLanguage: ((AppLanguage) -> Void)?
    var onCancelPicking: (() -> Void)?
    var idleOverride: String? = nil
    var listeningMode: ConversationListeningMode = .automatic
    var activeSpeaker: SpeakerSide?
    var turnEnabled = false
    var onSelectTurn: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsTurnBar {
                turnBar
            }
            languageBadge

            if isPickingLanguage {
                languagePicker
            } else {
                currentBlock
                if !pane.history.isEmpty {
                    historyBlock
                } else {
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, Tokens.horizontalPadding)
        .padding(.top, isPeer ? 24 : 28)
        .padding(.bottom, isPeer ? ScreenSafeArea.top : max(36, ScreenSafeArea.bottom + 8))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            ZStack {
                isPeer ? Tokens.peerPane : Tokens.userPane
                if isTurnActive {
                    Tokens.speaking.opacity(0.07)
                }
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Manual turn bar

    private var side: SpeakerSide { isPeer ? .peer : .user }

    private var showsTurnBar: Bool {
        listeningMode == .manual && onSelectTurn != nil
    }

    private var isTurnActive: Bool {
        listeningMode == .manual && activeSpeaker == side
    }

    private var isOtherTurnActive: Bool {
        guard listeningMode == .manual, let activeSpeaker else { return false }
        return activeSpeaker == side.opposite
    }

    private var turnStatusText: String {
        if isTurnActive {
            return Copy.turnIAmSpeaking(for: viewerLanguage)
        }
        if isOtherTurnActive {
            return Copy.turnOtherIsSpeaking(for: viewerLanguage)
        }
        return Copy.turnTapToSpeak(for: viewerLanguage)
    }

    /// Full-width tap target above the language chip and captions. The pane is
    /// rotated for the peer, so this bar is physically reachable by them; the
    /// pane's `.accessibilityHidden(true)` leaves VoiceOver on the lower bar
    /// and the middle control.
    private var turnBar: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onSelectTurn?()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isTurnActive ? "waveform" : "hand.tap")
                    .font(.system(size: 15, weight: .semibold))
                Text(turnStatusText)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                if isTurnActive {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 14, weight: .semibold))
                }
            }
            .foregroundStyle(turnForeground)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: Tokens.minHitTarget)
            .background(
                turnBackground,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!turnEnabled)
        .opacity(turnEnabled ? 1 : 0.5)
        .accessibilityIdentifier(isPeer ? "conversation-turn-peer" : "conversation-turn-user")
        .accessibilityLabel(turnStatusText)
        .accessibilityAddTraits(.isButton)
        .animation(.easeInOut(duration: 0.18), value: isTurnActive)
        .animation(.easeInOut(duration: 0.18), value: isOtherTurnActive)
    }

    private var turnForeground: Color {
        if isTurnActive { return Tokens.speaking }
        return isOtherTurnActive ? Tokens.textPrimary : Tokens.textSecondary
    }

    private var turnBackground: Color {
        if isTurnActive { return Tokens.speaking.opacity(0.16) }
        return Tokens.controlIdle.opacity(isOtherTurnActive ? 0.35 : 0.55)
    }

    private var languageBadge: some View {
        Button {
            if isPickingLanguage {
                onCancelPicking?()
            } else {
                onChooseLanguage?()
            }
        } label: {
            HStack(spacing: 4) {
                Text(viewerLanguage.badge)
                    .font(CaptionTypography.badgeFont())
                    .tracking(0.8)
                Image(systemName: isPickingLanguage ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Tokens.languageBadge(viewerLanguage))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .overlay(
                Capsule()
                    .stroke(Tokens.languageBadge(viewerLanguage), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(Copy.changeLanguage(for: viewerLanguage)), \(viewerLanguage.nativeName)")
        .animation(.easeInOut(duration: 0.25), value: viewerLanguage)
        .animation(.easeInOut(duration: 0.18), value: isPickingLanguage)
    }

    private var languagePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Copy.iReadSection(for: viewerLanguage))
                .font(.footnote)
                .foregroundStyle(Tokens.textSecondary)
            LanguageChipGrid(selected: viewerLanguage) { language in
                onSelectLanguage?(language)
            }
            Button(Copy.done(for: viewerLanguage)) {
                onCancelPicking?()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Tokens.onAccent)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Tokens.listen, in: Capsule())
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var currentBlock: some View {
        Text(liveText)
            .font(liveFont)
            .foregroundStyle(liveIsSecondary ? Tokens.textSecondary : Tokens.textPrimary)
            .lineSpacing(fontSize.livePoints * 0.18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transaction { transaction in
                transaction.animation = nil
            }
            .accessibilityAddTraits(.isStaticText)
    }

    private var historyBlock: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(pane.history.reversed())) { line in
                        Text(line.visibleText(forViewer: viewerLanguage))
                            .font(CaptionTypography.previousFont(size: fontSize))
                            .foregroundStyle(Tokens.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onAppear {
                scrollToNewest(proxy)
            }
            .onChange(of: pane.history.last?.id) { _, _ in
                scrollToNewest(proxy)
            }
        }
    }

    private var liveFont: Font {
        CaptionTypography.liveFont(size: fontSize, settled: liveIsSettled)
    }

    private var liveIsSettled: Bool {
        if errorText != nil, !isPeer { return true }
        if pane.speakingHint != nil { return false }
        return pane.live?.phase == .settled && !(pane.live?.translatedText.isEmpty ?? true)
    }

    private var liveText: String {
        if let errorText, !isPeer {
            return errorText
        }
        if let hint = pane.speakingHint {
            return hint
        }
        if let live = pane.live {
            return live.visibleText(forViewer: viewerLanguage)
        }
        return idlePrompt
    }

    private var liveIsSecondary: Bool {
        if errorText != nil, !isPeer { return false }
        if pane.speakingHint != nil { return true }
        if let live = pane.live {
            return live.phase == .streaming || live.translatedText.isEmpty
        }
        return true
    }

    private var idlePrompt: String {
        if let idleOverride { return idleOverride }
        if listeningMode == .manual, activeSpeaker == nil {
            return Copy.whichSideSpeaksFirst(for: viewerLanguage)
        }
        switch sessionState {
        case .ready, .idle, .paused:
            return isPeer
                ? Copy.peerIdlePrompt(for: viewerLanguage)
                : Copy.idlePrompt(for: viewerLanguage)
        case .preparing:
            return Copy.preparing(for: viewerLanguage)
        default:
            return Copy.listening(for: viewerLanguage)
        }
    }

    private func scrollToNewest(_ proxy: ScrollViewProxy) {
        guard let newest = pane.history.last?.id else { return }
        var transaction = Transaction()
        transaction.animation = ReduceMotion.allowed ? .easeOut(duration: 0.18) : nil
        withTransaction(transaction) {
            proxy.scrollTo(newest, anchor: .top)
        }
    }
}

@MainActor
enum ReduceMotion {
    static var allowed: Bool {
        !UIAccessibility.isReduceMotionEnabled
    }
}
