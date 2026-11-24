import Foundation
import Testing
@testable import Duiyi

/// Shared caption projection behavior used by Conversation, Interpretation,
/// and Meeting. These tests drive the same `PaneState` seam that the speech
/// stream feeds through each ViewModel.
@MainActor
struct CaptionProjectionTests {
    private func line(
        id: UUID = UUID(),
        text: String,
        translatedText: String = "",
        phase: CaptionLine.Phase = .settled
    ) -> CaptionLine {
        CaptionLine(
            id: id,
            side: .user,
            source: .english,
            sourceText: text,
            translatedText: translatedText,
            phase: phase
        )
    }

    @Test("Same utterance partials merge in place")
    func sameUtterancePartialsMerge() {
        var pane = PaneState()
        let id = UUID()

        _ = pane.applyLive(line(id: id, text: "The quarterly", phase: .streaming))
        _ = pane.applyLive(line(id: id, text: "The quarterly review", phase: .streaming))
        let applied = pane.applyLive(line(id: id, text: "The quarterly review is ready.", phase: .settled))

        #expect(applied.id == id)
        #expect(applied.sourceText == "The quarterly review is ready.")
        #expect(pane.history.isEmpty)
    }

    @Test("A short new final after a long final keeps its own source text")
    func shortNewFinalAfterLongFinalKeepsText() {
        var pane = PaneState()
        let longID = UUID()
        let longText = "The translation pipeline, the speech session gate, the storage degradation policy, and the accessibility audit in considerable detail."
        _ = pane.applyLive(line(id: longID, text: longText))

        let shortID = UUID()
        _ = pane.applyLive(line(id: shortID, text: "And", phase: .streaming))
        _ = pane.applyLive(line(id: shortID, text: "And the team", phase: .streaming))
        let shortText = "And the team agreed to revisit the remaining items next week."
        let applied = pane.applyLive(line(id: shortID, text: shortText))

        #expect(applied.id == shortID)
        #expect(applied.sourceText == shortText)
        #expect(pane.history.last?.id == longID)
    }

    @Test("A comparable cross-id revision keeps the new source")
    func comparableRevisionKeepsNewSource() {
        var pane = PaneState()
        _ = pane.applyLive(line(text: "Well we missed a movie called Lucky"))
        let applied = pane.applyLive(line(text: "Okay we missed a film called Lucky Day it"))

        #expect(applied.sourceText.contains("Lucky Day"))
        #expect(pane.live?.sourceText.contains("Lucky Day") == true)
    }

    @Test("A distinct greeting starts a new caption")
    func distinctGreetingStartsNewCaption() {
        var pane = PaneState()
        let first = line(text: "Hi Jack")
        _ = pane.applyLive(first)
        let second = line(text: "Hi Lucy")
        let applied = pane.applyLive(second)

        #expect(applied.id == second.id)
        #expect(pane.history.count == 1)
        #expect(pane.history.first?.id == first.id)
    }
}
