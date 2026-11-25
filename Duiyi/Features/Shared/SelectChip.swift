import SwiftUI

/// Full-width selectable chip shared by the settings sheets.
struct SelectChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Tokens.onAccent : Tokens.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    isSelected ? Tokens.listen : Tokens.sheetChip,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .minHitTarget()
        }
        .buttonStyle(.plain)
    }
}
