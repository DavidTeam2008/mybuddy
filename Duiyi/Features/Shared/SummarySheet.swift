import SwiftUI
import UIKit

struct SummarySheet: View {
    let language: AppLanguage
    let availability: SummaryAvailability
    let isLoading: Bool
    let summary: ConversationSummary?
    let errorText: String?
    var exportTask: TaskSession? = nil
    var exporter: (any ExportSharing)? = nil
    /// Present only for the unsaved-task "export and continue" flow. The
    /// continue button appears once the export file has been prepared.
    var continueAfterExport: (() -> Void)? = nil
    let onCopy: () -> Void
    let onClose: () -> Void

    @State private var isExportReady = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Copy.summaryTitle(for: language))
                .font(.headline)
                .foregroundStyle(Tokens.textPrimary)

            availabilityBanner

            ScrollView {
                Group {
                    if isLoading {
                        Text(Copy.summaryLoading(for: language))
                            .foregroundStyle(Tokens.textSecondary)
                    } else if let errorText {
                        Text(errorText)
                            .foregroundStyle(Tokens.danger)
                    } else if let summary, !summary.text.isEmpty {
                        Text(summary.text)
                            .foregroundStyle(Tokens.textPrimary)
                    }
                }
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)

            if let exportTask, let exporter {
                ExportShareButton(
                    task: exportSession(exportTask),
                    language: language,
                    exporter: exporter,
                    onPrepared: { isExportReady = $0 != nil }
                )
            }

            HStack {
                if let summary, !summary.text.isEmpty, !isLoading {
                    Button(Copy.copySummary(for: language), action: onCopy)
                        .foregroundStyle(Tokens.textPrimary)
                }
                Spacer()
                if let continueAfterExport, isExportReady {
                    Button(Copy.continueToNewTask(for: language), action: continueAfterExport)
                        .fontWeight(.semibold)
                        .foregroundStyle(Tokens.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Tokens.sheetChip, in: Capsule())
                        .accessibilityIdentifier("summary-continue")
                }
                Button(Copy.done(for: language), action: onClose)
                    .fontWeight(.semibold)
                    .foregroundStyle(Tokens.onAccent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Tokens.listen, in: Capsule())
            }
        }
        .padding(18)
        .background(Tokens.sheet, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 24)
    }

    private var availabilityBanner: some View {
        let text: String
        if summary?.usedAppleIntelligence == true {
            text = Copy.appleIntelligenceGenerated(for: language)
        } else {
            text = Copy.summaryAvailabilityMessage(availability, for: language)
        }
        return Text(text)
            .font(.footnote)
            .foregroundStyle(summary?.usedAppleIntelligence == true ? Tokens.intelligenceText : Tokens.warningText)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                summary?.usedAppleIntelligence == true
                    ? Tokens.intelligenceBackground
                    : Tokens.warningBackground,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
    }

    private func exportSession(_ task: TaskSession) -> TaskSession {
        var copy = task
        copy.summary = summary ?? task.summary
        return copy
    }
}
