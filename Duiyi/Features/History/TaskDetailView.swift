import SwiftUI
import UIKit

struct TaskDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppCoordinator.self) private var coordinator

    let taskID: UUID
    /// Applied before navigating away so history owns the deleted row's removal.
    var onDeleted: (UUID) -> Void = { _ in }

    @State private var viewModel: TaskDetailViewModel?
    @State private var translateJob: TranslationJob?
    @State private var pendingTranslate: [TranscriptEntry] = []

    private var language: AppLanguage { environment.preferences.userLanguage }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let viewModel {
                if viewModel.showsStorageBanner {
                    StorageUnavailableBanner(language: language) {
                        Task { await viewModel.retry() }
                    }
                    .padding(.horizontal, Tokens.horizontalPadding)
                    .padding(.top, 8)
                }

                if let task = viewModel.task {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(task.title)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Tokens.textPrimary)
                            Text(TaskFormatting.historyMeta(task: task, language: language))
                                .font(.footnote)
                                .foregroundStyle(Tokens.textSecondary)

                            availabilityBanner

                            if let summary = task.summary, !summary.text.isEmpty {
                                Text(summary.text)
                                    .font(.body)
                                    .foregroundStyle(Tokens.textPrimary)
                            } else if let summaryError = viewModel.summaryError {
                                Text(summaryError)
                                    .font(.body)
                                    .foregroundStyle(Tokens.danger)
                            } else if viewModel.isSummarizing {
                                Text(Copy.summaryLoading(for: language))
                                    .foregroundStyle(Tokens.textSecondary)
                            }

                            if viewModel.summarySaveFailure != nil {
                                Text(Copy.summarySaveFailed(for: language))
                                    .font(.footnote)
                                    .foregroundStyle(Tokens.danger)
                                    .accessibilityIdentifier("detail-summary-save-error")
                            }

                            if viewModel.translationSaveFailure != nil {
                                Text(Copy.translationSaveFailed(for: language))
                                    .font(.footnote)
                                    .foregroundStyle(Tokens.danger)
                                    .accessibilityIdentifier("detail-translation-save-error")
                            }

                            if let reason = viewModel.deleteFailure {
                                Text(Copy.deleteFailed(reason: reason, for: language))
                                    .font(.footnote)
                                    .foregroundStyle(Tokens.danger)
                                    .accessibilityIdentifier("detail-delete-error")
                            }

                            Text(Copy.transcriptSection(for: language))
                                .font(.footnote)
                                .foregroundStyle(Tokens.textSecondary)
                            ForEach(task.entries) { entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        if task.feature == .meeting {
                                            Text(entry.source.badge)
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(Tokens.languageBadge(entry.source))
                                        }
                                        Text(entry.sourceText)
                                            .foregroundStyle(Tokens.textPrimary)
                                    }
                                    if !entry.translatedText.isEmpty {
                                        Text(entry.translatedText)
                                            .foregroundStyle(Tokens.textSecondary)
                                    }
                                }
                                .font(.body)
                            }

                            if canSummarize {
                                Button(Copy.summarize(for: language)) {
                                    Task { await viewModel.summarize(language: language) }
                                }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Tokens.onAccent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Tokens.listen, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }

                            if task.feature == .meeting, needsTranslation(task) {
                                Button(Copy.translateToMine(for: language)) {
                                    startTranslation(for: task)
                                }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Tokens.accentText)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                            }

                            ExportShareButton(task: task, language: language, exporter: environment.exporter)

                            Button(Copy.delete(for: language)) {
                                viewModel.requestDelete()
                            }
                            .accessibilityIdentifier("detail-delete")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Tokens.danger)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .padding(.horizontal, Tokens.horizontalPadding)
                        .padding(.bottom, 32)
                    }
                } else {
                    Spacer()
                }
            } else {
                Spacer()
            }
        }
        .background(Tokens.canvas.ignoresSafeArea())
        .detailToolbar(
            title: Copy.recordTitle(for: language),
            language: language,
            onHome: { coordinator.popToHome() }
        )
        .overlay {
            if let job = translateJob {
                OneWayTranslationHostView(
                    sourceLanguage: job.source,
                    targetLanguage: language,
                    job: job,
                    onSuccess: handleTranslated,
                    onFailure: { _, _ in advanceTranslation() }
                )
                .id("\(job.source.rawValue)-\(job.utteranceID)")
            }
        }
        .task {
            if viewModel?.taskID != taskID {
                viewModel = TaskDetailViewModel(
                    taskID: taskID,
                    store: environment.taskStore,
                    summarizer: environment.summarizer
                )
            }
            await viewModel?.load()
        }
        .confirmationDialog(
            Copy.deleteTaskConfirm(for: language),
            isPresented: Binding(
                get: { viewModel?.pendingDelete == true },
                set: { presented in
                    if !presented { viewModel?.cancelDelete() }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(Copy.delete(for: language), role: .destructive) {
                Task {
                    if await viewModel?.confirmDelete() == true {
                        onDeleted(taskID)
                        coordinator.returnToHistory()
                    }
                }
            }
            Button(Copy.cancel(for: language), role: .cancel) {
                viewModel?.cancelDelete()
            }
        }
    }

    private var canSummarize: Bool {
        viewModel?.task?.hasTranscript == true && viewModel?.isSummarizing == false
    }

    private func needsTranslation(_ task: TaskSession) -> Bool {
        task.entries.contains {
            $0.source != language
                && $0.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var availabilityBanner: some View {
        let used = viewModel?.task?.summary?.usedAppleIntelligence == true
        let text = used
            ? Copy.appleIntelligenceGenerated(for: language)
            : Copy.summaryAvailabilityMessage(
                viewModel?.summaryAvailability ?? .unavailable,
                for: language
            )
        return Text(text)
            .font(.footnote)
            .foregroundStyle(used ? Tokens.intelligenceText : Tokens.warningText)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                used ? Tokens.intelligenceBackground : Tokens.warningBackground,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
    }

    private func startTranslation(for task: TaskSession) {
        pendingTranslate = task.entries.filter {
            $0.source != language
                && $0.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        advanceTranslation()
    }

    private func advanceTranslation() {
        guard let next = pendingTranslate.first else {
            translateJob = nil
            return
        }
        pendingTranslate.removeFirst()
        translateJob = TranslationJob(
            utteranceID: next.id,
            source: next.source,
            target: language,
            text: next.sourceText,
            isFinal: true
        )
    }

    private func handleTranslated(job: TranslationJob, text: String) {
        Task {
            await viewModel?.applyTranslation(entryID: job.utteranceID, text: text)
        }
        advanceTranslation()
    }
}
