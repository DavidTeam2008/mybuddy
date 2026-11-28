import Foundation

/// How strictly a transcription result's script must match the transcriber's
/// locale before the assembler accepts it.
enum SpeechLanguagePurity: Equatable, Sendable {
    /// Dual-locale pipelines reject results that look like the other locale so
    /// the two transcribers cannot leak into each other's rows.
    case strict
    /// A single-locale pipeline trusts its transcriber. Mixed-script sentences
    /// and numeric-only results must not be dropped; mismatches are only logged.
    case trustedLocale
}

/// The audio range a `SpeechTranscriber.Result` applies to. Times are source
/// audio seconds; they stay on one timeline across both transcribers.
struct SpeechRange: Equatable, Sendable {
    var start: Double
    var end: Double

    /// Builds a range only when both CMTime conversions are finite. A missing
    /// range keeps the text-only assembly path.
    init?(rangeStart: Double?, rangeDuration: Double?) {
        guard let rangeStart, let rangeDuration,
              rangeStart.isFinite, rangeDuration.isFinite,
              rangeDuration >= 0 else {
            return nil
        }
        start = rangeStart
        end = rangeStart + rangeDuration
    }

    init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    var duration: Double { max(0, end - start) }

    /// Two results overlap when they share real audio. Mere adjacency (the
    /// end of one phrase equals the start of the next) is not an overlap, so a
    /// small tolerance is subtracted rather than added.
    func overlaps(_ other: SpeechRange, tolerance: Double = 0.02) -> Bool {
        start < other.end - tolerance && other.start < end - tolerance
    }

    func contains(_ other: SpeechRange, tolerance: Double = 0.05) -> Bool {
        start <= other.start + tolerance && end + tolerance >= other.end
    }

    func union(_ other: SpeechRange) -> SpeechRange {
        SpeechRange(start: min(start, other.start), end: max(end, other.end))
    }
}

/// Diagnostic-only reason an ASR result did not become row content. These
/// events never change acceptance, publication, or utterance identity.
enum SpeechDropReason: String, Equatable, Sendable {
    case empty
    case punctuationOnly
    case purity
    case suppression
    case lateVolatileClosedRange
    case preemption
}

/// One diagnostic drop. It carries no caption text: only the language, result
/// shape, length, and audio range.
struct SpeechDropEvent: Equatable, Sendable {
    var language: AppLanguage
    var reason: SpeechDropReason
    var textLength: Int
    var isFinal: Bool
    var range: SpeechRange?
}

/// One diagnostic language-preemption decision. `language` in the exported
/// event is the incumbent; `challengerLanguage` is the result that arrived.
struct SpeechPreemptionEvent: Equatable, Sendable {
    /// The incumbent row that was dropped or published. Lets a real-device
    /// A/B join the event to the final ASR event/transcript row.
    var incumbentUtteranceID: UUID
    var incumbentLanguage: AppLanguage
    var challengerLanguage: AppLanguage
    var incumbentTextLength: Int
    var challengerTextLength: Int
    var incumbentConfident: Bool
    var challengerConfident: Bool
    var incumbentVisible: Bool
    var queuedFinal: Bool
    var applied: Bool
    var range: SpeechRange?
}

/// DEBUG-only A/B switch for the preemption content-loss experiment. Release
/// always keeps the existing discard behavior.
struct UtteranceAssemblerExperimentOptions: Equatable, Sendable {
    /// When true, a confident visible incumbent row is published and closed
    /// before the challenger starts; the loser is never merged into the winner.
    var publishesPreemptedIncumbent = false

    static func parse(arguments: [String]) -> UtteranceAssemblerExperimentOptions {
        var options = UtteranceAssemblerExperimentOptions()
        guard let index = arguments.firstIndex(of: "-duiyi.assemblerPreemptionPublish") else {
            return options
        }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return options }
        options.publishesPreemptedIncumbent = !["no", "false", "0"]
            .contains(arguments[valueIndex].lowercased())
        return options
    }

    static var current: UtteranceAssemblerExperimentOptions {
        #if DEBUG
        parse(arguments: ProcessInfo.processInfo.arguments)
        #else
        UtteranceAssemblerExperimentOptions()
        #endif
    }
}

struct UtteranceAssembler: Sendable {
    private struct FinalizedUtterance: Equatable, Sendable {
        let id: UUID
        let language: AppLanguage
        let text: String
        let at: Date
    }

    private struct RangePhrase: Equatable, Sendable {
        var text: String
        var range: SpeechRange
    }

    private struct LanguageRangeState: Equatable, Sendable {
        /// Final phrases that belong to the current utterance, in audio order.
        var finalized: [RangePhrase] = []
        /// The open range's latest volatile interpretation, if any.
        var volatile: RangePhrase?
    }

    private struct ClosedRangeUtterance: Equatable, Sendable {
        var id: UUID
        var language: AppLanguage
        var range: SpeechRange
        /// The row's finalized phrases and its still-open tail at close time.
        /// A late final usually covers only the tail, so the phrases are kept
        /// to merge it without dropping the finalized prefix.
        var state: LanguageRangeState
        var at: Date
    }

    /// A phrase gap larger than this starts a new utterance even when the
    /// previous final did not end with sentence punctuation.
    private static let rangeGapLimit: TimeInterval = 0.75
    /// Recently closed rows remembered for a late same-range final.
    private static let closedRangeHistoryLimit = 8
    /// Safety fuse for rows that keep growing through contiguous phrases.
    /// Only applied at a phrase boundary when the row has no volatile tail.
    private static let maxRowDuration: TimeInterval = 12
    private static let maxRowCharacters = 120

    var lastLanguage: AppLanguage?
    var languagePurity: SpeechLanguagePurity
    private var utteranceID = UUID()
    private var texts: [AppLanguage: String] = [:]
    private var finals: [AppLanguage: Bool] = [:]
    private var lockedLanguage: AppLanguage?
    private var suppressOtherUntil = Date.distantPast
    private var latestFinal: FinalizedUtterance?
    private var rangeStates: [AppLanguage: LanguageRangeState] = [:]
    private var closedRanges: [ClosedRangeUtterance] = []
    private var pendingFinals: [Utterance] = []
    private var publishedFinalForCurrentID = false
    /// Diagnostic-only queues. The engine drains them after every ingest.
    private var dropEvents: [SpeechDropEvent] = []
    private var preemptionEvents: [SpeechPreemptionEvent] = []
    private let reconciliationWindow: TimeInterval
    private let experiment: UtteranceAssemblerExperimentOptions
    private let now: @Sendable () -> Date

    init(
        reconciliationWindow: TimeInterval = 3,
        languagePurity: SpeechLanguagePurity = .strict,
        experiment: UtteranceAssemblerExperimentOptions = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.reconciliationWindow = reconciliationWindow
        self.languagePurity = languagePurity
        self.experiment = experiment
        self.now = now
    }

    /// Text-only seam kept for call sites and tests that do not have audio
    /// ranges. The engine uses the range-aware overload.
    mutating func ingest(language: AppLanguage, text: String, isFinal: Bool) -> Utterance? {
        ingest(language: language, text: text, isFinal: isFinal, range: nil)
    }

    mutating func ingest(
        language: AppLanguage,
        text: String,
        isFinal: Bool,
        range: SpeechRange?
    ) -> Utterance? {
        let trimmedInput = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = TextNormalization.sourcePhrase(text)
        // A punctuation-only result carries no words. Treat it as absent:
        // replacing or finalizing an open phrase with "." would discard the
        // phrase's text (and in trusted-locale mode it can otherwise become a
        // row of its own). Truly empty text still reaches the revoke path.
        if !trimmedInput.isEmpty,
           !normalized.contains(where: { $0.isLetter || $0.isNumber }) {
            recordDrop(
                language: language,
                reason: .punctuationOnly,
                textLength: trimmedInput.count,
                isFinal: isFinal,
                range: range
            )
            return nil
        }
        guard let range else {
            return ingestByText(language: language, text: normalized, isFinal: isFinal)
        }
        return ingestRangeAware(
            language: language,
            text: normalized,
            isFinal: isFinal,
            range: range
        )
    }

    /// True while a row has volatile text the silence timer can finalize.
    /// A row that already received only transcriber finals is still open for
    /// row identity purposes, but has nothing synthetic to publish.
    var hasOpenRange: Bool {
        rangeStates.values.contains { $0.volatile != nil }
    }

    /// True while the current row has any text that a gap, language change,
    /// name swap, or silence can close. A final-only row is open until one of
    /// those boundaries arrives; its final was already published in place.
    var hasOpenRow: Bool {
        rangeStates.values.contains { state in
            state.volatile != nil || !state.finalized.isEmpty
        }
    }

    /// Finals for rows closed by a gap, language/name change, or cap. The
    /// current `ingest` returns the new row's utterance, so the caller must
    /// publish these first; otherwise an open volatile at the boundary would
    /// be closed without ever reaching the transcript.
    mutating func takePendingFinals() -> [Utterance] {
        defer { pendingFinals.removeAll() }
        return pendingFinals
    }

    /// Diagnostic drops since the last drain. Never used for row decisions.
    mutating func takeDropEvents() -> [SpeechDropEvent] {
        defer { dropEvents.removeAll() }
        return dropEvents
    }

    /// Diagnostic language-preemption decisions since the last drain. Never
    /// used for row decisions.
    mutating func takePreemptionEvents() -> [SpeechPreemptionEvent] {
        defer { preemptionEvents.removeAll() }
        return preemptionEvents
    }

    private mutating func ingestByText(
        language: AppLanguage,
        text: String,
        isFinal: Bool
    ) -> Utterance? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            recordDrop(
                language: language,
                reason: .empty,
                textLength: 0,
                isFinal: isFinal,
                range: nil
            )
            return nil
        }
        guard passesPurityGate(trimmed, language: language) else {
            recordDrop(
                language: language,
                reason: .purity,
                textLength: trimmed.count,
                isFinal: isFinal,
                range: nil
            )
            return nil
        }
        guard passesSuppressionGate(language: language) else {
            recordDrop(
                language: language,
                reason: .suppression,
                textLength: trimmed.count,
                isFinal: isFinal,
                range: nil
            )
            return nil
        }

        // A replay of the just-closed range can arrive as a volatile before
        // the transcriber's final. Keep it on the closed row (as a volatile
        // revision) instead of starting a row that the final cannot settle.
        //
        // Reconcile only while no new row has started. Once a new utterance
        // has text, a later final may belong to either row; without audio
        // ranges the safe choice is the previous behavior (new row).
        let noRowInProgress = texts.values.allSatisfy(\.isEmpty)
        if !isFinal,
           noRowInProgress,
           let latest = latestFinal,
           latest.id != utteranceID,
           latest.language == language,
           !SpokenText.isNameSwap(trimmed, of: latest.text),
           now().timeIntervalSince(latest.at) <= reconciliationWindow,
           SpokenText.isRefinement(trimmed, of: latest.text) {
            return Utterance(
                id: latest.id,
                language: language,
                text: trimmed,
                isFinal: false,
                isRevision: true
            )
        }

        // A silence-timeout final closes the utterance before the transcriber
        // publishes its own final for the same range. When no new row has
        // started and the late final is a prefix extension of the closed
        // utterance, revise that utterance in place instead of starting a
        // duplicate row.
        if isFinal,
           noRowInProgress,
           let latest = latestFinal,
           latest.id != utteranceID,
           latest.language == language,
           !SpokenText.isNameSwap(trimmed, of: latest.text),
           now().timeIntervalSince(latest.at) <= reconciliationWindow,
           SpokenText.isRefinement(trimmed, of: latest.text) {
            let revised = Utterance(
                id: latest.id,
                language: language,
                text: trimmed,
                isFinal: true,
                isRevision: true
            )
            latestFinal = FinalizedUtterance(
                id: latest.id,
                language: language,
                text: trimmed,
                at: now()
            )
            return revised
        }

        // A row that already emitted a final may only accept a same-language
        // continuation or refinement. Anything else belongs to a new
        // utterance. `latestFinal` is the source of truth for finality: a
        // later volatile clears `finals[language]` but cannot un-finalize the
        // row, and an unconfident final never sets `lockedLanguage`.
        if let finalized = latestFinal, finalized.id == utteranceID {
            let sameLanguage = finalized.language == language
            let isRevision = sameLanguage && (
                SpokenText.isContinuation(trimmed, of: finalized.text, language: language)
                    || SpokenText.isRefinement(trimmed, of: finalized.text)
            )
            let isNameSwap = sameLanguage && SpokenText.isNameSwap(trimmed, of: finalized.text)
            if isNameSwap || !isRevision {
                guard sameLanguage || Self.isConfident(trimmed, language: language) else {
                    return nil
                }
                beginNextUtterance(keeping: language)
            }
        }

        // A greeting name swap is a different person speaking and must start a
        // new utterance even while both greetings are still volatile. Compute
        // it before a language preemption can replace the lock, so a losing
        // language's stale text can never look like the current greeting.
        let previousInLanguage = textFor(language)
        let isGreetingNameSwap = (lockedLanguage == nil || lockedLanguage == language)
            && !previousInLanguage.isEmpty
            && SpokenText.isNameSwap(trimmed, of: previousInLanguage)

        if preemptsIfNeeded(
            language: language,
            text: trimmed,
            isFinal: isFinal,
            range: nil
        ) == .rejected {
            return nil
        }

        if isGreetingNameSwap {
            beginNextUtterance(keeping: language)
            lockedLanguage = language
        } else if let locked = lockedLanguage, language == locked {
            let previous = textFor(locked)
            if !previous.isEmpty,
               isWinnerFinal(locked),
               !SpokenText.isContinuation(trimmed, of: previous, language: language)
                && !SpokenText.isRefinement(trimmed, of: previous) {
                beginNextUtterance(keeping: locked)
                lockedLanguage = language
            }
        }

        texts[language] = trimmed
        finals[language] = isFinal

        if lockedLanguage == nil {
            lockedLanguage = inferredLock()
        }

        guard let winner = lockedLanguage ?? winningLanguage() else { return nil }
        let winnerText = textFor(winner)
        guard !winnerText.isEmpty else { return nil }

        let utterance = Utterance(
            id: utteranceID,
            language: winner,
            text: winnerText,
            isFinal: isWinnerFinal(winner)
        )
        if utterance.isFinal {
            latestFinal = FinalizedUtterance(
                id: utterance.id,
                language: utterance.language,
                text: utterance.text,
                at: now()
            )
        }
        return utterance
    }

    // MARK: - Range-aware assembly (P1-1)

    /// `SpeechTranscriber` sends a result per audio phrase. The text belongs to
    /// `range`, not to the whole utterance: finalized phrases accumulate as a
    /// prefix and the open range's volatile text is the tail. Ranges decide
    /// where a phrase continues; punctuation stays in the text. Row boundaries
    /// are audio gaps, language/name changes, silence, and the max cap. A late
    /// final for a closed range revises that row in place.
    private mutating func ingestRangeAware(
        language: AppLanguage,
        text: String,
        isFinal: Bool,
        range: SpeechRange
    ) -> Utterance? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // An empty volatile revokes the open interpretation for its range; an
        // empty final says the range contained no speech.
        if trimmed.isEmpty {
            recordDrop(
                language: language,
                reason: .empty,
                textLength: 0,
                isFinal: isFinal,
                range: range
            )
            return revokeRange(language: language, range: range)
        }

        guard passesPurityGate(trimmed, language: language) else {
            recordDrop(
                language: language,
                reason: .purity,
                textLength: trimmed.count,
                isFinal: isFinal,
                range: range
            )
            return nil
        }
        guard passesSuppressionGate(language: language) else {
            recordDrop(
                language: language,
                reason: .suppression,
                textLength: trimmed.count,
                isFinal: isFinal,
                range: range
            )
            return nil
        }

        // A late volatile for an already-closed range must not revive or
        // pollute the newer row. If it extends beyond the closed range and no
        // new row has started yet, it may carry the first phrase after a
        // pause: start the next row with it instead of discarding possible
        // new content.
        if !isFinal, let closed = closedRangeMatch(language: language, range: range) {
            let extendsClosedRange = range.end > closed.range.end + 0.05
            let rowIsEmpty = texts.values.allSatisfy(\.isEmpty)
            guard extendsClosedRange, rowIsEmpty else {
                recordDrop(
                    language: language,
                    reason: .lateVolatileClosedRange,
                    textLength: trimmed.count,
                    isFinal: false,
                    range: range
                )
                return nil
            }
        }

        // A final for a range the silence timer already closed belongs to that
        // row even while a newer row is live. This replaces the old prefix
        // heuristic with the audio range Apple actually sent.
        if isFinal, let closed = closedRangeMatch(language: language, range: range) {
            // A final that extends the closed row into new audio is the next
            // phrase after a pause, not a revision, unless its text carries
            // the closed tail. Start the next row instead of replacing a
            // phrase and losing one side of the boundary.
            let extendsClosedRange = range.end > closed.range.end + 0.05
            let tail = closed.state.volatile
                ?? closed.state.finalized.max { $0.range.end < $1.range.end }
            let carriesClosedTail = tail.map {
                SpokenText.compact(trimmed).contains(SpokenText.compact($0.text))
            } ?? false
            let rowIsEmpty = texts.values.allSatisfy(\.isEmpty)
            let currentOverlaps = rangeStates[language].map { state in
                state.volatile?.range.overlaps(range) == true
                    || state.finalized.contains { $0.range.overlaps(range) }
            } ?? false
            let startsNextRow = extendsClosedRange
                && !carriesClosedTail
                && (rowIsEmpty || currentOverlaps)
            if !startsNextRow {
                // A late final usually covers only the tail that was still
                // volatile at close time. Merge it into the row's phrase
                // list: the final stays authoritative for its own range, but
                // the finalized prefix must survive.
                var state = closed.state
                apply(range: range, text: trimmed, isFinal: true, to: &state)
                let revisedText = Self.joinedText(of: state)
                updateClosedRange(id: closed.id, range: range, state: state)
                latestFinal = FinalizedUtterance(
                    id: closed.id,
                    language: language,
                    text: revisedText,
                    at: now()
                )
                return Utterance(
                    id: closed.id,
                    language: language,
                    text: revisedText,
                    isFinal: true,
                    isRevision: true
                )
            }
        }

        // A published final closes the row for identity. A different language
        // is a new utterance; remember the old range so a late final can still
        // revise it, then start the new row.
        if let finalized = latestFinal,
           finalized.id == utteranceID,
           language != finalized.language {
            guard Self.isConfident(trimmed, language: language) else { return nil }
            queueFinalForBoundary(language: finalized.language)
            closeCurrentRangeRow(language: finalized.language)
            beginNextUtterance(keeping: language)
        }

        let previousText = texts[language] ?? ""
        let isGreetingNameSwap = (lockedLanguage == nil || lockedLanguage == language)
            && !previousText.isEmpty
            && SpokenText.isNameSwap(trimmed, of: previousText)

        if isGreetingNameSwap {
            // Do not remember the old greeting's range: a final for that same
            // audio belongs to the new person's row, not the name it replaced.
            queueFinalForBoundary(language: language)
            beginNextUtterance(keeping: language)
        }

        if preemptsIfNeeded(
            language: language,
            text: trimmed,
            isFinal: isFinal,
            range: range
        ) == .rejected {
            return nil
        }

        // A preemption experiment may have closed the incumbent row and
        // started a new utterance. Read the challenger's state only after the
        // decision so the new id never inherits the loser's phrases.
        var state = rangeStates[language] ?? LanguageRangeState()

        // A phrase after a real audio gap starts a new utterance even when the
        // transcriber did not add sentence punctuation. This covers both a new
        // volatile phrase and a final that follows the gap.
        let lastEnd = Self.maxEnd(of: state)
        if let lastEnd, range.start > lastEnd + Self.rangeGapLimit {
            queueFinalForBoundary(language: language)
            closeCurrentRangeRow(language: language)
            beginNextUtterance(keeping: language)
            state = LanguageRangeState()
        }

        // A long run of contiguous finalized phrases is one speech turn for
        // identity purposes, but an unbounded row is bad for the pane and for
        // translation latency. Close only at a phrase boundary and only when
        // the row has no volatile tail; a volatile row waits for its final or
        // the silence timer.
        if state.volatile == nil,
           !state.finalized.isEmpty,
           let rowRange = Self.unionRange(of: state),
           !rowRange.overlaps(range),
           range.start >= rowRange.end - 0.05 {
            let rowText = Self.joinedText(of: state)
            if rowRange.duration > Self.maxRowDuration
                || SpokenText.compact(rowText).count > Self.maxRowCharacters {
                queueFinalForBoundary(language: language)
                closeCurrentRangeRow(language: language)
                beginNextUtterance(keeping: language)
                state = LanguageRangeState()
            }
        }

        apply(range: range, text: trimmed, isFinal: isFinal, to: &state)
        rangeStates[language] = state
        refreshTexts(for: language, state: state)
        if lockedLanguage == nil {
            lockedLanguage = inferredLock()
        }

        guard let winner = lockedLanguage ?? winningLanguage() else { return nil }
        let winnerText = textFor(winner)
        guard !winnerText.isEmpty else { return nil }
        let winnerFinal = isWinnerFinal(winner)
        let revision = winnerFinal && publishedFinalForCurrentID

        let utterance = Utterance(
            id: utteranceID,
            language: winner,
            text: winnerText,
            isFinal: winnerFinal,
            isRevision: revision
        )
        if utterance.isFinal {
            publishedFinalForCurrentID = true
            latestFinal = FinalizedUtterance(
                id: utterance.id,
                language: utterance.language,
                text: utterance.text,
                at: now()
            )
        }
        return utterance
    }

    /// Clears the open volatile text for `range`. Falls back to the finalized
    /// prefix when one exists; with no prefix there is no row text to show.
    private mutating func revokeRange(
        language: AppLanguage,
        range: SpeechRange
    ) -> Utterance? {
        guard var state = rangeStates[language],
              let volatile = state.volatile,
              volatile.range.overlaps(range) else {
            return nil
        }
        state.volatile = nil
        rangeStates[language] = state
        refreshTexts(for: language, state: state)
        guard let winner = lockedLanguage ?? winningLanguage(), winner == language else {
            return nil
        }
        let text = textFor(language)
        guard !text.isEmpty else { return nil }
        // The finalized prefix is authoritative, so publish it as a final
        // revision; the projection ignores a volatile update on a settled row
        // and would otherwise keep the revoked tail on screen.
        return Utterance(
            id: utteranceID,
            language: language,
            text: text,
            isFinal: true,
            isRevision: true
        )
    }

    private func apply(
        range: SpeechRange,
        text: String,
        isFinal: Bool,
        to state: inout LanguageRangeState
    ) {
        if isFinal {
            applyFinal(range: range, text: text, to: &state)
        } else {
            applyVolatile(range: range, text: text, to: &state)
        }
    }

    private func applyFinal(
        range: SpeechRange,
        text: String,
        to state: inout LanguageRangeState
    ) {
        var candidate = RangePhrase(text: text, range: range)

        // A final usually covers the phrase the volatile was previewing. When
        // the two texts describe the same phrase, merge them; when they do
        // not, the volatile is a different phrase that happens to share a
        // padded range. Keep it as its own phrase instead of replacing one
        // side with the other.
        if let volatile = state.volatile {
            if volatile.range.overlaps(range) {
                if Self.sameAudioWindow(volatile.range, range),
                   Self.describesSamePhrase(volatile.text, text) {
                    candidate = Self.mergeVolatile(volatile, final: candidate)
                } else if Self.shouldReplaceSameAudio(
                    existing: volatile,
                    incoming: candidate
                ) {
                    // A different text over the same audio is a re-hearing
                    // ("I scream" -> "ice cream"), not a second phrase. Keep
                    // the final; splitting the two would show both spellings.
                } else {
                    Self.insertPhrase(
                        Self.bounded(volatile, before: range),
                        into: &state.finalized
                    )
                }
                state.volatile = nil
            } else if range.start >= volatile.range.start {
                // The final begins after the open preview: that preview's
                // phrase is finished. A later phrase must not leave a stale
                // volatile tail attached to the row.
                Self.insertPhrase(
                    Self.bounded(volatile, before: range),
                    into: &state.finalized
                )
                state.volatile = nil
            }
        }

        // A final for an already-finalized phrase revises that phrase only
        // when it describes the same phrase. A different text is new content:
        // keep both, in audio order. This is the invariant that prevents a
        // short phrase between long phrases from being swallowed when padded
        // ranges overlap.
        if let index = Self.bestOverlapIndex(of: candidate.range, in: state.finalized) {
            let existing = state.finalized[index]
            let existingText = SpokenText.compact(existing.text)
            let candidateText = SpokenText.compact(candidate.text)
            let contains = existingText.contains(candidateText)
                || candidateText.contains(existingText)
            if Self.describesSamePhrase(existing.text, candidate.text),
               contains || Self.sameAudioWindow(existing.range, candidate.range) {
                state.finalized[index].text = Self.preferredPhraseText(
                    existing: existing.text,
                    incoming: candidate.text,
                    incomingCovers: candidate.range.contains(existing.range)
                )
                state.finalized[index].range = existing.range.union(candidate.range)
            } else if Self.shouldReplaceSameAudio(
                existing: existing,
                incoming: candidate
            ) {
                // The same audio answered differently. A transcriber final is
                // authoritative for that audio.
                state.finalized[index].text = candidate.text
                state.finalized[index].range = candidate.range
            } else {
                Self.insertPhrase(candidate, into: &state.finalized)
            }
        } else {
            Self.insertPhrase(candidate, into: &state.finalized)
        }
    }

    private func applyVolatile(
        range: SpeechRange,
        text: String,
        to state: inout LanguageRangeState
    ) {
        if let volatile = state.volatile, volatile.range.overlaps(range) {
            if Self.sameVolatilePhrase(
                existing: volatile,
                incoming: RangePhrase(text: text, range: range)
            ) {
                state.volatile = RangePhrase(
                    text: text,
                    range: volatile.range.union(range)
                )
                return
            }
            // A different phrase begins inside the volatile's padded range,
            // or the overlap is only padding. Bound the old phrase at the new
            // phrase's start.
            Self.insertPhrase(
                Self.bounded(volatile, before: range),
                into: &state.finalized
            )
            state.volatile = RangePhrase(text: text, range: range)
            return
        }

        // An open volatile from an earlier range lies outside this result's
        // range. Keep it as a consolidated phrase instead of discarding it; a
        // later final for that range still revises it in place. Bound its end
        // so its padded range cannot claim the new phrase's audio.
        if let volatile = state.volatile {
            Self.insertPhrase(
                Self.bounded(volatile, before: range),
                into: &state.finalized
            )
        }

        if let index = Self.bestOverlapIndex(of: range, in: state.finalized),
           Self.describesSamePhrase(state.finalized[index].text, text) {
            // The finalized text is authoritative; a preview must not reopen
            // or rewrite it.
            state.volatile = nil
            return
        }
        state.volatile = RangePhrase(text: text, range: range)
    }

    /// Two texts describe the same phrase when one contains the other or they
    /// are close ASR refinements. Anything else is distinct content and must
    /// never be merged by a "longer wins" rule.
    private static func describesSamePhrase(_ existing: String, _ incoming: String) -> Bool {
        let existingText = SpokenText.compact(existing)
        let incomingText = SpokenText.compact(incoming)
        guard !existingText.isEmpty, !incomingText.isEmpty else { return false }
        if existingText.contains(incomingText) || incomingText.contains(existingText) {
            return true
        }
        return SpokenText.isRefinement(existing, of: incoming)
            || SpokenText.isRefinement(incoming, of: existing)
    }

    /// Merges a final into the volatile phrase it completes. The final range
    /// stays tight unless the volatile text is demonstrably fuller: extending
    /// a phrase's range into a speculative volatile tail is what lets a later
    /// short phrase be mistaken for a revision of this one.
    private static func mergeVolatile(
        _ volatile: RangePhrase,
        final: RangePhrase
    ) -> RangePhrase {
        let volatileText = SpokenText.compact(volatile.text)
        let finalText = SpokenText.compact(final.text)
        if volatileText.contains(finalText),
           finalText.count * 2 < volatileText.count {
            // The final dropped more than half of what the preview already
            // showed: a truncation, not a cleanup. Keep the preview's text,
            // but not its speculative tail: a phrase range that claims audio
            // the final never covered lets a later distinct phrase be
            // mistaken for a re-transcription.
            return RangePhrase(text: volatile.text, range: final.range)
        }
        if volatileText.count > finalText.count,
           !final.range.contains(volatile.range) {
            // The final covers only part of the preview and drops content.
            // Keep the fuller preview text, with the tight final range.
            return RangePhrase(
                text: preferredPhraseText(
                    existing: volatile.text,
                    incoming: final.text,
                    incomingCovers: false
                ),
                range: final.range
            )
        }
        // The final range stays tight even when its punctuation or wording
        // loses to the preview's display text.
        return RangePhrase(
            text: preferredPhraseText(
                existing: volatile.text,
                incoming: final.text,
                incomingCovers: final.range.contains(volatile.range)
            ),
            range: final.range
        )
    }

    /// A volatile update continues the same phrase only when its range still
    /// starts near the existing preview. A short fragment from the next phrase
    /// ("you") can be contained in the preview's text and overlap its padded
    /// tail; treating that as a revision replaces the preview with the
    /// fragment and deletes words the user already saw.
    private static func sameVolatilePhrase(
        existing: RangePhrase,
        incoming: RangePhrase
    ) -> Bool {
        guard sameAudioWindow(existing.range, incoming.range) else { return false }
        let startTolerance = max(0.5, existing.range.duration * 0.25)
        guard incoming.range.start <= existing.range.start + startTolerance else {
            return false
        }
        let existingText = SpokenText.compact(existing.text)
        let incomingText = SpokenText.compact(incoming.text)
        if incomingText.count * 2 < existingText.count {
            return false
        }
        return describesSamePhrase(existing.text, incoming.text)
    }

    /// True when the two ranges describe mostly the same audio window, not
    /// merely adjacent phrases with a padded overlap. A volatile revision of
    /// one phrase keeps (or grows) the same start; a new phrase starts later.
    private static func sameAudioWindow(_ lhs: SpeechRange, _ rhs: SpeechRange) -> Bool {
        let overlap = min(lhs.end, rhs.end) - max(lhs.start, rhs.start)
        guard overlap > 0 else { return false }
        let smaller = min(lhs.duration, rhs.duration)
        guard smaller > 0 else { return false }
        return overlap / smaller >= 0.5
    }

    /// A same-audio replacement is for a re-hearing of the phrase's beginning
    /// or for a final that covers the whole phrase. A final that starts late
    /// and only covers the tail is a new phrase inside the preview's padded
    /// range; keep both rather than deleting the earlier text.
    private static func shouldReplaceSameAudio(
        existing: RangePhrase,
        incoming: RangePhrase
    ) -> Bool {
        guard sameAudioWindow(existing.range, incoming.range) else { return false }
        let existingText = SpokenText.compact(existing.text)
        let incomingText = SpokenText.compact(incoming.text)
        if incomingText.count * 2 < existingText.count {
            // A final much shorter than the preview is a truncation or a
            // fragment, not a re-hearing. Replacing would delete words the
            // user already saw; keep the preview and insert the final after
            // it instead.
            return false
        }
        if incoming.range.contains(existing.range) { return true }
        guard existing.range.duration > 0 else { return true }
        let startFraction = (incoming.range.start - existing.range.start)
            / existing.range.duration
        return startFraction <= 0.6
    }

    /// Keeps a phrase out of audio the next result has already claimed. A
    /// volatile range is a speculative window; its tail is not part of its
    /// text and must not become part of the finalized row.
    private static func bounded(
        _ phrase: RangePhrase,
        before range: SpeechRange
    ) -> RangePhrase {
        guard range.start > phrase.range.start,
              range.start < phrase.range.end else {
            return phrase
        }
        return RangePhrase(
            text: phrase.text,
            range: SpeechRange(start: phrase.range.start, end: range.start)
        )
    }

    private static func insertPhrase(
        _ phrase: RangePhrase,
        into phrases: inout [RangePhrase]
    ) {
        let index = phrases.firstIndex { phrase.range.start < $0.range.start }
            ?? phrases.endIndex
        phrases.insert(phrase, at: index)
    }

    private static func bestOverlapIndex(
        of range: SpeechRange,
        in phrases: [RangePhrase]
    ) -> Int? {
        var best: (index: Int, overlap: Double)?
        for (index, phrase) in phrases.enumerated() where phrase.range.overlaps(range) {
            let overlap = min(phrase.range.end, range.end)
                - max(phrase.range.start, range.start)
            if best == nil || overlap > best!.overlap {
                best = (index, overlap)
            }
        }
        return best?.index
    }

    private static func maxEnd(of state: LanguageRangeState) -> Double? {
        var ends = state.finalized.map(\.range.end)
        if let volatile = state.volatile {
            ends.append(volatile.range.end)
        }
        return ends.max()
    }

    /// A final that covers only part of an existing phrase cannot replace its
    /// text without losing the words outside the final's range. Prefer the
    /// interpretation that contains the other; otherwise keep the longer one.
    private static func preferredPhraseText(
        existing: String,
        incoming: String,
        incomingCovers: Bool
    ) -> String {
        let existingCompact = SpokenText.compact(existing)
        let incomingCompact = SpokenText.compact(incoming)
        if incomingCovers {
            // A final that drops more than half of the phrase it covers is a
            // truncation, not a cleanup ("...math test? She'll perform
            // better." -> "She'll perform better."). Keep the fuller text so
            // the preview's content survives into the settled row.
            if existingCompact.contains(incomingCompact),
               incomingCompact.count * 2 < existingCompact.count {
                return existing
            }
            return incoming
        }
        if existingCompact.contains(incomingCompact) { return existing }
        if incomingCompact.contains(existingCompact) { return incoming }
        return incomingCompact.count >= existingCompact.count ? incoming : existing
    }

    private mutating func refreshTexts(
        for language: AppLanguage,
        state: LanguageRangeState
    ) {
        texts[language] = Self.joinedText(of: state)
        finals[language] = !state.finalized.isEmpty && state.volatile == nil
    }

    /// The row's text: finalized phrases in audio order plus the open tail.
    private static func joinedText(of state: LanguageRangeState) -> String {
        var phrases = state.finalized
        if let volatile = state.volatile {
            phrases.append(volatile)
        }
        let ordered = phrases.enumerated().sorted { lhs, rhs in
            if lhs.element.range.start != rhs.element.range.start {
                return lhs.element.range.start < rhs.element.range.start
            }
            if lhs.element.range.end != rhs.element.range.end {
                return lhs.element.range.end < rhs.element.range.end
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        return joinPhrases(ordered)
    }

    private func closedRangeMatch(
        language: AppLanguage,
        range: SpeechRange
    ) -> ClosedRangeUtterance? {
        // Audio ranges are monotonic on one timeline, so a matching range is
        // always the same audio; only the bounded history limits the match.
        closedRanges.last { closed in
            closed.language == language && closed.range.overlaps(range)
        }
    }

    private mutating func updateClosedRange(
        id: UUID,
        range: SpeechRange,
        state: LanguageRangeState
    ) {
        guard let index = closedRanges.lastIndex(where: { $0.id == id }) else { return }
        var closed = closedRanges[index]
        closed.range = closed.range.union(range)
        closed.state = state
        closed.at = now()
        closedRanges[index] = closed
    }

    /// The preemption experiment must preserve the incumbent row's visible
    /// text, not a re-joined range state. The two can differ when a late
    /// phrase was already reconciled into `texts`.
    private mutating func queueVisibleFinalForPreemption(
        language: AppLanguage,
        text: String
    ) {
        guard !text.isEmpty else { return }
        if publishedFinalForCurrentID,
           latestFinal?.id == utteranceID,
           latestFinal?.text == text {
            return
        }
        let utterance = Utterance(
            id: utteranceID,
            language: language,
            text: text,
            isFinal: true,
            isRevision: publishedFinalForCurrentID
        )
        pendingFinals.append(utterance)
        publishedFinalForCurrentID = true
        latestFinal = FinalizedUtterance(
            id: utterance.id,
            language: utterance.language,
            text: utterance.text,
            at: now()
        )
    }

    /// A row closed by a boundary must publish any text the user can already
    /// see. The transcript only stores finals; closing an open volatile
    /// without this final is silent content loss.
    private mutating func queueFinalForBoundary(language: AppLanguage) {
        guard let state = rangeStates[language] else { return }
        let text = Self.joinedText(of: state)
        guard !text.isEmpty else { return }
        guard state.volatile != nil || !publishedFinalForCurrentID else { return }
        let utterance = Utterance(
            id: utteranceID,
            language: language,
            text: text,
            isFinal: true,
            isRevision: publishedFinalForCurrentID
        )
        pendingFinals.append(utterance)
        publishedFinalForCurrentID = true
        latestFinal = FinalizedUtterance(
            id: utterance.id,
            language: language,
            text: text,
            at: now()
        )
    }

    private mutating func closeCurrentRangeRow(language: AppLanguage) {
        guard let state = rangeStates[language],
              let range = Self.unionRange(of: state) else {
            return
        }
        closedRanges.append(
            ClosedRangeUtterance(
                id: utteranceID,
                language: language,
                range: range,
                state: state,
                at: now()
            )
        )
        trimClosedRanges()
    }

    private static func unionRange(of state: LanguageRangeState) -> SpeechRange? {
        var ranges = state.finalized.map(\.range)
        if let volatile = state.volatile {
            ranges.append(volatile.range)
        }
        guard let first = ranges.first else { return nil }
        return ranges.dropFirst().reduce(first) { $0.union($1) }
    }

    private mutating func trimClosedRanges() {
        if closedRanges.count > Self.closedRangeHistoryLimit {
            closedRanges.removeFirst(closedRanges.count - Self.closedRangeHistoryLimit)
        }
    }

    private mutating func silenceTimedOutForRanges() -> Utterance? {
        guard let winner = lockedLanguage ?? winningLanguage() else { return nil }
        guard let state = rangeStates[winner],
              state.volatile != nil || !state.finalized.isEmpty else {
            return nil
        }
        let winnerText = textFor(winner)
        guard !winnerText.isEmpty else { return nil }
        let utterance = Utterance(
            id: utteranceID,
            language: winner,
            text: winnerText,
            isFinal: true,
            isRevision: publishedFinalForCurrentID
        )
        // A final-only row already published its text; the silence timer only
        // advances the row boundary. Publishing it again would create a
        // duplicate final (and re-lock the language).
        let shouldPublish = state.volatile != nil || !publishedFinalForCurrentID
        if shouldPublish {
            publishedFinalForCurrentID = true
            latestFinal = FinalizedUtterance(
                id: utterance.id,
                language: utterance.language,
                text: utterance.text,
                at: now()
            )
        }
        closeCurrentRangeRow(language: winner)
        beginNextUtterance(keeping: winner)
        hold(winner, for: 0.8)
        return shouldPublish ? utterance : nil
    }

    private static func joinPhrases(_ phrases: [RangePhrase]) -> String {
        var joined = ""
        for phrase in phrases {
            let piece = phrase.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            // A trailing ellipsis marks a phrase the transcriber has not
            // finished. When another phrase continues the row, the ellipsis
            // is a continuation mark, not punctuation: drop it but keep the
            // normal word spacing. Do not concatenate the fragments: the
            // missing phoneme cannot be recovered, and joining "di" + "nostic"
            // into a fabricated word would hide that loss.
            let dots = trailingDotCount(joined)
            if dots >= 2 {
                joined.removeLast(dots)
            }
            if let last = joined.last, let first = piece.first,
               requiresSpace(between: last, and: first) {
                joined.append(" ")
            }
            joined += piece
        }
        return joined
    }

    private static func trailingDotCount(_ text: String) -> Int {
        var count = 0
        for character in text.reversed() {
            guard character == "." else { break }
            count += 1
        }
        return count
    }

    private static func requiresSpace(between left: Character, and right: Character) -> Bool {
        guard !left.isWhitespace, !right.isWhitespace else { return false }
        let leftIsCJK = isCJK(left) || isCJKPunctuation(left)
        let rightIsCJK = isCJK(right) || isCJKPunctuation(right)
        if leftIsCJK || rightIsCJK {
            // Only a CJK/Latin boundary gets a space; CJK punctuation and CJK
            // characters stay unspaced.
            return leftIsCJK != rightIsCJK
        }
        // A closing mark attaches to the token before it; an opening mark
        // attaches to the token after it.
        if closingPunctuation.contains(right) || openingPunctuation.contains(left) {
            return false
        }
        // After a sentence mark the next token starts a new word even when
        // it is punctuation-led: "carry." + "It's" is not "carry.It's".
        if closingPunctuation.contains(left) || openingPunctuation.contains(right) {
            return true
        }
        return (left.isLetter || left.isNumber) && (right.isLetter || right.isNumber)
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            isHanScalar($0) || isKanaScalar($0) || isHangulScalar($0) || isThaiScalar($0)
        }
    }

    private static func isCJKPunctuation(_ character: Character) -> Bool {
        "。，、；：？！…—～·「」『』【】（）《》〈〉".contains(character)
    }

    private static let closingPunctuation: Set<Character> = [
        ".", ",", "!", "?", ";", ":", ")", "]", "}", "”", "’", "%"
    ]

    private static let openingPunctuation: Set<Character> = [
        "(", "[", "{", "“", "‘"
    ]

    mutating func silenceTimedOut() -> Utterance? {
        if !rangeStates.isEmpty {
            return silenceTimedOutForRanges()
        }
        guard let winner = lockedLanguage ?? winningLanguage() else { return nil }
        let winnerText = textFor(winner)
        guard !winnerText.isEmpty else { return nil }
        let utterance = Utterance(
            id: utteranceID,
            language: winner,
            text: winnerText,
            isFinal: true
        )
        latestFinal = FinalizedUtterance(
            id: utterance.id,
            language: utterance.language,
            text: utterance.text,
            at: now()
        )
        beginNextUtterance(keeping: winner)
        hold(winner, for: 0.8)
        return utterance
    }

    mutating func acknowledgeFinal(language: AppLanguage) {
        hold(language, for: 1.0)
    }

    mutating func reset() {
        // `languagePurity` is configuration owned by the engine; a reset clears
        // per-utterance state only.
        lastLanguage = nil
        lockedLanguage = nil
        suppressOtherUntil = .distantPast
        latestFinal = nil
        closedRanges.removeAll()
        pendingFinals.removeAll()
        dropEvents.removeAll()
        preemptionEvents.removeAll()
        beginNextUtterance(keeping: nil)
    }

    private mutating func passesPurityGate(_ text: String, language: AppLanguage) -> Bool {
        let verdict = Self.languageVerdict(text, claimed: language, purity: languagePurity)
        guard verdict.accepted else { return false }
        if verdict.scriptMismatch, languagePurity == .trustedLocale {
            DuiyiLog.speech.debug(
                "Single-locale result script mismatch for \(language.rawValue, privacy: .public)"
            )
        }
        return true
    }

    private mutating func passesSuppressionGate(language: AppLanguage) -> Bool {
        if now() < suppressOtherUntil, let held = lastLanguage, language != held {
            return false
        }
        if now() >= suppressOtherUntil, lockedLanguage != nil, texts.values.allSatisfy(\.isEmpty) {
            lockedLanguage = nil
        }
        return true
    }

    private enum PreemptionOutcome: Equatable {
        case proceed
        case rejected
        case preempted
    }

    private mutating func preemptsIfNeeded(
        language: AppLanguage,
        text: String,
        isFinal: Bool,
        range: SpeechRange?
    ) -> PreemptionOutcome {
        guard let locked = lockedLanguage, language != locked else { return .proceed }
        // Capture the incumbent id before a successful preemption starts the
        // next utterance; the event must join to the row that was lost or
        // published, not to the challenger's new id.
        let incumbentID = utteranceID
        let incumbent = textFor(locked)
        let challengerConfident = Self.isConfident(text, language: language)
        let incumbentConfident = Self.isConfident(incumbent, language: locked)
        guard Self.shouldPreempt(
            challenger: text,
            challengerLanguage: language,
            incumbent: incumbent,
            incumbentLanguage: locked
        ) else {
            preemptionEvents.append(
                SpeechPreemptionEvent(
                    incumbentUtteranceID: incumbentID,
                    incumbentLanguage: locked,
                    challengerLanguage: language,
                    incumbentTextLength: incumbent.count,
                    challengerTextLength: text.count,
                    incumbentConfident: incumbentConfident,
                    challengerConfident: challengerConfident,
                    incumbentVisible: !incumbent.isEmpty,
                    queuedFinal: false,
                    applied: false,
                    range: range
                )
            )
            return .rejected
        }

        // DEBUG A/B: a critical visible incumbent may be published and closed
        // before the challenger starts. The loser is never merged into the
        // winner, and a non-confident incumbent keeps the old discard path.
        let shouldPreserve = experiment.publishesPreemptedIncumbent
            && !incumbent.isEmpty
            && incumbentConfident
        let pendingBefore = pendingFinals.count
        if shouldPreserve {
            // Publish exactly the text the user can already see. The range
            // state can contain a duplicate/late phrase that the visible
            // `texts` value already reconciled; joining it again would make
            // the preserved final longer than the incumbent.
            queueVisibleFinalForPreemption(language: locked, text: incumbent)
            closeCurrentRangeRow(language: locked)
            beginNextUtterance(keeping: language)
        } else {
            let incumbentIsFinal = isWinnerFinal(locked)
            rangeStates.removeValue(forKey: locked)
            clearText(for: locked)
            lockedLanguage = language
            if !incumbent.isEmpty {
                dropEvents.append(
                    SpeechDropEvent(
                        language: locked,
                        reason: .preemption,
                        textLength: incumbent.count,
                        isFinal: incumbentIsFinal,
                        range: nil
                    )
                )
            }
        }

        preemptionEvents.append(
            SpeechPreemptionEvent(
                incumbentUtteranceID: incumbentID,
                incumbentLanguage: locked,
                challengerLanguage: language,
                incumbentTextLength: incumbent.count,
                challengerTextLength: text.count,
                incumbentConfident: incumbentConfident,
                challengerConfident: challengerConfident,
                incumbentVisible: !incumbent.isEmpty,
                queuedFinal: pendingFinals.count > pendingBefore,
                applied: true,
                range: range
            )
        )
        return .preempted
    }

    private mutating func recordDrop(
        language: AppLanguage,
        reason: SpeechDropReason,
        textLength: Int,
        isFinal: Bool,
        range: SpeechRange?
    ) {
        dropEvents.append(
            SpeechDropEvent(
                language: language,
                reason: reason,
                textLength: textLength,
                isFinal: isFinal,
                range: range
            )
        )
    }

    private mutating func hold(_ language: AppLanguage, for seconds: TimeInterval) {
        lockedLanguage = language
        lastLanguage = language
        suppressOtherUntil = now().addingTimeInterval(seconds)
    }

    private mutating func beginNextUtterance(keeping language: AppLanguage?) {
        if let language {
            lastLanguage = language
        }
        utteranceID = UUID()
        texts = [:]
        finals = [:]
        rangeStates = [:]
        publishedFinalForCurrentID = false
        lockedLanguage = nil
    }

    private mutating func clearText(for language: AppLanguage) {
        texts[language] = ""
        finals[language] = false
        rangeStates.removeValue(forKey: language)
    }

    private func textFor(_ language: AppLanguage) -> String {
        texts[language] ?? ""
    }

    private func isWinnerFinal(_ language: AppLanguage) -> Bool {
        finals[language] ?? false
    }

    func winningLanguage() -> AppLanguage? {
        if let lockedLanguage {
            return lockedLanguage
        }
        return inferredLock() ?? weakerGuess()
    }

    private func inferredLock() -> AppLanguage? {
        Self.lock(texts: texts, lastLanguage: lastLanguage)
    }

    private func weakerGuess() -> AppLanguage? {
        let present = texts.compactMap { language, text -> (AppLanguage, String)? in
            text.isEmpty ? nil : (language, text)
        }
        if present.isEmpty {
            return lastLanguage
        }
        if present.count == 1 {
            return present[0].0
        }
        return lastLanguage
    }

    static func lock(
        chinese: String,
        english: String,
        lastLanguage: AppLanguage?
    ) -> AppLanguage? {
        lock(texts: [.zhHans: chinese, .english: english], lastLanguage: lastLanguage)
    }

    static func lock(
        texts: [AppLanguage: String],
        lastLanguage: AppLanguage?
    ) -> AppLanguage? {
        let confident = AppLanguage.allCases.filter { language in
            isConfident(texts[language] ?? "", language: language)
        }
        if confident.count == 1 {
            return confident[0]
        }
        if confident.count > 1 {
            return confident.max { lhs, rhs in
                score(texts[lhs] ?? "", as: lhs) < score(texts[rhs] ?? "", as: rhs)
            } ?? lastLanguage
        }
        return nil
    }

    static func shouldPreempt(
        challenger: String,
        challengerLanguage: AppLanguage,
        incumbent: String,
        incumbentLanguage: AppLanguage
    ) -> Bool {
        guard isConfident(challenger, language: challengerLanguage) else { return false }
        if !isConfident(incumbent, language: incumbentLanguage) {
            return true
        }
        let challengerUnits = nativeUnits(challenger, language: challengerLanguage)
        let incumbentUnits = nativeUnits(incumbent, language: incumbentLanguage)
        return challengerUnits > incumbentUnits * 1.5 + 2
    }

    static func resolvedLanguage(claimed: AppLanguage, text: String) -> AppLanguage {
        if matchesClaimedLanguage(text, claimed: claimed) {
            return claimed
        }
        let matches = AppLanguage.allCases.filter { matchesClaimedLanguage(text, claimed: $0) }
        if matches.count == 1 {
            return matches[0]
        }
        return matches.max { lhs, rhs in
            score(text, as: lhs) < score(text, as: rhs)
        } ?? claimed
    }

    static func isConfident(_ text: String, language: AppLanguage) -> Bool {
        switch language {
        case .zhHans:
            return hanCount(text) >= 4
        case .english:
            return wordCount(text) >= 3 && letterCount(text) >= 10 && vietnameseMarkCount(text) < 2
        case .japanese:
            return kanaCount(text) >= 2 || (kanaCount(text) >= 1 && hanCount(text) >= 2)
        case .korean:
            return hangulCount(text) >= 4
        case .thai:
            return thaiCount(text) >= 4
        case .vietnamese:
            return wordCount(text) >= 2 && (vietnameseMarkCount(text) >= 1 || letterCount(text) >= 10)
        }
    }

    private struct LanguageVerdict {
        let accepted: Bool
        let scriptMismatch: Bool
    }

    /// One policy evaluation for acceptance plus the script-mismatch signal
    /// used for single-locale diagnostics.
    private static func languageVerdict(
        _ text: String,
        claimed: AppLanguage,
        purity: SpeechLanguagePurity
    ) -> LanguageVerdict {
        let scriptMismatch = !strictMatchesClaimedLanguage(text, claimed: claimed)
        switch purity {
        case .strict:
            return LanguageVerdict(accepted: !scriptMismatch, scriptMismatch: scriptMismatch)
        case .trustedLocale:
            return LanguageVerdict(
                accepted: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                scriptMismatch: scriptMismatch
            )
        }
    }

    /// Drop results that do not look like the transcriber's language at all.
    /// Dual-locale callers keep the strict default.
    static func matchesClaimedLanguage(
        _ text: String,
        claimed: AppLanguage,
        purity: SpeechLanguagePurity = .strict
    ) -> Bool {
        languageVerdict(text, claimed: claimed, purity: purity).accepted
    }

    /// True when the strict purity gate would reject `text` for `claimed`.
    /// Trusted single-locale sessions only record this signal for diagnostics.
    static func isScriptMismatch(_ text: String, claimed: AppLanguage) -> Bool {
        !strictMatchesClaimedLanguage(text, claimed: claimed)
    }

    private static func strictMatchesClaimedLanguage(_ text: String, claimed: AppLanguage) -> Bool {
        let han = hanCount(text)
        let latin = letterCount(text)
        let kana = kanaCount(text)
        let hangul = hangulCount(text)
        let thai = thaiCount(text)
        let viet = vietnameseMarkCount(text)
        switch claimed {
        case .zhHans:
            return han >= 1 && kana == 0 && hangul == 0 && thai == 0 && han >= latin
        case .english:
            return latin >= 2 && han == 0 && kana == 0 && hangul == 0 && thai == 0 && viet < 2
        case .japanese:
            return kana >= 1 || (han >= 1 && kana >= 1)
        case .korean:
            return hangul >= 1
        case .thai:
            return thai >= 1
        case .vietnamese:
            return (viet >= 1 || latin >= 2) && han == 0 && kana == 0 && hangul == 0 && thai == 0
        }
    }

    static func hanCount(_ text: String) -> Int {
        ScriptCounts.hanCount(text)
    }

    static func kanaCount(_ text: String) -> Int {
        ScriptCounts.kanaCount(text)
    }

    static func hangulCount(_ text: String) -> Int {
        ScriptCounts.hangulCount(text)
    }

    static func thaiCount(_ text: String) -> Int {
        ScriptCounts.thaiCount(text)
    }

    static func vietnameseMarkCount(_ text: String) -> Int {
        ScriptCounts.vietnameseMarkCount(text)
    }

    static func letterCount(_ text: String) -> Int {
        ScriptCounts.letterCount(text)
    }

    static func wordCount(_ text: String) -> Int {
        ScriptCounts.wordCount(text)
    }

    static func isHanScalar(_ scalar: UnicodeScalar) -> Bool {
        ScriptCounts.isHanScalar(scalar)
    }

    static func isKanaScalar(_ scalar: UnicodeScalar) -> Bool {
        ScriptCounts.isKanaScalar(scalar)
    }

    static func isHangulScalar(_ scalar: UnicodeScalar) -> Bool {
        ScriptCounts.isHangulScalar(scalar)
    }

    static func isThaiScalar(_ scalar: UnicodeScalar) -> Bool {
        ScriptCounts.isThaiScalar(scalar)
    }

    static func isVietnameseMarkScalar(_ scalar: UnicodeScalar) -> Bool {
        ScriptCounts.isVietnameseMarkScalar(scalar)
    }

    static func isLatinScalar(_ scalar: UnicodeScalar) -> Bool {
        ScriptCounts.isLatinScalar(scalar)
    }

    static func score(_ text: String, as language: AppLanguage) -> Double {
        nativeUnits(text, language: language)
    }

    static func nativeUnits(_ text: String, language: AppLanguage) -> Double {
        switch language {
        case .zhHans:
            return Double(hanCount(text))
        case .english:
            return Double(max(wordCount(text), letterCount(text) / 4))
        case .japanese:
            return Double(kanaCount(text) * 2 + hanCount(text))
        case .korean:
            return Double(hangulCount(text))
        case .thai:
            return Double(thaiCount(text))
        case .vietnamese:
            return Double(wordCount(text) + vietnameseMarkCount(text))
        }
    }
}
