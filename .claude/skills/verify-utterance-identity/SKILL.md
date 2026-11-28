---
name: verify-utterance-identity
description: Bounded exhaustive verification of the assembler-side D8 promise that one Utterance.id names exactly one logical utterance. The text path checks settled language and final-text continuity; the range-aware production path checks settled language. Use when changing UtteranceAssembler, SpokenText, SpeechRange assembly, or any code deciding when a caption row is new. CaptionProjection is the harm consumer, not executed.
---

# Verify utterance identity (D8)

**Property.** One `Utterance.id` names exactly one logical utterance. On the text path, an ID keeps the language of its first final, and every later final under that ID is a continuation or refinement of the previous final. On the range-aware path, an ID keeps the language of its first final; the range, punctuation, and gap rules that decide new rows are covered by `UtteranceAssemblerRangeTests`. A new sentence always gets a new ID.

**Harm if broken.** A new sentence can overwrite a settled caption/transcript row: `CaptionProjection.ingest` accepts a final on a settled record (guard at `Duiyi/Domain/Projection/CaptionProjection.swift:53`) and replaces its source text (`:54-59`). The earlier sentence disappears from the caption, transcript, and export, and the translation is attributed to the wrong row. This violates D8 and the release blocker 数据不丢.

## Why this tool

Swift has no practical code-level model checker. The property is an identity invariant over a small event alphabet, so the lowest-cost faithful check is bounded exhaustive replay of the **compiled real assembler**, not a hand model that would re-encode the text heuristics where the bug lives. A TLA+ model was rejected: it would abstract away `SpokenText.isContinuation`/`isRefinement` and the final-flag interaction that produces the findings. Cost is one `swiftc` compile plus ~12 s of replay; no simulator, no network, no third-party dependency.

## What is verified

The real `UtteranceAssembler` with an injected clock, pinned to the default `.strict` language purity. The text pass replays every sequence of exactly 5 events over the 15-event alphabet (759,375 sequences) through `ingest(language:text:isFinal:)`. The range pass replays every sequence of exactly 4 events over the 12-event range alphabet (20,736 sequences) through the range-aware overload that production uses. A shorter sequence is a prefix of a longer one, and violations are checked at every step.

The harness models the engine's automatic `acknowledgeFinal` after every non-revision final that came from `ingest` (`BilingualSpeechEngine.handleTranscription`); `silenceTimedOut` does not go through that call. Corpus relations, confidence, preemption, and the greeting name-swap relation are asserted before the run; each ingest/silence event must also emit at least once, or the run exits 3.

Text pass properties: `finalized-text-identity` and `settled-language-identity`. Range pass property: `range-settled-language-identity`, an ID keeps the language of its first final when a later final arrives on a different audio range. Range boundary rules (sentence punctuation, `> 0.75 s` gaps, range overlap) are covered by `DuiyiTests/UtteranceAssemblerRangeTests.swift`, not by this verifier.

Text pass events:

| Event | Purpose |
| --- | --- |
| `ingest(en,base,final/volatile)` | A confident English sentence, finalized or growing |
| `ingest(en,extension,final/volatile)` | A continuation of `base` |
| `ingest(en,unrelated,final/volatile)` | A different English sentence |
| `ingest(en,filler,volatile)` | A non-confident short filler |
| `ingest(en,greetingA/final,greetingB/final)` | The greeting name-swap new-ID path |
| `ingest(zh,base,final/volatile)` | A confident Chinese sentence that can preempt English |
| `silenceTimedOut` | Silence-timer final for the open row |
| `advance(0.5s)` / `advance(3.5s)` | Cross the 1.0 s acknowledge hold and reconciliation windows |
| `reset` | Clear per-utterance state |

Range pass events: English phrases on ranges `0-1`, `1.1-2`, `5-6`, and a same-range correction on `0-1`; Chinese phrases on `0-1` and `1.1-2` plus a Chinese volatile; `silenceTimedOut`, both advances, and `reset`.

Covered code: `Duiyi/Services/Speech/UtteranceAssembler.swift` (`ingest`, the text path, `ingestRangeAware`, `SpeechRange`, `beginNextUtterance`, `closeCurrentRangeRow`, `silenceTimedOut`, `acknowledgeFinal`, `reset`, lock/preempt and reconciliation paths), `Duiyi/Domain/Models/Utterance.swift`, `SpokenText.swift` (`isContinuation`, `isRefinement`, `isNameSwap` as the definition of "same utterance"), and the `AppLanguage`/`ScriptCounts` functions that drive confidence and preemption. `DuiyiLog.swift` is a compile-only dependency. `CaptionProjection` is the harm consumer, not compiled or executed here.

Not covered: the projection's own behavior, the single-locale `.trustedLocale` purity, the speech engine/audio pipeline and real ASR timing (including how `SpeechRange` is built from CMTime), range boundary decisions beyond language identity, languages other than Chinese/English, and every non-identity policy (translation, TTS, queues, persistence). A pass covers the assembler's identity rules up to the bound, not the whole app.

## Run

```bash
tools/verify-utterance-identity.sh
```

- No simulator, no network, no third-party dependency. It uses `xcrun swiftc` to compile the real sources and a standalone checker, then replays the sequences.
- Reference toolchain: Xcode 27.1 / Apple Swift 6.4 on Apple silicon. Depth 5 (default): the text pass runs at depth 5, the range pass at depth 4, about 14 s total. Text depth 4: about 4 s. Depth 6: about 3 min for the text pass; the range pass stays at depth 4.
- Exit codes: `0` clean; `1` identity violations (a regression since the 2026-11-27 fix); `2` usage, missing toolchain, or compile failure; `3` modeling error (corpus precondition or event-coverage check changed).

## Read the output

The output has two sections, `Text-only path` and `Range-aware path`. Each property line gives the number of distinct traces, the number of sequences whose first violation belongs to that property, the **minimum trace length**, the trace-set fingerprint, and the shortest traces. A trace is the shortest event prefix that violates the property, written in the alphabet's words.

- `finalized-text-identity` — the detail line gives the ID, the previous final text, and the unrelated new final text.
- `settled-language-identity` / `range-settled-language-identity` — the detail line gives the ID, the language of the first final, and the language/text of the new final.

The counts are depth-scoped and count each sequence once per property (its first violation of that property).

## Current state (verified 2026-11-28, based on `9000ade`)

The run exits `0` with all three properties clean: the text pass checks `finalized-text-identity` and `settled-language-identity`, the range pass checks `range-settled-language-identity`.

The two text-path findings recorded on 2026-11-26 were fixed in `UtteranceAssembler.ingest` with one rule: once the current row has emitted a final (`latestFinal.id == utteranceID`), only a same-language continuation or refinement may reuse the ID. A different language or an unrelated text starts a new row, and a non-confident other-language result is dropped. That fix landed in `be08989`.

After merging `origin/main` at `84a880f`, the new range-aware path had the same language-change defect: a published final followed by a confident other-language final reused the ID. `0213ee3` closes the old range into `closedRanges` and starts a new utterance, so a late final for the old range still revises the old row.

Regression reference before the fixes (exit `1`):

1. Text `finalized-text-identity`: 7,874 distinct traces, 17,212 sequences with a first violation, minimum length 3, fingerprint `f82b2483e6dd4fc3`. Shortest trace: `ingest(en,base,final) → ingest(en,base,volatile) → ingest(en,unrelated,final)`.
2. Text `settled-language-identity`: 1,239 distinct traces, 2,849 sequences, minimum length 3, fingerprint `ee911927a4b4f3d3`. Shortest trace: `ingest(en,base,final) → advance(3.5s) → ingest(zh,base,final)`.
3. Range `range-settled-language-identity`: 96 distinct traces, 140 sequences, minimum length 3, fingerprint `f83918740ce0c7d3` with the range guard disabled. Shortest trace: `range(en,finalA,0-1) → advance(3.5s) → range(zh,finalA,0-1)`; the `zh,finalB,1.1-2` variant also appears.

A clean run is the state to preserve. If any property reports a violation, treat it as a regression. The shortest trace tells whether an old root cause returned or a new one appeared. Fingerprints are FNV-1a over the sorted distinct trace keys at the documented depths and are deterministic.

## Real bug vs modeling error

- Exit `3`: a corpus relation, confidence/preemption precondition, or the "every ingest/silence event emits" check changed. Update the corpus in `tools/verification/utterance-identity/main.swift` and this coverage record. Do not report it as a product finding.
- Exit `2`: the toolchain or compile failed. Read stderr; this is not an identity result.
- Exit `1`: a violation. The 2026-11-27 state is clean, so any violation is a regression. The pre-fix traces above identify the old root causes; a different trace is a new finding; investigate in the code.
- Exit `0`: no violation up to the bound. This is the current expected state. Confirm the alphabet still covers the changed behavior before relying on it.

## Coverage and sync

- Covered: the files and functions listed under **What is verified**. `ScriptCounts`/`AppLanguage` changes are caught only through the corpus preconditions and the run's confidence/preemption behavior.
- Sync commit: `9000ade`. The assembler drop/preemption diagnostics, incumbent-ID trace, and DEBUG incumbent-publish experiment were rechecked clean (preemption default path unchanged); the row-82 volatile-range fix (`sameVolatilePhrase` + `shouldReplaceSameAudio` text guard) and earlier text/range fixes remain covered. Move it forward only after the next covered change is rechecked.
- When covered code changes after the sync commit, re-run the check and read the diff. Move the sync commit forward **only after** confirming the verification still describes the code — update the alphabet, corpus, or properties if the behavior space changed. Use the pstack `maintain-formal-verification-skill` workflow when the verification needs to be brought back in line.
- The check is clean and costs about 18 s. Consider adding it to the release checklist. It stays out of `tools/test-unit.sh` and the pre-commit hook unless the team wants the gate.

## Extending

Add an event to `Event` in `tools/verification/utterance-identity/main.swift`, plus any corpus string and precondition; keep the depth-5 run under ~30 s. A new property goes in `violations(for:)`, `Property.all`, the output, and this document. Do not weaken a property to make the run pass; record a product finding instead.
