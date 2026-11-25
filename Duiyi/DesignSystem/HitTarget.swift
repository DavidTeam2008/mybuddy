import SwiftUI

extension View {
    /// Gives a control's label at least Apple's 44 pt hit target without
    /// changing the size of the visuals drawn inside it.
    func minHitTarget() -> some View {
        frame(minWidth: Tokens.minHitTarget, minHeight: Tokens.minHitTarget)
            .contentShape(Rectangle())
    }
}
