import CoreGraphics
import Foundation

enum ConversationLayout {
    static let midBarHeight: CGFloat = 72
    static let micSize: CGFloat = 64
    static let micHitSize: CGFloat = 88
    static let horizontalPadding: CGFloat = 22
    static let translationDebounceMilliseconds: UInt64 = 90
    static let firstTranslationDebounceMilliseconds: UInt64 = 40
    static let liveFontCap: CGFloat = 32
    static let silenceCommitMilliseconds: UInt64 = 1100
    static let idleRestoreSeconds: Double = 30
    /// Each face-to-face pane keeps the live line plus at most this many
    /// history lines; older lines live only in the task transcript.
    static let paneHistoryLimit = 3
}
