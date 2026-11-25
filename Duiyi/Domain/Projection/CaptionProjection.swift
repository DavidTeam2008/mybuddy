import Foundation

/// Single ordered caption/transcript projection shared by all three modules.
///
/// One record per `Utterance.id`; the on-screen pane window and the full
/// transcript are both derived from that store. Display-only clearing moves a
/// display generation forward instead of deleting records.
struct CaptionProjection: Sendable {
    private struct Record {
        var id: UUID
        var pane: SpeakerSide
        var speaker: SpeakerSide
        var source: AppLanguage
        var sourceText: String
        var translatedText: String
        var isFinal: Bool
        var createdAt: Date
        var updatedAt: Date
        /// The display generation this record joined; a clear moves the
        /// projection's generation forward and hides older records.
        var displayGeneration: Int
    }

    private let policy: CaptionDisplayPolicy
    private var records: [Record] = []
    private var index: [UUID: Int] = [:]
    private var liveIDByPane: [SpeakerSide: UUID] = [:]
    private var hints: [SpeakerSide: String] = [:]
    private var generation = 0

    init(policy: CaptionDisplayPolicy) {
        self.policy = policy
    }

    /// Ingests one utterance update. A new id appends a record and takes over
    /// the pane's live line; an existing id updates that same record in place
    /// and makes it live again, so a partial arriving after a display clear
    /// re-appears as the current caption and the returned line carries the
    /// `isFinal`-derived phase.
    @discardableResult
    mutating func ingest(
        _ utterance: Utterance,
        pane: SpeakerSide,
        speaker: SpeakerSide
    ) -> CaptionLine? {
        let text = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let existingIndex = index[utterance.id] {
            var record = records[existingIndex]
            // Once settled, a row only accepts a newer final; a late volatile
            // must not reopen or downgrade it.
            guard !(record.isFinal && !utterance.isFinal) else { return nil }
            record.source = utterance.language
            record.sourceText = SpokenText.preferredSource(record.sourceText, text)
            record.isFinal = utterance.isFinal
            record.updatedAt = max(record.updatedAt, utterance.createdAt)
            record.displayGeneration = generation
            records[existingIndex] = record
            // Only the newest row for the pane owns the live slot; a late
            // revision of an older row must not take it from the newer
            // utterance already in progress (including after a clear).
            let isNewestForPane = records.last(where: { $0.pane == record.pane })?.id == record.id
            if liveIDByPane[record.pane] == record.id || isNewestForPane {
                liveIDByPane[record.pane] = record.id
            }
            return line(for: record)
        }

        let record = Record(
            id: utterance.id,
            pane: pane,
            speaker: speaker,
            source: utterance.language,
            sourceText: text,
            translatedText: "",
            isFinal: utterance.isFinal,
            createdAt: utterance.createdAt,
            updatedAt: utterance.createdAt,
            displayGeneration: generation
        )
        index[utterance.id] = records.count
        records.append(record)
        liveIDByPane[pane] = utterance.id
        return line(for: record)
    }

    /// Updates the record's translation and returns the canonical line only
    /// while that record is in the pane's display window. A row hidden by a
    /// clear or evicted by the history limit still updates the record and the
    /// transcript, but returns nil so callers (notably interpretation TTS)
    /// never act on a row the user cannot see.
    @discardableResult
    mutating func applyTranslation(
        utteranceID: UUID,
        text: String,
        settle: Bool
    ) -> CaptionLine? {
        guard let recordIndex = index[utteranceID] else { return nil }
        var record = records[recordIndex]
        record.translatedText = SpokenText.preferredTranslation(record.translatedText, text)
        if settle {
            record.isFinal = true
        }
        record.updatedAt = .now
        records[recordIndex] = record
        guard isInDisplayWindow(record) else { return nil }
        return line(for: record)
    }

    mutating func archiveLive(pane: SpeakerSide) {
        liveIDByPane[pane] = nil
    }

    /// Display-only clear: moves the display generation forward instead of
    /// deleting records, so the transcript stays full. A later `ingest` for the
    /// same id re-joins the current generation.
    mutating func clearDisplay() {
        generation += 1
        liveIDByPane.removeAll()
        hints.removeAll()
    }

    mutating func reset() {
        records.removeAll()
        index.removeAll()
        liveIDByPane.removeAll()
        hints.removeAll()
        generation = 0
    }

    /// Rebuilds the record store from persisted transcript entries and derives
    /// the display window from it. Restored rows are history, never live.
    mutating func restore(_ entries: [TranscriptEntry]) {
        records.removeAll()
        index.removeAll()
        liveIDByPane.removeAll()
        hints.removeAll()
        for entry in entries {
            let record = Record(
                id: entry.id,
                pane: restoredPane(for: entry.speaker),
                speaker: entry.speaker,
                source: entry.source,
                sourceText: entry.sourceText,
                translatedText: entry.translatedText,
                isFinal: entry.isFinal,
                createdAt: entry.recordedAt,
                updatedAt: entry.recordedAt,
                displayGeneration: generation
            )
            index[entry.id] = records.count
            records.append(record)
        }
    }

    mutating func setSpeakingHint(_ text: String?, pane: SpeakerSide) {
        hints[pane] = text
    }

    func pane(_ side: SpeakerSide) -> PaneState {
        guard policy.panes.contains(side) else { return .empty }
        let history = visibleHistory(for: side).map { line(for: $0) }
        var live: CaptionLine?
        if let id = liveIDByPane[side], let recordIndex = index[id] {
            let record = records[recordIndex]
            if record.displayGeneration == generation {
                live = line(for: record)
            }
        }
        return PaneState(history: history, live: live, speakingHint: hints[side])
    }

    var transcript: [TranscriptEntry] {
        records.map { record in
            TranscriptEntry(
                id: record.id,
                speaker: record.speaker,
                source: record.source,
                sourceText: record.sourceText,
                translatedText: record.translatedText,
                isFinal: record.isFinal,
                recordedAt: record.createdAt
            )
        }
    }

    var transcriptCharacterCount: Int {
        records.reduce(0) { $0 + $1.sourceText.count }
    }

    /// `TranscriptEntry` stores only the speaker, not the pane it rendered on.
    /// Prefer the listener side (the speaker's opposite) when the policy shows
    /// it, then the speaker's own side, then the policy's first pane: that maps
    /// face-to-face rows to the reading side, interpretation rows to the single
    /// pane, and meeting rows to the user pane.
    private func restoredPane(for speaker: SpeakerSide) -> SpeakerSide {
        let listener = speaker.opposite
        if policy.panes.contains(listener) {
            return listener
        }
        if policy.panes.contains(speaker) {
            return speaker
        }
        return policy.panes.first ?? .user
    }

    /// The history rows rendered for a pane: visible records in record order,
    /// excluding the live row, capped by the policy's history limit.
    private func visibleHistory(for side: SpeakerSide) -> [Record] {
        var history: [Record] = []
        for record in records where record.pane == side && record.displayGeneration == generation {
            guard liveIDByPane[side] != record.id else { continue }
            history.append(record)
        }
        if let limit = policy.historyLimit, history.count > limit {
            history = Array(history.suffix(limit))
        }
        return history
    }

    private func isInDisplayWindow(_ record: Record) -> Bool {
        guard record.displayGeneration == generation, policy.panes.contains(record.pane) else {
            return false
        }
        if liveIDByPane[record.pane] == record.id {
            return true
        }
        return visibleHistory(for: record.pane).contains { $0.id == record.id }
    }

    private func line(for record: Record) -> CaptionLine {
        CaptionLine(
            id: record.id,
            side: record.pane,
            source: record.source,
            sourceText: record.sourceText,
            translatedText: record.translatedText,
            phase: phase(for: record),
            updatedAt: record.updatedAt
        )
    }

    /// `isFinal` is data; the display phase is derived from it plus whether the
    /// record is still the live line of its pane.
    private func phase(for record: Record) -> CaptionLine.Phase {
        liveIDByPane[record.pane] == record.id && !record.isFinal ? .streaming : .settled
    }
}
