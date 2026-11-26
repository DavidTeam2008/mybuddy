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
        var text: String
        var at: Date
    }

    /// A phrase gap larger than this starts a new utterance even when the
    /// previous final did not end with sentence punctuation.
    private static let rangeGapLimit: TimeInterval = 0.75
    /// Recently closed rows remembered for a late same-range final.
    private static let closedRangeHistoryLimit = 8

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
    private var publishedFinalForCurrentID = false
    private let reconciliationWindow: TimeInterval
    private let now: @Sendable () -> Date

    init(
        reconciliationWindow: TimeInterval = 3,
        languagePurity: SpeechLanguagePurity = .strict,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.reconciliationWindow = reconciliationWindow
        self.languagePurity = languagePurity
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
        guard let range else {
            return ingestByText(language: language, text: text, isFinal: isFinal)
        }
        return ingestRangeAware(
            language: language,
            text: text,
            isFinal: isFinal,
            range: range
        )
    }

    /// True while a row has volatile text the silence timer can finalize.
    /// A row that already received only transcriber finals is closed.
    var hasOpenRange: Bool {
        rangeStates.values.contains { $0.volatile != nil }
    }

    private mutating func ingestByText(
        language: AppLanguage,
        text: String,
        isFinal: Bool
    ) -> Utterance? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard passesPurityGate(trimmed, language: language),
              passesSuppressionGate(language: language) else {
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

        guard preemptsIfNeeded(language: language, text: trimmed) else { return nil }

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
    /// where a phrase continues, punctuation decides where the sentence ends,
    /// and a late final for a closed range revises that row in place.
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
            return revokeRange(language: language, range: range)
        }

        guard passesPurityGate(trimmed, language: language),
              passesSuppressionGate(language: language) else {
            return nil
        }

        // A late volatile for an already-closed range must not revive or
        // pollute the newer row.
        if !isFinal, closedRangeMatch(language: language, range: range) != nil {
            return nil
        }

        // A final for a range the silence timer already closed belongs to that
        // row even while a newer row is live. This replaces the old prefix
        // heuristic with the audio range Apple actually sent.
        if isFinal, let closed = closedRangeMatch(language: language, range: range) {
            // A late final is authoritative even when it is shorter than the
            // synthetic text it replaces (P0-2 final-wins).
            updateClosedRange(id: closed.id, language: language, range: range, text: trimmed)
            latestFinal = FinalizedUtterance(
                id: closed.id,
                language: language,
                text: trimmed,
                at: now()
            )
            return Utterance(
                id: closed.id,
                language: language,
                text: trimmed,
                isFinal: true,
                isRevision: true
            )
        }

        // A published final closes the row for identity. A different language
        // is a new utterance; remember the old range so a late final can still
        // revise it, then start the new row.
        if let finalized = latestFinal,
           finalized.id == utteranceID,
           language != finalized.language {
            guard Self.isConfident(trimmed, language: language) else { return nil }
            closeCurrentRangeRow(
                language: finalized.language,
                text: textFor(finalized.language)
            )
            beginNextUtterance(keeping: language)
        }

        var state = rangeStates[language] ?? LanguageRangeState()
        let previousText = texts[language] ?? ""
        let isGreetingNameSwap = (lockedLanguage == nil || lockedLanguage == language)
            && !previousText.isEmpty
            && SpokenText.isNameSwap(trimmed, of: previousText)

        if isGreetingNameSwap {
            // Do not remember the old greeting's range: a final for that same
            // audio belongs to the new person's row, not the name it replaced.
            beginNextUtterance(keeping: language)
            state = LanguageRangeState()
        }

        guard preemptsIfNeeded(language: language, text: trimmed) else { return nil }

        // A phrase after a real audio gap starts a new utterance even when the
        // transcriber did not add sentence punctuation. This covers both a new
        // volatile phrase and a final that follows the gap.
        let lastEnd = state.volatile?.range.end ?? state.finalized.last?.range.end
        if let lastEnd, range.start > lastEnd + Self.rangeGapLimit {
            closeCurrentRangeRow(language: language, text: textFor(language))
            beginNextUtterance(keeping: language)
            state = LanguageRangeState()
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
            if Self.endsSentence(winnerText) {
                closeCurrentRangeRow(language: winner, text: winnerText)
                beginNextUtterance(keeping: winner)
                hold(winner, for: 0.8)
            }
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
        // A result for an already-finalized phrase revises that phrase.
        if let index = state.finalized.firstIndex(where: { $0.range.overlaps(range) }) {
            if isFinal {
                state.finalized[index].text = text
                state.finalized[index].range = state.finalized[index].range.union(range)
                state.volatile = nil
            }
            return
        }

        if let volatile = state.volatile, volatile.range.overlaps(range) {
            if isFinal {
                state.finalized.append(
                    RangePhrase(text: text, range: volatile.range.union(range))
                )
                state.volatile = nil
            } else {
                state.volatile = RangePhrase(text: text, range: volatile.range.union(range))
            }
            return
        }

        if isFinal {
            // The final covers the open range; any unresolved volatile guess
            // is superseded.
            state.volatile = nil
            if let last = state.finalized.last, last.range.overlaps(range) {
                state.finalized[state.finalized.count - 1].text = text
                state.finalized[state.finalized.count - 1].range = last.range.union(range)
            } else {
                state.finalized.append(RangePhrase(text: text, range: range))
            }
        } else {
            // A newer volatile interpretation replaces the open phrase.
            state.volatile = RangePhrase(text: text, range: range)
        }
    }

    private mutating func refreshTexts(
        for language: AppLanguage,
        state: LanguageRangeState
    ) {
        var parts = state.finalized.map(\.text)
        if let volatile = state.volatile {
            parts.append(volatile.text)
        }
        texts[language] = Self.joinPhrases(parts)
        finals[language] = !state.finalized.isEmpty && state.volatile == nil
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
        language: AppLanguage,
        range: SpeechRange,
        text: String
    ) {
        guard let index = closedRanges.lastIndex(where: { $0.id == id }) else { return }
        var closed = closedRanges[index]
        closed.range = closed.range.union(range)
        closed.text = text
        closed.at = now()
        closedRanges[index] = closed
    }

    private mutating func closeCurrentRangeRow(language: AppLanguage, text: String) {
        guard let range = currentRange(for: language) else { return }
        closedRanges.append(
            ClosedRangeUtterance(
                id: utteranceID,
                language: language,
                range: range,
                text: text,
                at: now()
            )
        )
        trimClosedRanges()
    }

    private func currentRange(for language: AppLanguage) -> SpeechRange? {
        guard let state = rangeStates[language] else { return nil }
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
        guard let state = rangeStates[winner], state.volatile != nil else {
            // The transcriber already finalized the open range.
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
        publishedFinalForCurrentID = true
        latestFinal = FinalizedUtterance(
            id: utterance.id,
            language: utterance.language,
            text: utterance.text,
            at: now()
        )
        closeCurrentRangeRow(language: winner, text: winnerText)
        beginNextUtterance(keeping: winner)
        hold(winner, for: 0.8)
        return utterance
    }

    private static func joinPhrases(_ parts: [String]) -> String {
        var joined = ""
        for part in parts {
            let piece = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if let last = joined.last, let first = piece.first,
               requiresSpace(between: last, and: first) {
                joined.append(" ")
            }
            joined += piece
        }
        return joined
    }

    private static func requiresSpace(between left: Character, and right: Character) -> Bool {
        guard !left.isWhitespace, !right.isWhitespace else { return false }
        guard (left.isLetter || left.isNumber), (right.isLetter || right.isNumber) else {
            return false
        }
        let leftIsCJK = isCJK(left)
        let rightIsCJK = isCJK(right)
        if leftIsCJK || rightIsCJK {
            // Only a CJK/Latin boundary gets a space; CJK punctuation and CJK
            // characters stay unspaced.
            return leftIsCJK != rightIsCJK
        }
        return true
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            isHanScalar($0) || isKanaScalar($0) || isHangulScalar($0) || isThaiScalar($0)
        }
    }

    private static func endsSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var index = trimmed.endIndex
        while index > trimmed.startIndex {
            let previous = trimmed.index(before: index)
            let character = trimmed[previous]
            if "\"'”’)]）】」』".contains(character) {
                index = previous
                continue
            }
            return ".?!。？！".contains(character)
        }
        return false
    }

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

    private mutating func preemptsIfNeeded(language: AppLanguage, text: String) -> Bool {
        guard let locked = lockedLanguage, language != locked else { return true }
        let incumbent = textFor(locked)
        guard Self.shouldPreempt(
            challenger: text,
            challengerLanguage: language,
            incumbent: incumbent,
            incumbentLanguage: locked
        ) else {
            return false
        }
        rangeStates.removeValue(forKey: locked)
        clearText(for: locked)
        lockedLanguage = language
        return true
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
