import SwiftUI

struct InterpretationSettingsSheet: View {
    let viewerLanguage: AppLanguage
    let appMode: AppMode
    let sourceLanguage: AppLanguage
    let targetLanguage: AppLanguage
    let fontSize: CaptionFontSize
    let voiceOutEnabled: Bool
    let showsSourceLine: Bool
    let isVoiceOutBlocked: Bool
    let isRedownloading: Bool
    let speechProgress: Double
    let translationProgress: Double
    let redownloadError: String?
    let canSummarize: Bool
    let onSelectMode: (AppMode) -> Void
    let onSelectSourceLanguage: (AppLanguage) -> Void
    let onSelectTargetLanguage: (AppLanguage) -> Void
    let onSelectFont: (CaptionFontSize) -> Void
    let onToggleVoiceOut: (Bool) -> Void
    let onToggleSourceLine: (Bool) -> Void
    let onClear: () -> Void
    let onSummarize: () -> Void
    let onRedownload: () -> Void
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(Copy.settingsTitle(for: viewerLanguage))
                    .font(.headline)
                    .foregroundStyle(Tokens.textPrimary)

                Text(Copy.modeSection(for: viewerLanguage))
                    .font(.footnote)
                    .foregroundStyle(Tokens.textSecondary)
                HStack(spacing: 8) {
                    SelectChip(
                        title: Copy.modeFaceToFace(for: viewerLanguage),
                        isSelected: appMode == .faceToFace
                    ) {
                        onSelectMode(.faceToFace)
                    }
                    SelectChip(
                        title: Copy.modeSimultaneous(for: viewerLanguage),
                        isSelected: appMode == .simultaneous
                    ) {
                        onSelectMode(.simultaneous)
                    }
                }
                SelectChip(
                    title: Copy.modeMeeting(for: viewerLanguage),
                    isSelected: appMode == .meeting
                ) {
                    onSelectMode(.meeting)
                }

                Text(Copy.theySpeak(for: viewerLanguage))
                    .font(.footnote)
                    .foregroundStyle(Tokens.textSecondary)
                LanguageChipGrid(selected: sourceLanguage, onSelect: onSelectSourceLanguage)

                Text(Copy.iListen(for: viewerLanguage))
                    .font(.footnote)
                    .foregroundStyle(Tokens.textSecondary)
                LanguageChipGrid(selected: targetLanguage, onSelect: onSelectTargetLanguage)

                HStack(spacing: 8) {
                    SelectChip(
                        title: Copy.voiceOut(for: viewerLanguage),
                        isSelected: voiceOutEnabled && !isVoiceOutBlocked
                    ) {
                        onToggleVoiceOut(!voiceOutEnabled)
                    }
                    SelectChip(
                        title: showsSourceLine
                            ? Copy.showSourceLine(for: viewerLanguage)
                            : Copy.hideSourceLine(for: viewerLanguage),
                        isSelected: showsSourceLine
                    ) {
                        onToggleSourceLine(!showsSourceLine)
                    }
                }

                Text(Copy.voiceOutMicHint(for: viewerLanguage))
                    .font(.footnote)
                    .foregroundStyle(Tokens.textSecondary)

                FontSizeChips(
                    language: viewerLanguage,
                    selection: fontSize,
                    onSelect: onSelectFont
                )

                if isRedownloading {
                    AssetDownloadView(
                        speechTitle: Copy.speechModelsTitle(for: viewerLanguage),
                        translationTitle: Copy.translationModelsTitle(for: viewerLanguage),
                        speechProgress: speechProgress,
                        translationProgress: translationProgress
                    )
                }

                if let redownloadError {
                    Text(redownloadError)
                        .font(.footnote)
                        .foregroundStyle(Tokens.danger)
                }

                HStack {
                    Button(Copy.clearCaptions(for: viewerLanguage), action: onClear)
                        .foregroundStyle(Tokens.textPrimary)
                    Spacer()
                    Button(Copy.summarize(for: viewerLanguage), action: onSummarize)
                        .foregroundStyle(canSummarize ? Tokens.accentText : Tokens.textSecondary)
                        .disabled(!canSummarize)
                }
                .font(.subheadline)

                HStack {
                    Button(Copy.redownloadModels(for: viewerLanguage), action: onRedownload)
                        .foregroundStyle(Tokens.textSecondary)
                        .disabled(isRedownloading)
                    Spacer()
                    Button(Copy.done(for: viewerLanguage), action: onDone)
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
