import Foundation

struct UtteranceAssembler: Sendable {
    private struct FinalizedUtterance: Equatable, Sendable {
        let id: UUID
        let language: AppLanguage
        let text: String
        let at: Date
    }

    var lastLanguage: AppLanguage?
    private var utteranceID = UUID()
    private var texts: [AppLanguage: String] = [:]
    private var finals: [AppLanguage: Bool] = [:]
    private var lockedLanguage: AppLanguage?
    private var suppressOtherUntil = Date.distantPast
    private var latestFinal: FinalizedUtterance?
    private let reconciliationWindow: TimeInterval
    private let now: @Sendable () -> Date

    init(
        reconciliationWindow: TimeInterval = 3,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.reconciliationWindow = reconciliationWindow
        self.now = now
    }

    mutating func ingest(language: AppLanguage, text: String, isFinal: Bool) -> Utterance? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard Self.matchesClaimedLanguage(trimmed, claimed: language) else { return nil }

        if now() < suppressOtherUntil, let held = lastLanguage, language != held {
            return nil
        }
        if now() >= suppressOtherUntil, lockedLanguage != nil, texts.values.allSatisfy(\.isEmpty) {
            lockedLanguage = nil
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

        // A greeting name swap is a different person speaking and must start a
        // new utterance even while both greetings are still volatile. Compute
        // it before a language preemption can replace the lock, so a losing
        // language's stale text can never look like the current greeting.
        let previousInLanguage = textFor(language)
        let isGreetingNameSwap = (lockedLanguage == nil || lockedLanguage == language)
            && !previousInLanguage.isEmpty
            && SpokenText.isNameSwap(trimmed, of: previousInLanguage)

        if let locked = lockedLanguage, language != locked {
            let incumbent = textFor(locked)
            guard Self.shouldPreempt(
                challenger: trimmed,
                challengerLanguage: language,
                incumbent: incumbent,
                incumbentLanguage: locked
            ) else {
                return nil
            }
            clearText(for: locked)
            lockedLanguage = language
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

    mutating func silenceTimedOut() -> Utterance? {
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
        lastLanguage = nil
        lockedLanguage = nil
        suppressOtherUntil = .distantPast
        latestFinal = nil
        beginNextUtterance(keeping: nil)
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
        lockedLanguage = nil
    }

    private mutating func clearText(for language: AppLanguage) {
        texts[language] = ""
        finals[language] = false
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

    /// Drop results that do not look like the transcriber's language at all.
    static func matchesClaimedLanguage(_ text: String, claimed: AppLanguage) -> Bool {
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
