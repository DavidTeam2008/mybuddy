import SwiftUI
import UIKit

struct ConversationView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppCoordinator.self) private var coordinator
    @Bindable var viewModel: ConversationViewModel

    @State private var isRedownloading = false
    @State private var shouldPrepareTranslation = false
    @State private var speechProgress: Double = 0
    @State private var redownloadError: String?
    @State private var pickingSide: SpeakerSide?
    @State private var lastPreparedPair: Set<AppLanguage> = []
    @State private var confirmNewTask = false
    @State private var confirmEndTask = false

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                CaptionPaneView(
                    viewerLanguage: viewModel.peerLanguage,
                    pane: viewModel.peerPane,
                    fontSize: viewModel.fontSize,
                    isPeer: true,
                    sessionState: viewModel.sessionState,
                    errorText: nil,
                    isPickingLanguage: pickingSide == .peer,
                    onChooseLanguage: { openLanguagePicker(.peer) },
                    onSelectLanguage: { language in
                        applyPeerLanguage(language)
                    },
                    onCancelPicking: { pickingSide = nil },
                    listeningMode: viewModel.listeningMode,
                    activeSpeaker: viewModel.activeSpeaker,
                    turnEnabled: viewModel.hasActiveTask && viewModel.sessionState != .preparing,
                    onSelectTurn: {
                        Task { await viewModel.setActiveSpeaker(.peer) }
                    }
                )
                .rotationEffect(.degrees(180))
                .accessibilityHidden(true)

                ListeningControl(
                    sessionState: viewModel.sessionState,
                    label: viewModel.controlLabel,
                    swapLabel: Copy.swapLanguages(for: viewModel.userLanguage),
                    settingsLabel: Copy.settingsTitle(for: viewModel.userLanguage),
                    settingsHint: Copy.settingsHint(for: viewModel.userLanguage),
                    isEnabled: viewModel.hasActiveTask,
                    onTap: {
                        guard pickingSide == nil else {
                            pickingSide = nil
                            return
                        }
                        guard viewModel.sessionState != .preparing else { return }
                        Task { await viewModel.toggleListening() }
                    },
                    onOpenSettings: {
                        pickingSide = nil
                        withAnimation(.easeOut(duration: 0.22)) {
                            viewModel.isSettingsPresented = true
                        }
                    },
                    onSwap: {
                        pickingSide = nil
                        Task { await viewModel.swapLanguages() }
                    }
                )

                VStack(spacing: 0) {
                    Text(taskStatusText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(viewModel.hasActiveTask ? Tokens.accentText : Tokens.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Tokens.horizontalPadding)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                        .accessibilityLabel(taskStatusText)
                    if viewModel.isNotSaved {
                        NotSavedBanner(
                            language: viewModel.userLanguage,
                            accessibilityIdentifier: "conversation-not-saved-banner"
                        )
                    }
                    if let prompt = viewModel.resumePromptText {
                        Text(prompt)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Tokens.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Tokens.horizontalPadding)
                            .padding(.bottom, 8)
                            .accessibilityIdentifier("conversation-resume-prompt")
                    }
                    CaptionPaneView(
                        viewerLanguage: viewModel.userLanguage,
                        pane: viewModel.userPane,
                        fontSize: viewModel.fontSize,
                        isPeer: false,
                        sessionState: viewModel.sessionState,
                        errorText: viewModel.userErrorText,
                        isPickingLanguage: pickingSide == .user,
                        onChooseLanguage: { openLanguagePicker(.user) },
                        onSelectLanguage: { language in
                            applyUserLanguage(language)
                        },
                        onCancelPicking: { pickingSide = nil },
                        idleOverride: viewModel.hasActiveTask ? nil : Copy.needNewTask(for: viewModel.userLanguage),
                        listeningMode: viewModel.listeningMode,
                        activeSpeaker: viewModel.activeSpeaker,
                        turnEnabled: viewModel.hasActiveTask && viewModel.sessionState != .preparing,
                        onSelectTurn: {
                            Task { await viewModel.setActiveSpeaker(.user) }
                        }
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea()

            if viewModel.isSettingsPresented {
                SettingsSheet(
                    userLanguage: viewModel.userLanguage,
                    peerLanguage: viewModel.peerLanguage,
                    appMode: environment.preferences.appMode,
                    fontSize: viewModel.fontSize,
                    autoStartListening: viewModel.autoStartListening,
                    listeningMode: viewModel.listeningMode,
                    isRedownloading: isRedownloading,
                    speechProgress: speechProgress,
                    translationProgress: translationProgress,
                    redownloadError: redownloadError,
                    onSelectMode: { mode in
                        switchModule(mode)
                    },
                    onSelectUserLanguage: { language in
                        applyUserLanguage(language)
                    },
                    onSelectPeerLanguage: { language in
                        applyPeerLanguage(language)
                    },
                    onSelectFont: viewModel.setFontSize,
                    onToggleAutoStart: viewModel.setAutoStartListening,
                    onSelectListeningMode: { mode in
                        Task { await viewModel.setListeningMode(mode) }
                    },
                    onClear: {
                        Task { await viewModel.clearDisplay() }
                    },
                    onSummarize: {
                        Task { await viewModel.requestSummary() }
                    },
                    canSummarize: viewModel.canSummarize,
                    onRedownload: {
                        Task { await redownloadModels() }
                    },
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
                    language: viewModel.userLanguage,
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

            if showsOpenSettings {
                Button(Copy.openSettings(for: viewModel.userLanguage)) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Tokens.onAccent)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Tokens.listen, in: Capsule())
                .padding(.bottom, 96)
            } else if showsModelRetry, !viewModel.isSettingsPresented, !viewModel.isSummaryPresented, pickingSide == nil {
                Button(Copy.redownloadModels(for: viewModel.userLanguage)) {
                    withAnimation(.easeOut(duration: 0.22)) {
                        viewModel.isSettingsPresented = true
                    }
                    Task { await redownloadModels() }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Tokens.onAccent)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Tokens.listen, in: Capsule())
                .padding(.bottom, 96)
            } else if showsSummarizeButton {
                Button(Copy.summarize(for: viewModel.userLanguage)) {
                    Task { await viewModel.requestSummary() }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Tokens.onAccent)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Tokens.listen, in: Capsule())
                .padding(.bottom, 96)
            }
        }
        .background(Tokens.canvas)
        .moduleToolbar(
            title: Copy.modeFaceToFace(for: viewModel.userLanguage),
            language: viewModel.userLanguage,
            isTaskActive: viewModel.hasActiveTask,
            onHome: { coordinator.popToHome() },
            onHistory: { coordinator.open(.history) },
            onNewTask: { requestNewTask() },
            onEndTask: { confirmEndTask = true }
        )
        .confirmationDialog(
            Copy.replaceTaskConfirm(for: viewModel.userLanguage),
            isPresented: $confirmNewTask,
            titleVisibility: .visible
        ) {
            Button(Copy.newTask(for: viewModel.userLanguage)) {
                Task { await viewModel.beginTask() }
            }
            Button(Copy.cancel(for: viewModel.userLanguage), role: .cancel) {}
        }
        .confirmationDialog(
            Copy.endTaskConfirm(for: viewModel.userLanguage),
            isPresented: $confirmEndTask,
            titleVisibility: .visible
        ) {
            Button(Copy.endTask(for: viewModel.userLanguage)) {
                Task { await finishTask() }
            }
            Button(Copy.cancel(for: viewModel.userLanguage), role: .cancel) {}
        }
        .confirmationDialog(
            Copy.unsavedTaskConfirm(for: viewModel.userLanguage),
            isPresented: $viewModel.isUnsavedTaskPromptPresented,
            titleVisibility: .visible
        ) {
            Button(Copy.exportThenContinue(for: viewModel.userLanguage)) {
                withAnimation(.easeOut(duration: 0.18)) {
                    viewModel.beginExportThenContinue()
                }
            }
            Button(Copy.discardAndStartNew(for: viewModel.userLanguage), role: .destructive) {
                Task { await viewModel.discardUnsavedTaskAndBegin() }
            }
            Button(Copy.cancel(for: viewModel.userLanguage), role: .cancel) {
                viewModel.dismissUnsavedTaskPrompt()
            }
        }
        .overlay {
            TranslationHostView(
                userLanguage: viewModel.userLanguage,
                peerLanguage: viewModel.peerLanguage,
                outboundRevision: viewModel.outboundRevision,
                takeNextOutboundJob: viewModel.takeNextOutboundJob,
                onSuccess: viewModel.fulfill,
                onFailure: viewModel.failTranslation,
                diagnostics: viewModel.translationDiagnostics
            )
            .id("\(viewModel.userLanguage.rawValue)-\(viewModel.peerLanguage.rawValue)")
        }
        .overlay {
            TranslationPrepareHost(
                userLanguage: viewModel.userLanguage,
                peerLanguage: viewModel.peerLanguage,
                shouldPrepare: shouldPrepareTranslation,
                onFinished: handleTranslationPrepared
            )
            .id("prepare-\(viewModel.userLanguage.rawValue)-\(viewModel.peerLanguage.rawValue)")
        }
        .task {
            await viewModel.bootstrap()
        }
        .onAppear {
            applyIdleTimer()
            if lastPreparedPair.isEmpty {
                lastPreparedPair = Set(pairLanguages)
            }
        }
        .onChange(of: pairKey) { _, _ in
            Task { await handlePairChange() }
        }
        .onChange(of: viewModel.keepsScreenAwake) { _, _ in
            applyIdleTimer()
        }
        .onChange(of: viewModel.sessionState) { _, _ in
            applyIdleTimer()
        }
        .onChange(of: viewModel.holdScreenAfterPause) { _, _ in
            applyIdleTimer()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            Task { await viewModel.stop(restoreIdleTimerAfterDelay: false) }
        }
    }

    private var translationProgress: Double {
        if shouldPrepareTranslation { return max(speechProgress, 0.55) }
        return isRedownloading ? 0 : 1
    }

    private var taskStatusText: String {
        TaskStatusText.make(
            hasTask: viewModel.hasActiveTask,
            startedAt: viewModel.taskStartedAt,
            language: viewModel.userLanguage
        )
    }

    private var pairLanguages: [AppLanguage] {
        [viewModel.userLanguage, viewModel.peerLanguage]
    }

    private var pairKey: String {
        "\(viewModel.userLanguage.rawValue)|\(viewModel.peerLanguage.rawValue)"
    }

    private var showsOpenSettings: Bool {
        if case .failed(let error) = viewModel.sessionState {
            return error == .microphoneDenied || error == .speechDenied
        }
        return false
    }

    private var showsModelRetry: Bool {
        if case .failed(let error) = viewModel.sessionState {
            return error == .modelsMissing || error == .languageUnsupported
        }
        return false
    }

    private var showsSummarizeButton: Bool {
        viewModel.sessionState == .paused
            && viewModel.canSummarize
            && !viewModel.isSettingsPresented
            && !viewModel.isSummaryPresented
            && pickingSide == nil
    }

    private func applyIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = viewModel.keepsScreenAwake
    }

    private func openLanguagePicker(_ side: SpeakerSide) {
        viewModel.isSettingsPresented = false
        viewModel.isSummaryPresented = false
        withAnimation(.easeOut(duration: 0.18)) {
            pickingSide = side
        }
    }

    private func applyUserLanguage(_ language: AppLanguage) {
        pickingSide = nil
        Task { await viewModel.setUserLanguage(language) }
    }

    private func applyPeerLanguage(_ language: AppLanguage) {
        pickingSide = nil
        Task { await viewModel.setPeerLanguage(language) }
    }

    private func handlePairChange() async {
        let newSet = Set(pairLanguages)
        let needsAssets = newSet != lastPreparedPair
        let resumeListening = viewModel.sessionState == .listening
        let stayPaused = viewModel.sessionState == .paused
        if resumeListening || needsAssets {
            await viewModel.stop(restoreIdleTimerAfterDelay: false)
        }
        if needsAssets {
            shouldPrepareTranslation = false
            viewModel.enterPreparing()
            let prepared = await prepareSpeechForCurrentPair(reportFailure: true)
            if !prepared {
                return
            }
            lastPreparedPair = newSet
            shouldPrepareTranslation = true
        } else {
            lastPreparedPair = newSet
        }
        if resumeListening {
            await viewModel.start()
        } else if stayPaused {
            viewModel.markPaused()
        } else if viewModel.sessionState == .preparing {
            viewModel.restoreReady()
        }
    }

    private func redownloadModels() async {
        redownloadError = nil
        isRedownloading = true
        speechProgress = 0
        shouldPrepareTranslation = false
        await viewModel.stop()
        let prepared = await prepareSpeechForCurrentPair(reportFailure: false)
        if prepared {
            lastPreparedPair = Set(pairLanguages)
            shouldPrepareTranslation = true
        } else {
            isRedownloading = false
        }
    }

    private func prepareSpeechForCurrentPair(reportFailure: Bool) async -> Bool {
        redownloadError = nil
        speechProgress = 0
        do {
            guard await environment.speechModels.isDeviceCapable(for: pairLanguages) else {
                throw DuiyiError.deviceIncapable
            }
            try await environment.speechModels.prepare(languages: pairLanguages) { value in
                Task { @MainActor in
                    speechProgress = value
                }
            }
            let pair = await environment.translationAvailability.pairStatus(
                from: viewModel.userLanguage,
                to: viewModel.peerLanguage
            )
            if pair == .unsupported {
                throw DuiyiError.languageUnsupported
            }
            return true
        } catch let error as DuiyiError {
            redownloadError = error.userMessage(for: viewModel.userLanguage)
            if reportFailure {
                viewModel.fail(error)
            }
            return false
        } catch {
            redownloadError = DuiyiError.modelsMissing.userMessage(for: viewModel.userLanguage)
            if reportFailure {
                viewModel.fail(.modelsMissing)
            }
            return false
        }
    }

    private func handleTranslationPrepared(_ result: Result<Void, Error>) {
        switch result {
        case .success:
            isRedownloading = false
            shouldPrepareTranslation = false
            speechProgress = 1
            if case .failed = viewModel.sessionState {
                Task { await viewModel.start() }
            }
        case .failure:
            redownloadError = DuiyiError.modelsMissing.userMessage(for: viewModel.userLanguage)
            isRedownloading = false
            shouldPrepareTranslation = false
            if viewModel.sessionState == .preparing {
                viewModel.fail(.modelsMissing)
            }
        }
    }

    private func copySummary() {
        guard let text = viewModel.summary?.text, !text.isEmpty else { return }
        UIPasteboard.general.string = text
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

    private func switchModule(_ mode: AppMode) {
        guard mode != .faceToFace else { return }
        Task {
            await viewModel.stop(restoreIdleTimerAfterDelay: false)
            environment.preferences.appMode = mode
            coordinator.replaceModule(mode.featureID)
        }
    }
}

#Preview("Listening") {
    ConversationPreview.listening
}

#Preview("Ready") {
    ConversationPreview.idle
}

#Preview("Peer speaking") {
    ConversationPreview.peerSpeaking
}

#Preview("User speaking") {
    ConversationPreview.userSpeaking
}

#Preview("Paused") {
    ConversationPreview.paused
}

#Preview("Settings") {
    ConversationPreview.settings
}

#Preview("Switch language") {
    ConversationPreview.switchingLanguage
}

#Preview("Permission failed") {
    ConversationPreview.failed
}
