---
name: verify-tts-text-fidelity
description: Bounded verification of settled TTS text fidelity in ClauseSplitter. Use when changing ClauseSplitter.consume, unspokenRemnants, compactSpan, subsequenceTail, spokenCursor, or the terminator set. Checks that new meaning-bearing content is spoken, nothing is fabricated, and a second consume speaks nothing new. The caller's queue and scheduling are not executed.
---

# Verify settled TTS text fidelity

**Property.** When a settled translation adds or corrects meaning-bearing content relative to what was already spoken, the emitted clauses must contain that new content. No clause may contain text absent from the final translation, and consuming the same final again must speak nothing new.

**Harm if broken.** The synthesizer can silently drop a negation or a corrected number. The listener hears a meaning inversion or a fragment, with no visible error. This violates the release blocker that TTS must not read half a sentence.

## Why this tool

Swift has no practical code-level verifier. The risk lives in the Unicode and alignment heuristics of `ClauseSplitter`, so a hand model or TLA+ model would re-encode the logic under test. The real function is fast enough to run directly. The 7 hand-built cases, 55 generated insertions, and 1,555 exhaustive small strings finish in well under a second. The checker calls the compiled real code, not a model.

## What is verified

The real `ClauseSplitter.consume` with `isSettled: true`. Production only uses this mode (`InterpretationViewModel.scheduleSpeech` guards on settle); the volatile branch is dead code and out of scope.

| Check | What it asserts |
| --- | --- |
| `insertion-coverage` | For every case, the concatenated clauses contain each required new string, or they re-speak the whole final |
| `no-fabrication` | Every emitted clause is a character subsequence of the final translation |
| `idempotent-settle` | Consuming the same final again with the returned `spokenPrefix` emits nothing and keeps the cursor |
| `terminator-coverage` | Every expected sentence-final punctuation scalar, including ASCII `.`, is in `ClauseSplitter.terminators` |
| `punctuation-only-clause` | No emitted clause consists only of expected terminators and whitespace |

Corpus: 7 hand-built correction cases, 55 generated insertions over Chinese and English bases, and all strings up to length 4 over `{a, b, 。, ，, space, .}`. Corpus preconditions fail the run with exit 3 when a required string is absent from the final or purely ignorable.

Covered code: `Duiyi/Domain/Models/Clause.swift` (`consume` settled path, `unspokenRemnants`, `compactSpan`, `subsequenceTail`, `spokenCursor`, `stripLeadingTerminators`, `terminators`) and `AppLanguage.usesLatinScript`.

Not covered: the volatile branch and `splitClauses` (production never reaches them), the caller's clause queue, dedupe, and 380 ms settle scheduling (`InterpretationViewModel`), actual `AVSpeechSynthesizer` output, languages beyond the corpus, arbitrary Unicode beyond the bounded alphabet, and `shouldCarry` policy (cases pass `alreadySpoken` directly).

## Run

```bash
tools/verify-tts-text-fidelity.sh
```

- No simulator, no network, no third-party dependency. It uses `xcrun swiftc` and the real sources.
- Reference toolchain: Xcode 27.1 / Apple Swift 6.4 on Apple silicon. About 5 s total, dominated by the Swift compile; the checks report their own elapsed time.
- Exit codes: `0` clean; `1` fidelity violations (the expected baseline while the findings below are open); `2` usage, missing toolchain, or compile failure; `3` modeling error (corpus precondition or empty check).

## Read the output

Each check line gives its failure count or says `clean`. A failure shows the case name, the spoken text, the final text, the required new text, and the emitted clauses. `insertion-coverage` failures name the dropped meaning-bearing content; `punctuation-only-clause` names the clause and final; `terminator-coverage` names the missing scalar. The trace-set fingerprint covers every distinct failure.

## Current baseline (recorded 2026-11-27, sources at `df18973`)

The run exits `1` with 29 distinct failures, fingerprint `101d55531e2df6e8`. Rechecked after merging `origin/main` at `84a880f`: the same 29 findings and fingerprint. `Clause.swift` is unchanged by the merge.

- **`insertion-coverage`: 26 failures** (5 hand-built, 21 generated).
  - `zh-leading-negation`: spoken `那是3月18日`, final `不，那是3月18日，但他们把它改成了 15日。`, required `不`, emitted `["但他们把它改成了 15日。"]`. The new negation is dropped.
  - `zh-middle-negation`: spoken `我同意这个计划`, final `我不同意这个计划。`, required `不`, emitted `[]`. Nothing is spoken.
  - `en-not`: spoken `I agree with this plan`, final `I do not agree with this plan.`, required `not`, emitted `["."]`.
  - `zh-number-correction`: spoken `那是3月18日`, final `那是3月15日。`, required `15`, emitted `["5日。"]`.
  - `en-no-carry`: spoken `no,`, final `We have no time.`, required `no`, emitted `["time."]`.
  - The generated failures are the same class: an insertion at the start or inside an already-spoken sentence is dropped.
- **`terminator-coverage`: 1 failure.** `ClauseSplitter.terminators` is missing ASCII `.` (U+002E). The same set drives `TranslationTrigger.endsWithClause`, so English sentence-final periods neither split a clause nor trigger immediate preview translation.
- **`punctuation-only-clause`: 2 failures.** `en-not` and `en-period` emit a lone `.` because the terminator set does not treat it as punctuation.
- **`no-fabrication`: clean. `idempotent-settle`: clean.**

These are findings, not fixes. The product code is unchanged.

The fingerprint is FNV-1a over the sorted distinct failure keys. Compare it on every run: unchanged means the same failure set; changed means a new failure or a fix; both insertion coverage and punctuation checks clean means the findings were fixed. The counts are distinct failure keys, not case counts.

## Real bug vs modeling error

- Exit `3`: a corpus precondition failed or a check has no cases. Update the corpus or the checker in `tools/verification/tts-text-fidelity/main.swift`, then update this record. Do not report it as a product finding.
- Exit `2`: the toolchain or compile failed. Read stderr; this is not a fidelity result.
- Exit `1`: compare the fingerprint and the per-check counts with the baseline. A changed fingerprint is a new failure or a fix; investigate in the code. The five named cases above are the recorded findings.
- Exit `0`: no failure in the corpus. Confirm the corpus still covers the changed behavior before relying on it.

## Coverage and sync

- Covered: the file and functions listed under **What is verified**.
- Sync commit: `df18973` (2026-11-27). `Clause.swift` is unchanged at that commit; the verifier and this skill were added on top. The assembler fix does not touch this file.
- When covered code changes after the sync commit, re-run the check and read the diff. Move the sync commit forward **only after** confirming the verification still describes the code. Use the pstack `maintain-formal-verification-skill` workflow when it needs to be brought back in line.
- After the findings are fixed, consider adding this command to the release checklist. It stays out of `tools/test-unit.sh` and the pre-commit hook while the expected baseline is exit `1`.

## Extending

Add a hand-built case or insertion to `tools/verification/tts-text-fidelity/main.swift`, plus a precondition that the required text is in the final. Keep the run under a few seconds. A new check goes in `runChecks`, the output's check list, and this document. Do not weaken a check to make the run pass; record a product finding instead.
