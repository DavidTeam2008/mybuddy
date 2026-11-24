import Foundation

/// Which panes a projection renders and how much history each pane keeps.
///
/// Face-to-face uses both panes with a short per-side window; interpretation
/// and meeting render a single pane, with 50 rows and an unlimited window
/// respectively (`nil` history limit).
struct CaptionDisplayPolicy: Equatable, Sendable {
    let panes: [SpeakerSide]
    /// Maximum history rows per pane; `nil` keeps every visible row.
    let historyLimit: Int?

    init(panes: [SpeakerSide], historyLimit: Int?) {
        self.panes = panes
        self.historyLimit = historyLimit
    }
}

extension CaptionDisplayPolicy {
    /// Meeting notes render one pane and keep every row; the 2万字 task
    /// counter, not the display window, stops listening.
    static let meeting = CaptionDisplayPolicy(panes: [.user], historyLimit: nil)
}
