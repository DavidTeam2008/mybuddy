import SwiftUI

/// The one storage status surface shared by Home, History and Task Detail.
/// All three read `TaskStoreV2.availability` from the same store instance; a
/// read that fails while the store is open also surfaces through this banner.
struct StorageUnavailableBanner: View {
    let language: AppLanguage
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(Copy.storageUnavailable(for: language))
                .font(.footnote)
                .foregroundStyle(Color(hex: 0xF0D9B0))
            Spacer(minLength: 8)
            Button(Copy.retry(for: language), action: onRetry)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Tokens.listen)
                .accessibilityIdentifier("storage-retry")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(hex: 0x2A2420),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("storage-banner")
    }
}

extension TaskStoreAvailability {
    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}
