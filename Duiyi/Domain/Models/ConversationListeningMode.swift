import Foundation

/// How face-to-face decides who is speaking.
///
/// Manual is the default: the user taps the side that is talking and the app
/// runs only that side's language. Automatic keeps the language-detection
/// router as the fallback for people who do not want to tap between turns.
enum ConversationListeningMode: String, Codable, Sendable, Equatable, CaseIterable {
    case manual
    case automatic
}
