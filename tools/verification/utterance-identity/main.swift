import Darwin
import Foundation

// Bounded exhaustive verifier for the D8 promise that one `Utterance.id`
// names exactly one logical utterance.
//
// This runs the real `UtteranceAssembler` (not a hand model) with an injected
// clock. Every event sequence of exactly `--depth` events over the alphabet
// below is replayed once per identity property; a violation in any prefix is
// reported. A shorter sequence is a prefix of some longer one, so exploring
// fixed-length sequences covers every sequence up to the bound.
//
// The harness pins the assembler's default `.strict` language purity, which is
// what the dual-locale pipelines and Meeting use. The single-locale
// `.trustedLocale` path is outside this check.
//
// The properties, corpus, baseline, and reporting rules are documented in
// `.claude/skills/verify-utterance-identity/SKILL.md`. Read that before
// changing the alphabet or the corpus.

// MARK: - Corpus

private enum Corpus {
    static let englishBase = "I would like a cup of coffee"
    static let englishExtension = "I would like a cup of coffee with milk"
    static let englishUnrelated = "The train leaves at seven tomorrow morning"
    static let englishFiller = "um"
    static let englishGreetingA = "Hi Jack"
    static let englishGreetingB = "Hi Lucy"
    // 13 Han characters, so the challenger clears shouldPreempt's 1.5x + 2 bar
    // against englishBase (7 native units).
    static let chineseBase = "我想点一杯咖啡，谢谢你的服务"
}

private enum Property {
    static let finalizedTextIdentity = "finalized-text-identity"
    static let settledLanguageIdentity = "settled-language-identity"
    static let all = [finalizedTextIdentity, settledLanguageIdentity]
}

// MARK: - Events

private enum Event: CaseIterable {
    case englishBaseFinal
    case englishBaseVolatile
    case englishExtensionFinal
    case englishExtensionVolatile
    case englishUnrelatedFinal
    case englishUnrelatedVolatile
    case englishFillerVolatile
    case englishGreetingAFinal
    case englishGreetingBFinal
    case chineseBaseFinal
    case chineseBaseVolatile
    case silenceTimedOut
    case advanceHalfSecond
    case advanceThreeAndHalfSeconds
    case reset

    var label: String {
        switch self {
        case .englishBaseFinal: return "ingest(en,base,final)"
        case .englishBaseVolatile: return "ingest(en,base,volatile)"
        case .englishExtensionFinal: return "ingest(en,extension,final)"
        case .englishExtensionVolatile: return "ingest(en,extension,volatile)"
        case .englishUnrelatedFinal: return "ingest(en,unrelated,final)"
        case .englishUnrelatedVolatile: return "ingest(en,unrelated,volatile)"
        case .englishFillerVolatile: return "ingest(en,filler,volatile)"
        case .englishGreetingAFinal: return "ingest(en,greetingA,final)"
        case .englishGreetingBFinal: return "ingest(en,greetingB,final)"
        case .chineseBaseFinal: return "ingest(zh,base,final)"
        case .chineseBaseVolatile: return "ingest(zh,base,volatile)"
        case .silenceTimedOut: return "silenceTimedOut"
        case .advanceHalfSecond: return "advance(0.5s)"
        case .advanceThreeAndHalfSeconds: return "advance(3.5s)"
        case .reset: return "reset"
        }
    }

    /// Events that call `UtteranceAssembler.ingest`. The engine acknowledges a
    /// non-revision final after exactly these calls, never after the silence
    /// timer's `silenceTimedOut`.
    var isIngest: Bool {
        switch self {
        case .englishBaseFinal, .englishBaseVolatile,
             .englishExtensionFinal, .englishExtensionVolatile,
             .englishUnrelatedFinal, .englishUnrelatedVolatile,
             .englishFillerVolatile,
             .englishGreetingAFinal, .englishGreetingBFinal,
             .chineseBaseFinal, .chineseBaseVolatile:
            return true
        case .silenceTimedOut, .advanceHalfSecond, .advanceThreeAndHalfSeconds, .reset:
            return false
        }
    }

    /// Events that must produce at least one emitted utterance somewhere in the
    /// exploration; otherwise the alphabet stopped exercising the assembler.
    var mustEmit: Bool {
        isIngest || self == .silenceTimedOut
    }
}

// MARK: - Clock and state

private final class ClockBox: @unchecked Sendable {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

private struct IDRecord {
    var firstFinalLanguage: AppLanguage?
    var lastFinalText: String?
    var lastFinalLanguage: AppLanguage?
}

private struct Violation {
    let property: String
    let trace: [String]
    let detail: String

    var key: String { property + "|" + trace.joined(separator: " -> ") }
}

private struct ExploreResult {
    var violations: [String: [String: Violation]] = [:]
    var sequencesHit: [String: Int] = [:]
    var emissionsByEvent: [Int: Int] = [:]
}

private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

// MARK: - One replay

private func apply(
    _ event: Event,
    clock: ClockBox,
    assembler: inout UtteranceAssembler
) -> Utterance? {
    switch event {
    case .englishBaseFinal:
        return assembler.ingest(language: .english, text: Corpus.englishBase, isFinal: true)
    case .englishBaseVolatile:
        return assembler.ingest(language: .english, text: Corpus.englishBase, isFinal: false)
    case .englishExtensionFinal:
        return assembler.ingest(language: .english, text: Corpus.englishExtension, isFinal: true)
    case .englishExtensionVolatile:
        return assembler.ingest(language: .english, text: Corpus.englishExtension, isFinal: false)
    case .englishUnrelatedFinal:
        return assembler.ingest(language: .english, text: Corpus.englishUnrelated, isFinal: true)
    case .englishUnrelatedVolatile:
        return assembler.ingest(language: .english, text: Corpus.englishUnrelated, isFinal: false)
    case .englishFillerVolatile:
        return assembler.ingest(language: .english, text: Corpus.englishFiller, isFinal: false)
    case .englishGreetingAFinal:
        return assembler.ingest(language: .english, text: Corpus.englishGreetingA, isFinal: true)
    case .englishGreetingBFinal:
        return assembler.ingest(language: .english, text: Corpus.englishGreetingB, isFinal: true)
    case .chineseBaseFinal:
        return assembler.ingest(language: .zhHans, text: Corpus.chineseBase, isFinal: true)
    case .chineseBaseVolatile:
        return assembler.ingest(language: .zhHans, text: Corpus.chineseBase, isFinal: false)
    case .silenceTimedOut:
        return assembler.silenceTimedOut()
    case .advanceHalfSecond:
        clock.now = clock.now.addingTimeInterval(0.5)
        return nil
    case .advanceThreeAndHalfSeconds:
        clock.now = clock.now.addingTimeInterval(3.5)
        return nil
    case .reset:
        assembler.reset()
        return nil
    }
}

/// The assembler's own notion of one logical utterance: the guard that decides
/// between `beginNextUtterance` and an in-place update at
/// `UtteranceAssembler.swift:141-149`.
private func isSameUtterance(_ incoming: String, _ previous: String, language: AppLanguage) -> Bool {
    SpokenText.isContinuation(incoming, of: previous, language: language)
        || SpokenText.isRefinement(incoming, of: previous)
}

private func short(_ id: UUID) -> String {
    String(id.uuidString.prefix(8))
}

private func violations(
    for utterance: Utterance,
    trace: [String],
    records: inout [UUID: IDRecord]
) -> [Violation] {
    guard utterance.isFinal else { return [] }

    var found: [Violation] = []
    var record = records[utterance.id] ?? IDRecord()

    if let lastText = record.lastFinalText,
       record.lastFinalLanguage == utterance.language,
       !isSameUtterance(utterance.text, lastText, language: utterance.language) {
        found.append(
            Violation(
                property: Property.finalizedTextIdentity,
                trace: trace,
                detail: "id \(short(utterance.id)) was finalized as \"\(lastText)\", then finalized as unrelated \"\(utterance.text)\""
            )
        )
    }

    if let firstLanguage = record.firstFinalLanguage,
       firstLanguage != utterance.language {
        found.append(
            Violation(
                property: Property.settledLanguageIdentity,
                trace: trace,
                detail: "id \(short(utterance.id)) was first finalized in \(firstLanguage.rawValue), then finalized in \(utterance.language.rawValue) as \"\(utterance.text)\""
            )
        )
    }

    if record.firstFinalLanguage == nil {
        record.firstFinalLanguage = utterance.language
    }
    record.lastFinalText = utterance.text
    record.lastFinalLanguage = utterance.language
    records[utterance.id] = record
    return found
}

private func replay(
    _ indices: [Int],
    alphabet: [Event],
    emissionsByEvent: inout [Int: Int]
) -> [String: Violation] {
    let clock = ClockBox(baseDate)
    var assembler = UtteranceAssembler(now: { clock.now })
    var records: [UUID: IDRecord] = [:]
    var trace: [String] = []
    trace.reserveCapacity(indices.count)
    var firstViolation: [String: Violation] = [:]

    for index in indices {
        let event = alphabet[index]
        trace.append(event.label)
        guard let utterance = apply(event, clock: clock, assembler: &assembler) else { continue }
        emissionsByEvent[index, default: 0] += 1

        for violation in violations(for: utterance, trace: trace, records: &records)
        where firstViolation[violation.property] == nil {
            firstViolation[violation.property] = violation
        }
        // Every property has already witnessed its first violation in this
        // sequence; later steps cannot add a new property finding for it.
        if firstViolation.count == Property.all.count { break }

        // The engine acknowledges every non-revision final that came from the
        // transcriber; the silence timer does not go through this call.
        if event.isIngest, utterance.isFinal, !utterance.isRevision {
            assembler.acknowledgeFinal(language: utterance.language)
        }
    }
    return firstViolation
}

private func explore(depth: Int) -> ExploreResult {
    let alphabet = Event.allCases
    var result = ExploreResult()
    var indices = [Int](repeating: 0, count: depth)

    while true {
        let found = replay(indices, alphabet: alphabet, emissionsByEvent: &result.emissionsByEvent)
        for (property, violation) in found {
            result.violations[property, default: [:]][violation.key] = violation
            result.sequencesHit[property, default: 0] += 1
        }

        var position = depth - 1
        while position >= 0 {
            indices[position] += 1
            if indices[position] < alphabet.count { break }
            indices[position] = 0
            position -= 1
        }
        if position < 0 { break }
    }
    return result
}

// MARK: - Corpus preconditions

/// A failure here means the corpus no longer expresses the relations the skill
/// documents (for example, a heuristic change made "unrelated" count as a
/// refinement). That is a modeling error, not a product finding.
private func corpusPreconditions() -> [String] {
    var failures: [String] = []

    func require(_ condition: Bool, _ message: String) {
        if !condition { failures.append(message) }
    }

    require(
        isSameUtterance(Corpus.englishExtension, Corpus.englishBase, language: .english),
        "englishExtension must be a continuation/refinement of englishBase"
    )
    require(
        !isSameUtterance(Corpus.englishUnrelated, Corpus.englishBase, language: .english)
            && !isSameUtterance(Corpus.englishBase, Corpus.englishUnrelated, language: .english),
        "englishUnrelated and englishBase must be unrelated in both directions"
    )
    require(
        !isSameUtterance(Corpus.englishUnrelated, Corpus.englishExtension, language: .english)
            && !isSameUtterance(Corpus.englishExtension, Corpus.englishUnrelated, language: .english),
        "englishUnrelated and englishExtension must be unrelated in both directions"
    )
    require(
        UtteranceAssembler.isConfident(Corpus.englishBase, language: .english),
        "englishBase must be confident English so the row locks"
    )
    require(
        UtteranceAssembler.isConfident(Corpus.englishExtension, language: .english),
        "englishExtension must be confident English"
    )
    require(
        UtteranceAssembler.isConfident(Corpus.englishUnrelated, language: .english),
        "englishUnrelated must be confident English"
    )
    require(
        !UtteranceAssembler.isConfident(Corpus.englishFiller, language: .english),
        "englishFiller must stay non-confident"
    )
    require(
        UtteranceAssembler.matchesClaimedLanguage(Corpus.englishFiller, claimed: .english),
        "englishFiller must be accepted by the strict script gate"
    )
    require(
        UtteranceAssembler.isConfident(Corpus.chineseBase, language: .zhHans),
        "chineseBase must be confident Chinese so it can preempt"
    )
    require(
        UtteranceAssembler.shouldPreempt(
            challenger: Corpus.chineseBase,
            challengerLanguage: .zhHans,
            incumbent: Corpus.englishBase,
            incumbentLanguage: .english
        ),
        "chineseBase must clear shouldPreempt against englishBase"
    )
    require(
        SpokenText.isNameSwap(Corpus.englishGreetingB, of: Corpus.englishGreetingA),
        "englishGreetingB must read as a greeting name swap of englishGreetingA"
    )
    require(
        !isSameUtterance(Corpus.englishGreetingB, Corpus.englishGreetingA, language: .english),
        "englishGreetingB must not also count as a continuation of englishGreetingA"
    )
    return failures
}

// MARK: - Reporting

private func fingerprint(of keys: [String]) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for key in keys.sorted() {
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        hash ^= 0x0a
        hash = hash &* 0x100000001b3
    }
    return String(format: "%016llx", hash)
}

private func usage() {
    print("Usage: verify [--depth N]")
    print("  Replays every event sequence of exactly N events over the corpus.")
    print("  Default depth: 5.")
    print("  Exit 0 = clean, 1 = identity violations, 2 = usage/bad argument,")
    print("  3 = modeling error (corpus precondition or event coverage changed).")
}

// MARK: - Entry point

private var depth = 5
private var arguments = Array(CommandLine.arguments.dropFirst())
while let argument = arguments.first {
    switch argument {
    case "--depth":
        arguments.removeFirst()
        guard let value = arguments.first, let parsed = Int(value), parsed >= 1, parsed <= 7 else {
            FileHandle.standardError.write(Data("invalid --depth (1...7)\n".utf8))
            exit(2)
        }
        depth = parsed
        arguments.removeFirst()
    case "-h", "--help":
        usage()
        exit(0)
    default:
        FileHandle.standardError.write(Data("unknown argument: \(argument)\n".utf8))
        usage()
        exit(2)
    }
}

let modelingFailures = corpusPreconditions()
if !modelingFailures.isEmpty {
    print("MODELING ERROR: the corpus no longer matches the documented relations.")
    for failure in modelingFailures {
        print("  - \(failure)")
    }
    print("Update the corpus in tools/verification/utterance-identity/main.swift")
    print("and the coverage record in .claude/skills/verify-utterance-identity/SKILL.md.")
    exit(3)
}

private let alphabet = Event.allCases
let sequences = Int(pow(Double(alphabet.count), Double(depth)))
let started = Date()

private let result = explore(depth: depth)

let elapsed = Date().timeIntervalSince(started)

var silentEvents: [String] = []
for (index, event) in alphabet.enumerated() where event.mustEmit {
    if result.emissionsByEvent[index, default: 0] == 0 {
        silentEvents.append(event.label)
    }
}
if !silentEvents.isEmpty {
    print("MODELING ERROR: these events never produced an utterance:")
    for label in silentEvents { print("  - \(label)") }
    exit(3)
}

print("Utterance identity verification (D8)")
print("Real code: Duiyi/Services/Speech/UtteranceAssembler.swift + Domain types")
print("Purity: .strict (single-locale .trustedLocale is outside this check)")
print("Alphabet: \(alphabet.count) events, bound: exactly \(depth) events = \(sequences) sequences")
print("Properties:")
print("  \(Property.finalizedTextIdentity)   consecutive finals under one id must stay continuations/refinements")
print("  \(Property.settledLanguageIdentity) an id must keep the language of its first final")
print(String(format: "Elapsed: %.2fs", elapsed))
print("")

var anyViolations = false
for property in Property.all {
    let found = result.violations[property] ?? [:]
    if found.isEmpty {
        print("\(property): clean up to the bound")
        print("")
        continue
    }
    anyViolations = true
    let violations = found.values.sorted {
        if $0.trace.count != $1.trace.count { return $0.trace.count < $1.trace.count }
        return $0.trace.joined(separator: ">") < $1.trace.joined(separator: ">")
    }
    let minimumLength = violations.first?.trace.count ?? 0
    let atMinimum = violations.filter { $0.trace.count == minimumLength }
    print("\(property): \(violations.count) distinct trace(s), \(result.sequencesHit[property, default: 0]) sequence(s) with a first violation")
    print("  minimum trace length: \(minimumLength); \(atMinimum.count) trace(s) at that length")
    print("  trace-set fingerprint: \(fingerprint(of: violations.map(\.key)))")
    for violation in atMinimum.prefix(10) {
        print("  shortest: \(violation.trace.joined(separator: " -> "))")
        print("    \(violation.detail)")
    }
    print("")
}

if anyViolations {
    print("RESULT: identity violations found.")
    print("Expected state and how to read this: .claude/skills/verify-utterance-identity/SKILL.md")
    exit(1)
}

print("RESULT: clean. No identity violation up to the bound.")
exit(0)
