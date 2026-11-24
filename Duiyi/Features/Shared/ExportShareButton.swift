import SwiftUI

struct ExportShareButton: View {
    let task: TaskSession
    let language: AppLanguage
    let exporter: any ExportSharing
    var title: String? = nil
    /// Reports the prepared share file, or `nil` when preparation failed.
    var onPrepared: ((URL?) -> Void)? = nil

    @State private var fileURL: URL?

    var body: some View {
        Group {
            if let fileURL {
                ShareLink(item: fileURL) {
                    label
                }
            } else {
                Button(action: prepare) {
                    label
                }
            }
        }
        .buttonStyle(.plain)
        .task(id: task.id) {
            prepare()
        }
        .onChange(of: task) {
            prepare()
        }
        .onChange(of: language) {
            prepare()
        }
    }

    private var label: some View {
        Text(title ?? Copy.exportShare(for: language))
            .font(.subheadline.weight(.bold))
            .foregroundStyle(Tokens.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Tokens.listen, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func prepare() {
        let prepared = try? exporter.makeTranscriptFile(task: task, language: language)
        fileURL = prepared
        onPrepared?(prepared)
    }
}
