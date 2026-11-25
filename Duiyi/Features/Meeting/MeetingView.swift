import SwiftUI
import UIKit

struct MeetingView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppCoordinator.self) private var coordinator
    @Bindable var viewModel: MeetingViewModel

    @State private var isRedownloading = false
    @State private var speechProgress: Double = 0
    @State private var redownloadError: String?
    @State private var confirmNewTask = false
    @State private var confirmEndTask = false
    @State private var lastPreparedKey = ""

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                Text(taskStatusText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(viewModel.hasActiveTask ? Tokens.accentText : Tokens.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Tokens.horizontalPadding)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    .accessibilityLabel(taskStatusText)

                languageChip
                    .padding(.horizontal, Tokens.horizontalPadding)
                    .padding(.bottom, 8)

                if viewModel.isNotSaved {
                    NotSavedBanner(
                        language: viewModel.displayLanguage,
                        accessibilityIdentifier: "meeting-not-saved-banner"
                    )
                }

                if let prompt = viewModel.resumePromptText {
                    Text(prompt)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Tokens.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Tokens.horizontalPadding)
                        .padding(.bottom, 8)
                        .accessibilityIdentifier("meeting-resume-prompt")
                }

                transcriptColumn

                ListeningControl(
                    sessionState: viewModel.sessionState,
                    label: viewModel.controlLabel,
                    swapLabel: Copy.meetingLanguage(for: viewModel.displayLanguage),
                    settingsLabel: Copy.settingsTitle(for: viewModel.displayLanguage),
                    settingsHint: Copy.settingsHint(for: viewModel.displayLanguage),
                    isEnabled: viewModel.hasActiveTask && !viewModel.isLengthLimited,
                    showsSwap: false,
                    onTap: {
                        guard viewModel.sessionState != .preparing else { return }
                        Task { await viewModel.toggleListening() }
                    },
                    onOpenSettings: {
                        withAnimation(.easeOut(duration: 0.22)) {
                            viewModel.isSettingsPresented = true
                        }
                    },
                    onSwap: {}
                )
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if viewModel.isSettingsPresented {
                MeetingSettingsSheet(
                    language: viewModel.displayLanguage,
                    recognizesMultipleLanguages: viewModel.recognizesMultipleLanguages,
                    sourceLanguage: viewModel.sourceLanguage,
                    fontSize: viewModel.fontSize,
                    isRedownloading: isRedownloading,
                    speechProgress: speechProgress,
                    redownloadError: redownloadError,
                    canSummarize: viewModel.canSummarize,
                    onSelectMultilingual: { enabled in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            viewModel.setRecognizesMultipleLanguages(enabled)
                        }
                    },
                    onSelectLanguage: { language in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            viewModel.setSourceLanguage(language)
                        }
                    },
                    onSelectFont: viewModel.setFontSize,
                    onClear: { Task { await viewModel.clearDisplay() } },
                    onSummarize: { Task { await viewModel.requestSummary() } },
                    onRedownload: { Task { await redownloadModels() } },
                    onDone: {
                        withAnimation(.easeOut(duration: 0.18)) {
                            viewModel.isSettingsPresented = false
                        }
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if viewModel.isSummaryPresented {
                SummarySheet(
                    language: viewModel.displayLanguage,
                    availability: viewModel.summaryAvailability,
                    isLoading: viewModel.isSummarizing,
                    summary: viewModel.summary,
                    errorText: viewModel.summaryError,
                    exportTask: viewModel.exportableSession,
                    exporter: environment.exporter,
                    continueAfterExport: viewModel.isExportThenContinuePending
                        ? { Task { await viewModel.continueAfterExport() } }
                        : nil,
                    onCopy: copySummary,
                    onClose: {
                        withAnimation(.easeOut(duration: 0.18)) {
                            viewModel.dismissSummary()
                        }
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Tokens.userPane.ignoresSafeArea())
        .moduleToolbar(
            title: Copy.modeMeeting(for: viewModel.displayLanguage),
            language: viewModel.displayLanguage,
            isTaskActive: viewModel.hasActiveTask,
            onHome: { coordinator.popToHome() },
            onHistory: { coordinator.open(.history) },
            onNewTask: { requestNewTask() },
            onEndTask: { confirmEndTask = true }
        )
        .task { await viewModel.bootstrap() }
        .onAppear {
            applyIdleTimer()
            if lastPreparedKey.isEmpty {
                lastPreparedKey = viewModel.recognitionKey
            }
        }
        .onChange(of: viewModel.recognitionKey) { _, _ in
            Task { await handleRecognitionChange() }
        }
        .onChange(of: viewModel.keepsScreenAwake) { _, _ in applyIdleTimer() }
        .onChange(of: viewModel.sessionState) { _, _ in applyIdleTimer() }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            Task { await viewModel.stop(restoreIdleTimerAfterDelay: false) }
        }
        .confirmationDialog(
            Copy.replaceTaskConfirm(for: viewModel.displayLanguage),
            isPresented: $confirmNewTask,
            titleVisibility: .visible
        ) {
            Button(Copy.newTask(for: viewModel.displayLanguage)) {
                Task { await viewModel.beginTask() }
            }
            Button(Copy.cancel(for: viewModel.displayLanguage), role: .cancel) {}
        }
        .confirmationDialog(
            Copy.endTaskConfirm(for: viewModel.displayLanguage),
            isPresented: $confirmEndTask,
            titleVisibility: .visible
        ) {
            Button(Copy.endTask(for: viewModel.displayLanguage)) {
                Task { await finishTask() }
            }
            Button(Copy.cancel(for: viewModel.displayLanguage), role: .cancel) {}
        }
        .confirmationDialog(
            Copy.unsavedTaskConfirm(for: viewModel.displayLanguage),
            isPresented: $viewModel.isUnsavedTaskPromptPresented,
            titleVisibility: .visible
        ) {
            Button(Copy.exportThenContinue(for: viewModel.displayLanguage)) {
                withAnimation(.easeOut(duration: 0.18)) {
                    viewModel.beginExportThenContinue()
                }
            }
            Button(Copy.discardAndStartNew(for: viewModel.displayLanguage), role: .destructive) {
                Task { await viewModel.discardUnsavedTaskAndBegin() }
            }
            Button(Copy.cancel(for: viewModel.displayLanguage), role: .cancel) {
                viewModel.dismissUnsavedTaskPrompt()
            }
        }
    }

    private var languageChip: some View {
        Button {
            withAnimation(.easeOut(duration: 0.22)) {
                viewModel.isSettingsPresented = true
            }
        } label: {
            HStack {
                Text(recognitionLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(recognitionColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .overlay(
                        Capsule().stroke(recognitionColor, lineWidth: 1)
                    )
                Text(Copy.transcriptSection(for: viewModel.displayLanguage))
                    .font(.caption)
                    .foregroundStyle(Tokens.textSecondary)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recognitionLabel)
        .accessibilityHint(Copy.meetingRecognitionMode(for: viewModel.displayLanguage))
    }

    private var recognitionLabel: String {
        viewModel.recognizesMultipleLanguages
            ? Copy.meetingMultilingual(for: viewModel.displayLanguage)
            : viewModel.sourceLanguage.nativeName
    }

    private var recognitionColor: Color {
        viewModel.recognizesMultipleLanguages
            ? Tokens.featureMeeting
            : Tokens.languageBadge(viewModel.sourceLanguage)
    }

    private var transcriptColumn: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(viewModel.pane.history) { line in
                        transcriptLine(text: line.sourceText, language: line.source, live: false)
                    }
                    transcriptLine(
                        text: liveText,
                        language: viewModel.pane.live?.source,
                        live: true
                    )
                    .id("live")
                }
                .padding(.horizontal, Tokens.horizontalPadding)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            .onChange(of: viewModel.pane.live?.sourceText) { _, _ in
                proxy.scrollTo("live", anchor: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var liveText: String {
        if let errorText = viewModel.errorText {
            return errorText
        }
        if let live = viewModel.pane.live, !live.sourceText.isEmpty {
            return live.sourceText
        }
        if let hint = viewModel.pane.speakingHint {
            return hint
        }
        if viewModel.hasActiveTask {
            return viewModel.recognizesMultipleLanguages
                ? Copy.meetingMultilingualIdle(for: viewModel.displayLanguage)
                : Copy.interpretationIdle(for: viewModel.displayLanguage)
        }
        return Copy.needNewTask(for: viewModel.displayLanguage)
    }

    @ViewBuilder
    private func transcriptLine(text: String, language: AppLanguage?, live: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let language, showsLanguageBadge {
                Text(language.badge)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Tokens.languageBadge(language))
                    .accessibilityLabel(language.nativeName)
            }
            Text(text)
                .font(live
                    ? CaptionTypography.liveFont(size: viewModel.fontSize, settled: liveIsSettled)
                    : CaptionTypography.previousFont(size: viewModel.fontSize))
                .foregroundStyle(live && !liveIsSecondary ? Tokens.textPrimary : Tokens.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var taskStatusText: String {
        TaskStatusText.make(
            hasTask: viewModel.hasActiveTask,
            startedAt: viewModel.taskStartedAt,
            language: viewModel.displayLanguage
        )
    }

    private var showsLanguageBadge: Bool {
        viewModel.recognizesMultipleLanguages || viewModel.pane.history.contains { $0.source != viewModel.sourceLanguage }
    }

    private var liveIsSettled: Bool {
        viewModel.errorText != nil || viewModel.pane.live?.phase == .settled
    }

    private var liveIsSecondary: Bool {
        if viewModel.errorText != nil { return false }
        if viewModel.pane.speakingHint != nil { return true }
        return viewModel.pane.live?.phase != .settled
    }

    private func requestNewTask() {
        if viewModel.hasActiveTask {
            confirmNewTask = true
        } else {
            Task { await viewModel.beginTask() }
        }
    }

    private func finishTask() async {
        if let session = await viewModel.endTask() {
            coordinator.showEndedTask(session.id)
        }
    }

    private func applyIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = viewModel.keepsScreenAwake
    }

    private func handleRecognitionChange() async {
        let needsAssets = viewModel.recognitionKey != lastPreparedKey
        await viewModel.stop(restoreIdleTimerAfterDelay: false)
        if needsAssets {
            viewModel.enterPreparing()
            await redownloadModels()
            if viewModel.sessionState == .preparing {
                viewModel.restoreReady()
            }
        } else if viewModel.sessionState == .preparing {
            viewModel.restoreReady()
        }
    }

    private func redownloadModels() async {
        redownloadError = nil
        isRedownloading = true
        speechProgress = 0
        await viewModel.stop(restoreIdleTimerAfterDelay: false)
        do {
            guard await environment.speechModels.isDeviceCapable(for: viewModel.recognitionLanguages) else {
                throw DuiyiError.deviceIncapable
            }
            try await environment.speechModels.prepare(languages: viewModel.recognitionLanguages) { value in
                Task { @MainActor in
                    speechProgress = value
                }
            }
            lastPreparedKey = viewModel.recognitionKey
        } catch let error as DuiyiError {
            redownloadError = error.userMessage(for: viewModel.displayLanguage)
            viewModel.fail(error)
        } catch {
            redownloadError = DuiyiError.modelsMissing.userMessage(for: viewModel.displayLanguage)
        }
        isRedownloading = false
    }

    private func copySummary() {
        guard let text = viewModel.summary?.text, !text.isEmpty else { return }
        UIPasteboard.general.string = text
    }
}

#Preview("Meeting") {
    MeetingPreview.idle
}

@MainActor
enum MeetingPreview {
    static var idle: some View {
        let preferences = PreferencesStore(defaults: UserDefaults(suiteName: "duiyi.meet.preview") ?? .standard)
        preferences.meetingLanguage = .zhHans
        let store = InMemoryTaskStore()
        let speech = PreviewSpeechEngine()
        let environment = AppEnvironment(
            preferences: preferences,
            speechEngine: speech,
            taskStore: store
        )
        let viewModel = MeetingViewModel(
            speech: speech,
            permissions: PreviewPermissions(),
            preferences: preferences,
            summarizer: PreviewSummarizer(),
            taskStore: store
        )
        viewModel.skipsBootstrap = true
        viewModel.sessionState = .ready
        return MeetingView(viewModel: viewModel)
            .environment(environment)
            .environment(AppCoordinator())
    }
}
