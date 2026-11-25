import SwiftUI

/// Toolbar glyph with a ≥44 pt hit target. The system toolbar draws the
/// Liquid Glass surface; this view only sizes the interactive content.
struct ToolbarGlyph: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .frame(width: Tokens.minHitTarget, height: Tokens.minHitTarget)
            .contentShape(Rectangle())
    }
}
