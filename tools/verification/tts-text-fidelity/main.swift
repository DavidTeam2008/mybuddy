import Darwin
import Foundation

// Bounded verifier for settled TTS text fidelity.
//
// The property: when a settled translation differs from what was already
// spoken, every meaning-bearing character of the new content must reach the
// synthesizer, no emitted clause may contain text absent from the final
// translation, and consuming the same final again must speak nothing new.
//
// This runs the real `ClauseSplitter.consume` in settled mode, which is the
// only mode production uses (`InterpretationViewModel.scheduleSpeech` guards
// on settle). The volatile branch is dead code and out of scope.
//
// The corpus is a fixed set of correction cases plus generated insertions over
// Chinese and English bases, and exhaustive small strings for the fabrication
// and idempotence checks. The baseline and reporting rules live in
// `.claude/skills/verify-tts-text-fidelity/SKILL.md`.

private struct FidelityCase {
    let name: String
    let language: AppLanguage
    let spoken: String
    let final: String
    let required: [String]
}

private struct Failure {
    let check: String
    let key: String
    let detail: String

    var fingerprintKey: String { check + "|" + key }
}

private let expectedTerminators = "，。！？；、：…—,;:!?."

private let contentIgnorable: CharacterSet = {
    var set = CharacterSet.whitespacesAndNewlines
    set.insert(charactersIn: expectedTerminators + "\"'“”‘’《》〈〉「」『』")
    return set
}()

private let expectedTerminatorScalars: [UnicodeScalar] = Array(expectedTerminators.unicodeScalars)

private func compact(_ text: String) -> String {
    var result = ""
    for scalar in text.unicodeScalars where !contentIgnorable.contains(scalar) {
        result.unicodeScalars.append(scalar)
    }
    return result
}

private func isSubsequence(_ needle: [Character], of haystack: [Character]) -> Bool {
    var index = 0
    for character in haystack {
        if index < needle.count, needle[index] == character {
            index += 1
        }
    }
    return index == needle.count
}

private func consume(
    _ final: String,
    spoken: String,
    _ language: AppLanguage
) -> (clauses: [Clause], spokenPrefix: String) {
    ClauseSplitter.consume(
        translated: final,
        utteranceID: UUID(),
        language: language,
        alreadySpoken: spoken,
        isSettled: true
    )
}

private func inserting(_ insertion: String, into base: String, at offset: Int) -> String {
    let index = base.index(base.startIndex, offsetBy: offset)
    return String(base[..<index]) + insertion + String(base[index...])
}

// MARK: - Corpus

private func handBuiltCases() -> [FidelityCase] {
    [
        FidelityCase(
            name: "zh-leading-negation",
            language: .zhHans,
            spoken: "那是3月18日",
            final: "不，那是3月18日，但他们把它改成了 15日。",
            required: ["不"]
        ),
        FidelityCase(
            name: "zh-middle-negation",
            language: .zhHans,
            spoken: "我同意这个计划",
            final: "我不同意这个计划。",
            required: ["不"]
        ),
        FidelityCase(
            name: "en-not",
            language: .english,
            spoken: "I agree with this plan",
            final: "I do not agree with this plan.",
            required: ["not"]
        ),
        FidelityCase(
            name: "zh-number-correction",
            language: .zhHans,
            spoken: "那是3月18日",
            final: "那是3月15日。",
            required: ["15"]
        ),
        FidelityCase(
            name: "en-no-carry",
            language: .english,
            spoken: "no,",
            final: "We have no time.",
            required: ["no"]
        ),
        FidelityCase(
            name: "en-period",
            language: .english,
            spoken: "Hello there",
            final: "Hello there.",
            required: []
        ),
        FidelityCase(
            name: "zh-same-text",
            language: .zhHans,
            spoken: "好的。",
            final: "好的。",
            required: []
        ),
    ]
}

private func generatedCases() -> [FidelityCase] {
    let bases: [(String, AppLanguage, [String])] = [
        ("那是3月18日", .zhHans, ["不", "没", "15"]),
        ("我同意这个计划", .zhHans, ["不", "没"]),
        ("I agree with this plan", .english, [" not ", " no ", "15"]),
    ]

    var cases: [FidelityCase] = []
    for (base, language, insertions) in bases {
        let offsets: [Int]
        if language == .english {
            var boundaries = [0]
            var index = base.startIndex
            while index < base.endIndex {
                if base[index] == " " {
                    boundaries.append(base.distance(from: base.startIndex, to: base.index(after: index)))
                }
                index = base.index(after: index)
            }
            offsets = boundaries
        } else {
            offsets = Array(0...base.count)
        }
        for insertion in insertions {
            for offset in offsets {
                let final = inserting(insertion, into: base, at: offset)
                cases.append(
                    FidelityCase(
                        name: "generated:\(language.rawValue):offset\(offset):\(insertion)",
                        language: language,
                        spoken: base,
                        final: final,
                        required: [insertion]
                    )
                )
            }
        }
    }
    return cases
}

// MARK: - Checks

private func runChecks(cases: [FidelityCase]) -> (failures: [Failure], modeling: [String], requiredCases: Int, exhaustiveCount: Int) {
    var failuresByKey: [String: Failure] = [:]
    var modeling: [String] = []
    var requiredCases = 0

    func record(_ failure: Failure) {
        failuresByKey[failure.fingerprintKey] = failure
    }

    for fidelityCase in cases {
        let finalCompact = compact(fidelityCase.final)
        for required in fidelityCase.required {
            let requiredCompact = compact(required)
            if requiredCompact.isEmpty {
                modeling.append("\(fidelityCase.name): required text is purely ignorable")
            } else if !finalCompact.contains(requiredCompact) {
                modeling.append("\(fidelityCase.name): final does not contain required text \(required)")
            }
        }
    }

    for scalar in expectedTerminatorScalars where !ClauseSplitter.terminators.contains(scalar) {
        record(
            Failure(
                check: "terminator-coverage",
                key: "missing:\(scalar)",
                detail: "ClauseSplitter.terminators is missing \(String(scalar))"
            )
        )
    }

    for fidelityCase in cases {
        if !fidelityCase.required.isEmpty { requiredCases += 1 }
        let result = consume(fidelityCase.final, spoken: fidelityCase.spoken, fidelityCase.language)
        let emitted = result.clauses.map(\.text).joined()
        let emittedCompact = compact(emitted)
        let finalCompact = compact(fidelityCase.final)

        if !fidelityCase.required.isEmpty {
            let covered = fidelityCase.required.allSatisfy { required in
                let requiredCompact = compact(required)
                return emittedCompact.contains(requiredCompact) || emittedCompact.contains(finalCompact)
            }
            if !covered {
                record(
                    Failure(
                        check: "insertion-coverage",
                        key: fidelityCase.name,
                        detail: "spoken=\"\(fidelityCase.spoken)\" final=\"\(fidelityCase.final)\" required=\(fidelityCase.required) emitted=\(result.clauses.map(\.text))"
                    )
                )
            }
        }

        for clause in result.clauses {
            let clauseCompact = compact(clause.text)
            if !isSubsequence(Array(clauseCompact), of: Array(finalCompact)) {
                record(
                    Failure(
                        check: "no-fabrication",
                        key: fidelityCase.name,
                        detail: "clause \"\(clause.text)\" is not a subsequence of final \"\(fidelityCase.final)\""
                    )
                )
            }

            let trimmed = clause.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, compact(trimmed).isEmpty {
                record(
                    Failure(
                        check: "punctuation-only-clause",
                        key: fidelityCase.name,
                        detail: "emitted punctuation-only clause \"\(clause.text)\" for final \"\(fidelityCase.final)\""
                    )
                )
            }
        }

        let second = consume(fidelityCase.final, spoken: result.spokenPrefix, fidelityCase.language)
        if !second.clauses.isEmpty || second.spokenPrefix != result.spokenPrefix {
            record(
                Failure(
                    check: "idempotent-settle",
                    key: fidelityCase.name,
                    detail: "second consume emitted \(second.clauses.map(\.text)) and prefix \"\(second.spokenPrefix)\" != \"\(result.spokenPrefix)\""
                )
            )
        }
    }

    let alphabet: [Character] = ["a", "b", "。", "，", " ", "."]
    var current = [""]
    var strings = [""]
    for _ in 0..<4 {
        var next: [String] = []
        for prefix in current {
            for character in alphabet {
                next.append(prefix + String(character))
            }
        }
        strings.append(contentsOf: next)
        current = next
    }

    for text in strings {
        let first = consume(text, spoken: "", .english)
        let compactText = compact(text)
        for clause in first.clauses {
            let clauseCompact = compact(clause.text)
            if !isSubsequence(Array(clauseCompact), of: Array(compactText)) {
                record(
                    Failure(
                        check: "no-fabrication",
                        key: "exhaustive:\(text)",
                        detail: "clause \"\(clause.text)\" is not a subsequence of \"\(text)\""
                    )
                )
                break
            }
        }
        let second = consume(text, spoken: first.spokenPrefix, .english)
        if !second.clauses.isEmpty || second.spokenPrefix != first.spokenPrefix {
            record(
                Failure(
                    check: "idempotent-settle",
                    key: "exhaustive:\(text)",
                    detail: "second consume emitted \(second.clauses.map(\.text)) and prefix \"\(second.spokenPrefix)\" != \"\(first.spokenPrefix)\""
                )
            )
        }
    }

    return (Array(failuresByKey.values), modeling, requiredCases, strings.count)
}

// MARK: - Reporting

private func fingerprint(_ failures: [Failure]) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for key in failures.map(\.fingerprintKey).sorted() {
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
    print("Usage: verify")
    print("  Exit 0 = clean, 1 = fidelity violations, 3 = modeling error.")
}

// MARK: - Entry point

if CommandLine.arguments.contains("-h") || CommandLine.arguments.contains("--help") {
    usage()
    exit(0)
}

private let started = Date()
private let cases = handBuiltCases() + generatedCases()
private let run = runChecks(cases: cases)
private let elapsed = Date().timeIntervalSince(started)

if !run.modeling.isEmpty {
    print("MODELING ERROR: the corpus no longer expresses the documented cases.")
    for message in run.modeling { print("  - \(message)") }
    print("Update the corpus in tools/verification/tts-text-fidelity/main.swift")
    print("and the coverage record in .claude/skills/verify-tts-text-fidelity/SKILL.md.")
    exit(3)
}
if cases.isEmpty || run.requiredCases == 0 || run.exhaustiveCount == 0 {
    print("MODELING ERROR: a check has no cases to run.")
    exit(3)
}

private let grouped = Dictionary(grouping: run.failures, by: \.check)
print("Settled TTS text fidelity")
print("Real code: Duiyi/Domain/Models/Clause.swift (ClauseSplitter.consume, settled mode)")
print("Checks: insertion-coverage, no-fabrication, idempotent-settle, terminator-coverage, punctuation-only-clause")
print("Corpus: \(handBuiltCases().count) hand-built + \(generatedCases().count) generated cases; \(run.exhaustiveCount) exhaustive strings")
print(String(format: "Elapsed: %.2fs", elapsed))
print("")

let allChecks = [
    "insertion-coverage",
    "no-fabrication",
    "idempotent-settle",
    "terminator-coverage",
    "punctuation-only-clause",
]
for check in allChecks {
    let failures = (grouped[check] ?? []).sorted {
        let lhsGenerated = $0.key.hasPrefix("generated:")
        let rhsGenerated = $1.key.hasPrefix("generated:")
        if lhsGenerated != rhsGenerated { return !lhsGenerated }
        return $0.key < $1.key
    }
    print("\(check): \(failures.isEmpty ? "clean" : "\(failures.count) failure(s)")")
    for failure in failures.prefix(8) {
        print("  [\(failure.key)] \(failure.detail)")
    }
    print("")
}

print("trace-set fingerprint: \(fingerprint(run.failures))")
if run.failures.isEmpty {
    print("RESULT: clean. No fidelity violation in the corpus.")
    exit(0)
}
print("RESULT: \(run.failures.count) distinct fidelity violation(s).")
print("Expected baseline and how to read this: .claude/skills/verify-tts-text-fidelity/SKILL.md")
exit(1)
