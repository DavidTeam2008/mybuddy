import Foundation
import Testing
@testable import Duiyi

/// Contract tests for the shared `CaptionProjection` module. The module owns
/// one ordered record per `Utterance.id`; display panes and the full transcript
/// are derived from it.
struct CaptionProjectionModuleTests {
    private func makeUtterance(
        id: UUID = UUID(),
        language: AppLanguage = .english,
        text: String,
        isFinal: Bool = false,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        isRevision: Bool = false
    ) -> Utterance {
        Utterance(
            id: id,
            language: language,
            text: text,
            isFinal: isFinal,
            createdAt: createdAt,
            isRevision: isRevision
        )
    }

    private func makeProjection(
        panes: [SpeakerSide] = [.user],
        historyLimit: Int? = nil
    ) -> CaptionProjection {
        CaptionProjection(
            policy: CaptionDisplayPolicy(panes: panes, historyLimit: historyLimit)
        )
    }

    private func makeEntry(
        id: UUID = UUID(),
        speaker: SpeakerSide,
        source: AppLanguage = .english,
        sourceText: String,
        translatedText: String = "",
        isFinal: Bool = true,
        recordedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> TranscriptEntry {
        TranscriptEntry(
            id: id,
            speaker: speaker,
            source: source,
            sourceText: sourceText,
            translatedText: translatedText,
            isFinal: isFinal,
            recordedAt: recordedAt
        )
    }

    @Test("Same utterance id updates one record and creates no history")
    func sameIDUpdatesOneRecord() {
        var projection = makeProjection()
        let id = UUID()

        let partial = projection.ingest(
            makeUtterance(id: id, text: "The quarterly"),
            pane: .user,
            speaker: .peer
        )
        let grown = projection.ingest(
            makeUtterance(id: id, text: "The quarterly review"),
            pane: .user,
            speaker: .peer
        )
        let final = projection.ingest(
            makeUtterance(id: id, text: "The quarterly review is ready.", isFinal: true),
            pane: .user,
            speaker: .peer
        )

        #expect(partial?.id == id)
        #expect(grown?.sourceText == "The quarterly review")
        #expect(final?.sourceText == "The quarterly review is ready.")
        #expect(final?.phase == .settled)
        #expect(projection.transcript.count == 1)
        #expect(projection.pane(.user).history.isEmpty)
        #expect(projection.pane(.user).live?.id == id)
    }

    @Test("A new utterance id moves the previous live line into history")
    func newIDMovesLiveToHistory() {
        var projection = makeProjection()
        let firstID = UUID()
        let secondID = UUID()

        _ = projection.ingest(
            makeUtterance(id: firstID, text: "Hello there"),
            pane: .user,
            speaker: .peer
        )
        let line = projection.ingest(
            makeUtterance(id: secondID, text: "How are you today", isFinal: true),
            pane: .user,
            speaker: .peer
        )

        #expect(line?.id == secondID)
        #expect(line?.side == .user)
        #expect(line?.phase == .settled)
        #expect(projection.pane(.user).live?.id == secondID)
        #expect(projection.pane(.user).history.map(\.id) == [firstID])
        #expect(projection.transcript.map(\.id) == [firstID, secondID])
    }

    @Test("User and peer panes keep independent live and history lines")
    func panesAreIndependent() {
        var projection = makeProjection(panes: [.user, .peer], historyLimit: 3)
        let firstUser = UUID()
        let peer = UUID()
        let secondUser = UUID()

        _ = projection.ingest(
            makeUtterance(id: firstUser, text: "Hello there"),
            pane: .user,
            speaker: .peer
        )
        _ = projection.ingest(
            makeUtterance(id: peer, text: "你好，很高兴认识你"),
            pane: .peer,
            speaker: .user
        )
        _ = projection.ingest(
            makeUtterance(id: secondUser, text: "How are you today"),
            pane: .user,
            speaker: .peer
        )

        #expect(projection.pane(.user).live?.id == secondUser)
        #expect(projection.pane(.user).history.map(\.id) == [firstUser])
        #expect(projection.pane(.peer).live?.id == peer)
        #expect(projection.pane(.peer).history.isEmpty)
        #expect(projection.transcript.map(\.id) == [firstUser, peer, secondUser])
    }

    @Test("A whitespace-only utterance is ignored")
    func blankUtteranceIsIgnored() {
        var projection = makeProjection()

        let line = projection.ingest(
            makeUtterance(text: " \n\t "),
            pane: .user,
            speaker: .peer
        )

        #expect(line == nil)
        #expect(projection.pane(.user) == .empty)
        #expect(projection.transcript.isEmpty)
        #expect(projection.transcriptCharacterCount == 0)
    }

    @Test("A three-row history limit keeps the live line plus three newest history rows")
    func historyLimitThree() {
        var projection = makeProjection(historyLimit: 3)
        var ids: [UUID] = []

        for index in 0..<6 {
            let id = UUID()
            ids.append(id)
            _ = projection.ingest(
                makeUtterance(id: id, text: "Line number \(index)"),
                pane: .user,
                speaker: .peer
            )
        }

        let pane = projection.pane(.user)
        #expect(pane.live?.id == ids[5])
        #expect(pane.history.map(\.id) == Array(ids[2...4]))
        #expect(projection.transcript.count == 6)
    }

    @Test("A 50-row history limit keeps only the newest 50 history rows")
    func historyLimitFifty() {
        var projection = makeProjection(historyLimit: 50)
        var ids: [UUID] = []

        for index in 0..<52 {
            let id = UUID()
            ids.append(id)
            _ = projection.ingest(
                makeUtterance(id: id, text: "Meeting line \(index)"),
                pane: .user,
                speaker: .peer
            )
        }

        let pane = projection.pane(.user)
        #expect(pane.live?.id == ids[51])
        #expect(pane.history.count == 50)
        #expect(pane.history.first?.id == ids[1])
        #expect(pane.history.last?.id == ids[50])
        #expect(projection.transcript.count == 52)
    }

    @Test("An unlimited history policy keeps every visible row")
    func historyLimitUnlimited() {
        var projection = makeProjection(historyLimit: nil)
        var ids: [UUID] = []

        for index in 0..<52 {
            let id = UUID()
            ids.append(id)
            _ = projection.ingest(
                makeUtterance(id: id, text: "Meeting line \(index)"),
                pane: .user,
                speaker: .peer
            )
        }

        let pane = projection.pane(.user)
        #expect(pane.live?.id == ids[51])
        #expect(pane.history.count == 51)
        #expect(pane.history.first?.id == ids[0])
        #expect(pane.history.last?.id == ids[50])
        #expect(projection.transcript.count == 52)
    }

    @Test("Archiving live moves the line into history and is idempotent")
    func archiveLiveMovesToHistory() {
        var projection = makeProjection()
        let id = UUID()
        _ = projection.ingest(
            makeUtterance(id: id, text: "Hello there", isFinal: true),
            pane: .user,
            speaker: .peer
        )

        projection.archiveLive(pane: .user)

        #expect(projection.pane(.user).live == nil)
        #expect(projection.pane(.user).history.map(\.id) == [id])

        projection.archiveLive(pane: .user)

        #expect(projection.pane(.user).live == nil)
        #expect(projection.pane(.user).history.map(\.id) == [id])
    }

    @Test("A pane outside the display policy renders empty")
    func paneOutsidePolicyIsEmpty() {
        var projection = makeProjection(panes: [.user], historyLimit: nil)
        _ = projection.ingest(
            makeUtterance(text: "你好，很高兴认识你"),
            pane: .user,
            speaker: .peer
        )

        #expect(projection.pane(.peer) == .empty)
        #expect(projection.pane(.user).live != nil)
    }

    @Test("Clearing the display empties the pane but keeps the full transcript")
    func clearDisplayKeepsTranscript() {
        var projection = makeProjection()
        let firstID = UUID()
        let secondID = UUID()
        _ = projection.ingest(
            makeUtterance(id: firstID, text: "Hello there", isFinal: true),
            pane: .user,
            speaker: .peer
        )
        _ = projection.ingest(
            makeUtterance(id: secondID, text: "How are you today", isFinal: true),
            pane: .user,
            speaker: .peer
        )

        projection.clearDisplay()

        #expect(projection.pane(.user) == .empty)
        #expect(projection.transcript.map(\.id) == [firstID, secondID])
        #expect(projection.transcriptCharacterCount == "Hello there".count + "How are you today".count)
    }

    @Test("Re-ingesting the same id after a clear makes the row visible again")
    func ingestAfterClearRevealsSameID() {
        var projection = makeProjection()
        let id = UUID()
        _ = projection.ingest(
            makeUtterance(id: id, text: "Hello there"),
            pane: .user,
            speaker: .peer
        )

        projection.clearDisplay()
        let line = projection.ingest(
            makeUtterance(id: id, text: "Hello there again", isFinal: true),
            pane: .user,
            speaker: .peer
        )

        #expect(line?.id == id)
        #expect(projection.pane(.user).live?.id == id)
        #expect(projection.pane(.user).live?.sourceText == "Hello there again")
        #expect(projection.transcript.count == 1)
    }

    @Test("Speaking hints stay per pane and clear with the display")
    func speakingHintsClearWithDisplay() {
        var projection = makeProjection(panes: [.user, .peer])

        projection.setSpeakingHint("Speaking", pane: .user)

        #expect(projection.pane(.user).speakingHint == "Speaking")
        #expect(projection.pane(.peer).speakingHint == nil)

        projection.clearDisplay()

        #expect(projection.pane(.user).speakingHint == nil)
    }

    @Test("Reset drops records, display, and hints")
    func resetClearsEverything() {
        var projection = makeProjection()
        _ = projection.ingest(
            makeUtterance(text: "Hello there"),
            pane: .user,
            speaker: .peer
        )
        projection.setSpeakingHint("Speaking", pane: .user)

        projection.reset()

        #expect(projection.pane(.user) == .empty)
        #expect(projection.transcript.isEmpty)
        #expect(projection.transcriptCharacterCount == 0)
    }

    @Test("Translating the live line updates the pane and transcript and returns the line")
    func translationUpdatesLiveLine() {
        var projection = makeProjection()
        let id = UUID()
        _ = projection.ingest(
            makeUtterance(id: id, text: "你好，很高兴认识你"),
            pane: .user,
            speaker: .peer
        )

        let line = projection.applyTranslation(
            utteranceID: id,
            text: "Nice to meet you",
            settle: false
        )
        let grown = projection.applyTranslation(
            utteranceID: id,
            text: "Nice to meet you all",
            settle: false
        )
        let shorter = projection.applyTranslation(
            utteranceID: id,
            text: "Nice",
            settle: true
        )

        #expect(line?.id == id)
        #expect(line?.translatedText == "Nice to meet you")
        #expect(line?.phase == .streaming)
        #expect(grown?.translatedText == "Nice to meet you all")
        #expect(shorter?.translatedText == "Nice")
        #expect(shorter?.phase == .settled)
        #expect(projection.pane(.user).live?.translatedText == "Nice")
        #expect(projection.transcript.first?.translatedText == "Nice")
        #expect(projection.transcript.first?.isFinal == true)
    }

    @Test("A final source replaces a longer preview source")
    func finalSourceReplacesLongerPreview() {
        var projection = makeProjection()
        let id = UUID()
        _ = projection.ingest(
            makeUtterance(id: id, text: "They also cause us to bump into each other."),
            pane: .user,
            speaker: .peer
        )

        let final = projection.ingest(
            makeUtterance(id: id, text: "They also cause us.", isFinal: true),
            pane: .user,
            speaker: .peer
        )

        #expect(final?.sourceText == "They also cause us.")
        #expect(projection.transcript.first?.sourceText == "They also cause us.")
        #expect(projection.transcript.first?.isFinal == true)
    }

    @Test("A late preview translation cannot overwrite a final translation")
    func latePreviewDoesNotOverwriteFinalTranslation() {
        var projection = makeProjection()
        let id = UUID()
        _ = projection.ingest(
            makeUtterance(id: id, text: "Hello", isFinal: true),
            pane: .user,
            speaker: .peer
        )
        let final = projection.applyTranslation(
            utteranceID: id,
            text: "你好",
            settle: true
        )
        #expect(final?.translatedText == "你好")

        let late = projection.applyTranslation(
            utteranceID: id,
            text: "你好，很高兴认识你",
            settle: false
        )
        #expect(late == nil)
        #expect(projection.transcript.first?.translatedText == "你好")
    }

    @Test("Translating an in-window history row updates it and returns the row")
    func translationUpdatesHistoryRow() {
        var projection = makeProjection()
        let firstID = UUID()
        let secondID = UUID()
        _ = projection.ingest(
            makeUtterance(id: firstID, text: "Hello there"),
            pane: .user,
            speaker: .peer
        )
        _ = projection.ingest(
            makeUtterance(id: secondID, text: "How are you today"),
            pane: .user,
            speaker: .peer
        )

        let line = projection.applyTranslation(
            utteranceID: firstID,
            text: "你好",
            settle: true
        )

        #expect(line?.id == firstID)
        #expect(line?.phase == .settled)
        #expect(line?.translatedText == "你好")
        #expect(projection.pane(.user).history.first?.translatedText == "你好")
        #expect(projection.transcript.first?.translatedText == "你好")
        #expect(projection.transcript.first?.isFinal == true)
    }

    @Test("Translating an unknown id returns nil and changes nothing")
    func unknownTranslationReturnsNil() {
        var projection = makeProjection()
        _ = projection.ingest(
            makeUtterance(text: "Hello there"),
            pane: .user,
            speaker: .peer
        )

        let line = projection.applyTranslation(
            utteranceID: UUID(),
            text: "你好",
            settle: true
        )

        #expect(line == nil)
        #expect(projection.transcript.count == 1)
        #expect(projection.transcript.first?.translatedText.isEmpty == true)
    }

    @Test("A translation after clear updates the transcript without revealing the row")
    func translationAfterClearUpdatesTranscriptOnly() {
        var projection = makeProjection()
        let id = UUID()
        _ = projection.ingest(
            makeUtterance(id: id, text: "你好，很高兴认识你"),
            pane: .user,
            speaker: .peer
        )

        projection.clearDisplay()
        let line = projection.applyTranslation(
            utteranceID: id,
            text: "Nice to meet you",
            settle: true
        )

        #expect(line == nil)
        #expect(projection.pane(.user) == .empty)
        #expect(projection.transcript.first?.translatedText == "Nice to meet you")
        #expect(projection.transcript.first?.isFinal == true)
    }

    @Test("A translation for a window-evicted row updates the transcript but returns nil")
    func evictedTranslationReturnsNil() {
        var projection = makeProjection(historyLimit: 3)
        var ids: [UUID] = []
        for index in 0..<6 {
            let id = UUID()
            ids.append(id)
            _ = projection.ingest(
                makeUtterance(id: id, text: "Line number \(index)"),
                pane: .user,
                speaker: .peer
            )
        }

        let evicted = projection.applyTranslation(
            utteranceID: ids[0],
            text: "First translation",
            settle: true
        )
        let visible = projection.applyTranslation(
            utteranceID: ids[3],
            text: "Fourth translation",
            settle: true
        )

        #expect(evicted == nil)
        #expect(visible?.id == ids[3])
        #expect(projection.pane(.user).history.first?.id == ids[2])
        #expect(projection.transcript.first?.translatedText == "First translation")
        #expect(projection.transcript[3].translatedText == "Fourth translation")
    }

    @Test("Restore backfills only the pane window and keeps the full transcript")
    func restoreBackfillsWindowOnly() {
        var projection = makeProjection(panes: [.user, .peer], historyLimit: 3)
        _ = projection.ingest(
            makeUtterance(text: "Unrelated live line"),
            pane: .user,
            speaker: .peer
        )
        let entries = (0..<8).map { index in
            makeEntry(
                speaker: index.isMultiple(of: 2) ? .user : .peer,
                sourceText: "Restored line \(index)",
                translatedText: "译文 \(index)",
                isFinal: !index.isMultiple(of: 3),
                recordedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            )
        }

        projection.restore(entries)

        #expect(projection.transcript.map(\.id) == entries.map(\.id))
        #expect(projection.transcript.map(\.speaker) == entries.map(\.speaker))
        #expect(projection.transcript.map(\.recordedAt) == entries.map(\.recordedAt))
        #expect(projection.pane(.user).live == nil)
        #expect(projection.pane(.peer).live == nil)
        // Speaker .peer rows render on the user pane and vice versa.
        #expect(projection.pane(.user).history.map(\.id) == [entries[3].id, entries[5].id, entries[7].id])
        #expect(projection.pane(.peer).history.map(\.id) == [entries[2].id, entries[4].id, entries[6].id])
    }

    @Test("Restoring interpretation entries keeps only the newest 50 display rows")
    func restoreInterpretationKeepsNewestFifty() {
        var projection = makeProjection(panes: [.user], historyLimit: 50)
        let entries = (0..<52).map { index in
            makeEntry(
                speaker: .peer,
                sourceText: "Interpretation line \(index)",
                recordedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            )
        }

        projection.restore(entries)

        let pane = projection.pane(.user)
        #expect(pane.live == nil)
        #expect(pane.history.count == 50)
        #expect(pane.history.first?.id == entries[2].id)
        #expect(pane.history.last?.id == entries[51].id)
        #expect(projection.transcript.count == 52)
    }

    @Test("Restoring meeting entries keeps every row with an unlimited policy")
    func restoreMeetingKeepsAllRows() {
        var projection = makeProjection(panes: [.user], historyLimit: nil)
        let entries = (0..<5).map { index in
            makeEntry(speaker: .user, sourceText: "Meeting line \(index)")
        }

        projection.restore(entries)

        #expect(projection.pane(.user).live == nil)
        #expect(projection.pane(.user).history.map(\.id) == entries.map(\.id))
        #expect(projection.transcript.map(\.id) == entries.map(\.id))
    }

    @Test("Transcript keeps record order, timestamps, and source character count")
    func transcriptOrderAndCharacterCount() {
        var projection = makeProjection()
        let first = makeUtterance(
            text: "Hello there",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let second = makeUtterance(
            language: .zhHans,
            text: "你好，很高兴认识你",
            createdAt: Date(timeIntervalSince1970: 1_700_000_010)
        )
        let third = makeUtterance(
            text: "How are you today",
            createdAt: Date(timeIntervalSince1970: 1_700_000_020)
        )

        for utterance in [first, second, third] {
            _ = projection.ingest(utterance, pane: .user, speaker: .peer)
        }

        let transcript = projection.transcript
        #expect(transcript.map(\.id) == [first.id, second.id, third.id])
        #expect(transcript.map(\.sourceText) == [first.text, second.text, third.text])
        #expect(transcript.map(\.recordedAt) == [first.createdAt, second.createdAt, third.createdAt])
        #expect(
            projection.transcriptCharacterCount
                == first.text.count + second.text.count + third.text.count
        )
    }

    @Test("Pane and speaker are recorded independently")
    func paneAndSpeakerStayIndependent() {
        var projection = makeProjection(panes: [.user, .peer])
        let id = UUID()

        let line = projection.ingest(
            makeUtterance(id: id, language: .zhHans, text: "你好，很高兴认识你"),
            pane: .user,
            speaker: .peer
        )

        #expect(line?.side == .user)
        #expect(projection.pane(.user).live?.side == .user)
        #expect(projection.pane(.peer) == .empty)
        #expect(projection.transcript.first?.speaker == .peer)
        #expect(projection.transcript.first?.source == .zhHans)
    }

    @Test("The same utterance id can change source language and text")
    func sourceChangeOnSameID() {
        var projection = makeProjection()
        let id = UUID()
        _ = projection.ingest(
            makeUtterance(id: id, language: .english, text: "Hello there"),
            pane: .user,
            speaker: .peer
        )

        let changed = projection.ingest(
            makeUtterance(
                id: id,
                language: .zhHans,
                text: "你好，很高兴认识你，今天天气非常好"
            ),
            pane: .user,
            speaker: .peer
        )

        #expect(changed?.source == .zhHans)
        #expect(changed?.sourceText == "你好，很高兴认识你，今天天气非常好")
        #expect(projection.transcript.first?.source == .zhHans)
        #expect(projection.transcript.first?.sourceText == "你好，很高兴认识你，今天天气非常好")
        #expect(projection.transcript.count == 1)
    }

    @Test("A short new final after a long final keeps its own source text")
    func shortNewFinalAfterLongFinalKeepsText() {
        var projection = makeProjection()
        let longID = UUID()
        let longText = "The translation pipeline, the speech session gate, the storage degradation policy, and the accessibility audit in considerable detail."
        _ = projection.ingest(
            makeUtterance(id: longID, text: longText, isFinal: true),
            pane: .user,
            speaker: .peer
        )
        let shortID = UUID()
        _ = projection.ingest(
            makeUtterance(id: shortID, text: "And"),
            pane: .user,
            speaker: .peer
        )
        _ = projection.ingest(
            makeUtterance(id: shortID, text: "And the team"),
            pane: .user,
            speaker: .peer
        )
        let shortText = "And the team agreed to revisit the remaining items next week."
        let applied = projection.ingest(
            makeUtterance(id: shortID, text: shortText, isFinal: true),
            pane: .user,
            speaker: .peer
        )

        #expect(applied?.id == shortID)
        #expect(applied?.sourceText == shortText)
        #expect(projection.pane(.user).history.map(\.id) == [longID])
    }

    @Test("A comparable revision on a new id keeps its own source")
    func comparableRevisionOnNewIDKeepsItsSource() {
        var projection = makeProjection()
        let firstID = UUID()
        let secondID = UUID()
        _ = projection.ingest(
            makeUtterance(
                id: firstID,
                text: "Well we missed a movie called Lucky",
                isFinal: true
            ),
            pane: .user,
            speaker: .peer
        )

        let applied = projection.ingest(
            makeUtterance(
                id: secondID,
                text: "Okay we missed a film called Lucky Day it",
                isFinal: true
            ),
            pane: .user,
            speaker: .peer
        )

        #expect(applied?.id == secondID)
        #expect(applied?.sourceText.contains("Lucky Day") == true)
        #expect(projection.pane(.user).live?.sourceText.contains("Lucky Day") == true)
        #expect(projection.pane(.user).history.map(\.id) == [firstID])
    }

    @Test("A distinct greeting on a new id starts a new line")
    func distinctGreetingWithNewIDStartsNewLine() {
        var projection = makeProjection()
        let firstID = UUID()
        let secondID = UUID()
        _ = projection.ingest(
            makeUtterance(id: firstID, text: "Hi Jack"),
            pane: .user,
            speaker: .peer
        )

        let applied = projection.ingest(
            makeUtterance(id: secondID, text: "Hi Lucy"),
            pane: .user,
            speaker: .peer
        )

        #expect(applied?.id == secondID)
        #expect(projection.pane(.user).history.map(\.id) == [firstID])
        #expect(projection.pane(.user).live?.id == secondID)
    }

    @Test("Re-ingesting the same id keeps its existing translation")
    func ingestKeepsExistingTranslation() {
        var projection = makeProjection()
        let id = UUID()
        _ = projection.ingest(
            makeUtterance(id: id, language: .zhHans, text: "你好，很高兴认识你"),
            pane: .user,
            speaker: .peer
        )
        _ = projection.applyTranslation(
            utteranceID: id,
            text: "Nice to meet you",
            settle: false
        )

        let line = projection.ingest(
            makeUtterance(
                id: id,
                language: .zhHans,
                text: "你好，很高兴认识你，今天天气非常好",
                isFinal: true
            ),
            pane: .user,
            speaker: .peer
        )

        #expect(line?.translatedText == "Nice to meet you")
        #expect(projection.pane(.user).live?.translatedText == "Nice to meet you")
        #expect(projection.transcript.first?.translatedText == "Nice to meet you")
    }

    @Test("A revision of a settled row does not take the live slot from a newer utterance")
    func revisionDoesNotStealLiveSlot() {
        var projection = makeProjection()
        let settledID = UUID()
        let liveID = UUID()
        _ = projection.ingest(
            makeUtterance(id: settledID, text: "They also cause us", isFinal: true),
            pane: .user,
            speaker: .peer
        )
        _ = projection.ingest(
            makeUtterance(id: liveID, text: "And then something else entirely"),
            pane: .user,
            speaker: .peer
        )
        #expect(projection.pane(.user).live?.id == liveID)

        _ = projection.ingest(
            makeUtterance(
                id: settledID,
                text: "They also cause us to bump into each other.",
                isFinal: true,
                isRevision: true
            ),
            pane: .user,
            speaker: .peer
        )

        #expect(projection.pane(.user).live?.id == liveID)
        #expect(
            projection.transcript.first { $0.id == settledID }?.sourceText
                == "They also cause us to bump into each other."
        )
    }

    @Test("A volatile update cannot reopen a settled row")
    func lateVolatileCannotReopenSettledRow() {
        var projection = makeProjection()
        let id = UUID()
        _ = projection.ingest(
            makeUtterance(id: id, text: "They also cause us", isFinal: true),
            pane: .user,
            speaker: .peer
        )

        let late = projection.ingest(
            makeUtterance(id: id, text: "They also cause us to bump into each other."),
            pane: .user,
            speaker: .peer
        )

        #expect(late == nil)
        #expect(projection.transcript.first?.sourceText == "They also cause us")
        #expect(projection.pane(.user).live?.phase == .settled)
    }

    @Test("A revision cannot claim the live slot after the display was cleared")
    func revisionDoesNotClaimClearedLiveSlot() {
        var projection = makeProjection()
        let settledID = UUID()
        let liveID = UUID()
        _ = projection.ingest(
            makeUtterance(id: settledID, text: "They also cause us", isFinal: true),
            pane: .user,
            speaker: .peer
        )
        _ = projection.ingest(
            makeUtterance(id: liveID, text: "And then something else entirely"),
            pane: .user,
            speaker: .peer
        )
        projection.clearDisplay()

        _ = projection.ingest(
            makeUtterance(
                id: settledID,
                text: "They also cause us to bump into each other.",
                isFinal: true,
                isRevision: true
            ),
            pane: .user,
            speaker: .peer
        )
        #expect(projection.pane(.user).live?.id == nil)

        let grown = projection.ingest(
            makeUtterance(id: liveID, text: "And then something else entirely and more"),
            pane: .user,
            speaker: .peer
        )
        #expect(projection.pane(.user).live?.id == liveID)
        #expect(grown?.phase == .streaming)
    }
}
