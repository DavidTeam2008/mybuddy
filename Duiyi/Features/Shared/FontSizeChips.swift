import SwiftUI

/// Standard / larger / largest selector shared by the settings sheets.
struct FontSizeChips: View {
    let language: AppLanguage
    let selection: CaptionFontSize
    let onSelect: (CaptionFontSize) -> Void

    var body: some View {
        HStack(spacing: 8) {
            SelectChip(
                title: Copy.fontStandard(for: language),
                isSelected: selection == .standard
            ) {
                onSelect(.standard)
            }
            SelectChip(
                title: Copy.fontLarger(for: language),
                isSelected: selection == .larger
            ) {
                onSelect(.larger)
            }
            SelectChip(
                title: Copy.fontLargest(for: language),
                isSelected: selection == .largest
            ) {
                onSelect(.largest)
            }
        }
    }
}
