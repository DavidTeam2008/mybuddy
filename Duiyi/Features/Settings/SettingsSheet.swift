import SwiftUI

struct SettingsSheet: View {
    let userLanguage: AppLanguage
    let peerLanguage: AppLanguage
    let appMode: AppMode
    let fontSize: CaptionFontSize
    let autoStartListening: Bool
    let listeningMode: ConversationListeningMode
    let isRedownloading: Bool
    let speechProgress: Double
    let translationProgress: Double
    let redownloadError: String?
    let onSelectMode: (AppMode) -> Void
    let onSelectUserLanguage: (AppLanguage) -> Void
    let onSelectPeerLanguage: (AppLanguage) -> Void
    let onSelectFont: (CaptionFontSize) -> Void
    let onToggleAutoStart: (Bool) -> Void
    let onSelectListeningMode: (ConversationListeningMode) -> Void
    let onClear: () -> Void
    let onSummarize: () -> Void
    let canSummarize: Bool
    let onRedownload: () -> Void
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
            Text(Copy.settingsTitle(for: userLanguage))
                .font(.headline)
                .foregroundStyle(Tokens.textPrimary)

            Text(Copy.modeSection(for: userLanguage))
                .font(.footnote)
                .foregroundStyle(Tokens.textSecondary)
            HStack(spacing: 8) {
                SelectChip(
                    title: Copy.modeFaceToFace(for: userLanguage),
                    isSelected: appMode == .faceToFace
                ) {
                    onSelectMode(.faceToFace)
                }
                SelectChip(
                    title: Copy.modeSimultaneous(for: userLanguage),
                    isSelected: appMode == .simultaneous
                ) {
                    onSelectMode(.simultaneous)
                }
            }
            SelectChip(
                title: Copy.modeMeeting(for: userLanguage),
                isSelected: appMode == .meeting
            ) {
                onSelectMode(.meeting)
            }

            Text(Copy.turnModeSection(for: userLanguage))
                .font(.footnote)
                .foregroundStyle(Tokens.textSecondary)
            HStack(spacing: 8) {
                SelectChip(
                    title: Copy.turnModeManual(for: userLanguage),
                    isSelected: listeningMode == .manual
                ) {
                    onSelectListeningMode(.manual)
                }
                .accessibilityIdentifier("conversation-mode-manual")
                SelectChip(
                    title: Copy.turnModeAutomatic(for: userLanguage),
                    isSelected: listeningMode == .automatic
                ) {
                    onSelectListeningMode(.automatic)
                }
                .accessibilityIdentifier("conversation-mode-automatic")
            }
            Text(
                listeningMode == .manual
                    ? Copy.turnModeManualHint(for: userLanguage)
                    : Copy.turnModeAutomaticHint(for: userLanguage)
            )
            .font(.caption)
            .foregroundStyle(Tokens.textSecondary)

            Text(Copy.iReadSection(for: userLanguage))
                .font(.footnote)
                .foregroundStyle(Tokens.textSecondary)
            LanguageChipGrid(selected: userLanguage, onSelect: onSelectUserLanguage)

            Text(Copy.theyReadSection(for: userLanguage))
                .font(.footnote)
                .foregroundStyle(Tokens.textSecondary)
            LanguageChipGrid(selected: peerLanguage, onSelect: onSelectPeerLanguage)

            FontSizeChips(
                language: userLanguage,
                selection: fontSize,
                onSelect: onSelectFont
            )

            Text(Copy.autoStart(for: userLanguage))
                .font(.footnote)
                .foregroundStyle(Tokens.textSecondary)

            HStack(spacing: 8) {
                SelectChip(
                    title: Copy.autoStartOn(for: userLanguage),
                    isSelected: autoStartListening
                ) {
                    onToggleAutoStart(true)
                }
                SelectChip(
                    title: Copy.autoStartOff(for: userLanguage),
                    isSelected: !autoStartListening
                ) {
                    onToggleAutoStart(false)
                }
            }

            if isRedownloading {
                AssetDownloadView(
                    speechTitle: Copy.speechModelsTitle(for: userLanguage),
                    translationTitle: Copy.translationModelsTitle(for: userLanguage),
                    speechProgress: speechProgress,
                    translationProgress: translationProgress
                )
            }

            if let redownloadError {
                Text(redownloadError)
                    .font(.footnote)
                    .foregroundStyle(Tokens.danger)
            }

            Text(Copy.tableHint(for: userLanguage))
                .font(.footnote)
                .foregroundStyle(Tokens.textSecondary)

            HStack {
                Button(Copy.clearCaptions(for: userLanguage), action: onClear)
                    .foregroundStyle(Tokens.textPrimary)
                Spacer()
                Button(Copy.summarize(for: userLanguage), action: onSummarize)
                    .foregroundStyle(canSummarize ? Tokens.accentText : Tokens.textSecondary)
                    .disabled(!canSummarize)
            }
            .font(.subheadline)

            HStack {
                Button(Copy.redownloadModels(for: userLanguage), action: onRedownload)
                    .foregroundStyle(Tokens.textSecondary)
                    .disabled(isRedownloading)
                Spacer()
                Button(Copy.done(for: userLanguage), action: onDone)
                    .fontWeight(.semibold)
                    .foregroundStyle(Tokens.onAccent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Tokens.listen, in: Capsule())
            }
            .font(.subheadline)
            }
            .padding(18)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .background(Tokens.sheet, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 24)
    }

}
