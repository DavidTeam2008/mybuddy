import SwiftUI
import UIKit

struct HomeSettingsSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var isRedownloading = false
    @State private var speechProgress: Double = 0
    @State private var redownloadError: String?
    @State private var unavailableLanguages: Set<AppLanguage> = []
    #if DEBUG
    @State private var diagnosticsFileURL: URL?
    #endif

    private var language: AppLanguage { environment.preferences.userLanguage }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(Copy.iReadSection(for: language))
                        .font(.footnote)
                        .foregroundStyle(Tokens.textSecondary)
                    LanguageChipGrid(
                        selected: language,
                        languages: environment.languageCatalog.all,
                        unavailableLanguages: unavailableLanguages
                    ) { selected in
                        environment.preferences.userLanguage = selected
                    }

                    Text(Copy.fontLarger(for: language))
                        .font(.footnote)
                        .foregroundStyle(Tokens.textSecondary)
                    FontSizeChips(
                        language: language,
                        selection: environment.preferences.fontSize
                    ) { size in
                        environment.preferences.fontSize = size
                    }

                    if isRedownloading {
                        AssetDownloadView(
                            speechTitle: Copy.speechModelsTitle(for: language),
                            translationTitle: Copy.translationModelsTitle(for: language),
                            speechProgress: speechProgress,
                            translationProgress: max(speechProgress, 0.4)
                        )
                    }

                    if let redownloadError {
                        Text(redownloadError)
                            .font(.footnote)
                            .foregroundStyle(Tokens.danger)
                    }

                    Button(Copy.redownloadModels(for: language)) {
                        Task { await redownload() }
                    }
                    .foregroundStyle(Tokens.textSecondary)
                    .disabled(isRedownloading)

                    #if DEBUG
                    debugRecognitionSection
                    diagnosticsSection
                    #endif

                    Button(Copy.openSettings(for: language)) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .foregroundStyle(Tokens.accentText)
                }
                .padding(20)
            }
            .navigationTitle(Copy.settingsTitle(for: language))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Copy.done(for: language)) { dismiss() }
                        .foregroundStyle(Tokens.accentText)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            await environment.languageCatalog.refreshCapabilities()
            unavailableLanguages = LanguageCatalogSelection.unavailableLanguages(from: environment.languageCatalog)
        }
    }

    #if DEBUG
    /// A/B fixture for the face-to-face recognition plan. Off is the
    /// production dual-locale request; on forces one transcriber. The switch
    /// is read when the next listening request is built.
    private var debugRecognitionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                isOn: Binding(
                    get: { environment.preferences.debugForceSingleLocale },
                    set: { environment.preferences.debugForceSingleLocale = $0 }
                )
            ) {
                Text(debugCopy.forceSingleLocale)
                    .font(.footnote)
                    .foregroundStyle(Tokens.textSecondary)
            }
            .accessibilityIdentifier("debug-force-single-locale")

            if environment.preferences.debugForceSingleLocale {
                Picker(
                    debugCopy.singleLocaleSide,
                    selection: Binding(
                        get: { environment.preferences.debugSingleLocaleUsesPeer },
                        set: { environment.preferences.debugSingleLocaleUsesPeer = $0 }
                    )
                ) {
                    Text(debugCopy.userLanguage).tag(false)
                    Text(debugCopy.peerLanguage).tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("debug-single-locale-side")

                Text(debugCopy.hint)
                    .font(.caption)
                    .foregroundStyle(Tokens.textSecondary)
            }
        }
    }

    private var debugCopy: (
        forceSingleLocale: String,
        singleLocaleSide: String,
        userLanguage: String,
        peerLanguage: String,
        hint: String
    ) {
        if language == .zhHans {
            return (
                "面对面单路听写（DEBUG）",
                "单路语种",
                "我的语言",
                "对方语言",
                "仅影响下一次面对面开始听写。A/B：关闭 = 双路；开启 = 单路。"
            )
        }
        return (
            "Face-to-face single locale (DEBUG)",
            "Single locale",
            "My language",
            "Their language",
            "Applies the next time face-to-face starts listening. A/B: off = dual; on = single."
        )
    }

    /// Per-task diagnostics written to Documents; the share sheet and
    /// `devicectl` can both retrieve the JSON. Nothing is uploaded.
    private var diagnosticsSection: some View {
        Group {
            if environment.diagnostics.hasSession {
                if let diagnosticsFileURL {
                    ShareLink(item: diagnosticsFileURL) {
                        Text(Copy.exportDiagnostics(for: language))
                            .foregroundStyle(Tokens.accentText)
                    }
                    .accessibilityIdentifier("diagnostics-export")
                } else {
                    Button(Copy.exportDiagnostics(for: language)) {
                        diagnosticsFileURL = environment.diagnostics.makeExportFile()
                    }
                    .foregroundStyle(Tokens.accentText)
                    .accessibilityIdentifier("diagnostics-export")
                }
            }
        }
    }
    #endif

    private func redownload() async {
        redownloadError = nil
        isRedownloading = true
        speechProgress = 0
        let meetingLanguages = MeetingRecognition.languages(
            multilingual: environment.preferences.meetingRecognizesMultipleLanguages,
            pinned: environment.preferences.meetingLanguage,
            display: environment.preferences.userLanguage
        )
        var seen = Set<AppLanguage>()
        var languages: [AppLanguage] = []
        for language in [
            environment.preferences.userLanguage,
            environment.preferences.peerLanguage,
            environment.preferences.sourceLanguage,
            environment.preferences.targetLanguage
        ] + meetingLanguages where seen.insert(language).inserted {
            languages.append(language)
        }
        do {
            try await environment.speechModels.prepare(languages: languages) { value in
                Task { @MainActor in
                    speechProgress = value
                }
            }
        } catch {
            redownloadError = DuiyiError.modelsMissing.userMessage(for: language)
        }
        isRedownloading = false
    }
}
