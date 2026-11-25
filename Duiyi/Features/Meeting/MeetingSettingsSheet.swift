import SwiftUI

struct MeetingSettingsSheet: View {
    let language: AppLanguage
    let recognizesMultipleLanguages: Bool
    let sourceLanguage: AppLanguage
    let fontSize: CaptionFontSize
    let isRedownloading: Bool
    let speechProgress: Double
    let redownloadError: String?
    let canSummarize: Bool
    let onSelectMultilingual: (Bool) -> Void
    let onSelectLanguage: (AppLanguage) -> Void
    let onSelectFont: (CaptionFontSize) -> Void
    let onClear: () -> Void
    let onSummarize: () -> Void
    let onRedownload: () -> Void
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(Copy.settingsTitle(for: language))
                    .font(.headline)
                    .foregroundStyle(Tokens.textPrimary)

                Text(Copy.meetingRecognitionMode(for: language))
                    .font(.footnote)
                    .foregroundStyle(Tokens.textSecondary)
                HStack(spacing: 8) {
                    SelectChip(
                        title: Copy.meetingMultilingual(for: language),
                        isSelected: recognizesMultipleLanguages
                    ) {
                        onSelectMultilingual(true)
                    }
                    SelectChip(
                        title: Copy.meetingSingleLanguage(for: language),
                        isSelected: !recognizesMultipleLanguages
                    ) {
                        onSelectMultilingual(false)
                    }
                }
                Text(Copy.meetingMultilingualHint(for: language))
                    .font(.footnote)
                    .foregroundStyle(Tokens.textSecondary)

                if !recognizesMultipleLanguages {
                    Text(Copy.meetingLanguage(for: language))
                        .font(.footnote)
                        .foregroundStyle(Tokens.textSecondary)
                    LanguageChipGrid(selected: sourceLanguage, onSelect: onSelectLanguage)
                }

                FontSizeChips(
                    language: language,
                    selection: fontSize,
                    onSelect: onSelectFont
                )

                if isRedownloading {
                    AssetDownloadView(
                        speechTitle: Copy.speechModelsTitle(for: language),
                        translationTitle: Copy.translationModelsTitle(for: language),
                        speechProgress: speechProgress,
                        translationProgress: max(speechProgress, 0.55)
                    )
                }

                if let redownloadError {
                    Text(redownloadError)
                        .font(.footnote)
                        .foregroundStyle(Tokens.danger)
                }

                HStack {
                    Button(Copy.clearCaptions(for: language), action: onClear)
                        .foregroundStyle(Tokens.textPrimary)
                    Spacer()
                    Button(Copy.summarize(for: language), action: onSummarize)
                        .foregroundStyle(canSummarize ? Tokens.accentText : Tokens.textSecondary)
                        .disabled(!canSummarize)
                }
                .font(.subheadline)

                HStack {
                    Button(Copy.redownloadModels(for: language), action: onRedownload)
                        .foregroundStyle(Tokens.textSecondary)
                        .disabled(isRedownloading)
                    Spacer()
                    Button(Copy.done(for: language), action: onDone)
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
