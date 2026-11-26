---
name: verify-utterance-identity
description: Bounded exhaustive verification of the assembler-side D8 promise that one Utterance.id names exactly one logical utterance — a finalized row keeps its language, and a later final must continue or refine the earlier text. Use when changing UtteranceAssembler, SpokenText continuation/refinement, or any code deciding when a caption row is new. CaptionProjection is the harm consumer, not executed.
---

# Verify utterance identity (D8)

**Property.** One `Utterance.id` names exactly one logical utterance: an ID keeps the language of its first final, and every later final under that ID is a continuation or refinement of the previous final. A new sentence always gets a new ID.

**Harm if broken.** A new sentence can overwrite a settled caption/transcript row: `CaptionProjection.ingest` accepts a final on a settled record (guard at `Duiyi/Domain/Projection/CaptionProjection.swift:53`) and replaces its source text (`:54-59`). The earlier sentence disappears from the caption, transcript, and export, and the translation is attributed to the wrong row. This violates D8 and the release blocker 数据不丢.

## Why this tool

Swift has no practical code-level model checker. The property is an identity invariant over a small event alphabet, so the lowest-cost faithful check is bounded exhaustive replay of the **compiled real assembler**, not a hand model that would re-encode the text heuristics where the bug lives. A TLA+ model was rejected: it would abstract away `SpokenText.isContinuation`/`isRefinement` and the final-flag interaction that produces the findings. Cost is one `swiftc` compile plus ~12 s of replay; no simulator, no network, no third-party dependency.

## What is verified

The real `UtteranceAssembler` with an injected clock, pinned to the default `.strict` language purity. Every event sequence of exactly 5 events over the 15-event alphabet is replayed (759,375 sequences); a shorter sequence is a prefix of a longer one, and violations are checked at every step.

The harness models the engine's automatic `acknowledgeFinal` after every non-revision final that came from `ingest` (`BilingualSpeechEngine.handleTranscription`); `silenceTimedOut` does not go through that call. Corpus relations, confidence, preemption, and the greeting name-swap relation are asserted before the run; each ingest/silence event must also emit at least once, or the run exits 3.

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

Covered code: `Duiyi/Services/Speech/UtteranceAssembler.swift` (`ingest`, `silenceTimedOut`, `acknowledgeFinal`, `reset`, `beginNextUtterance`, lock/preempt and reconciliation paths), `Duiyi/Domain/Models/Utterance.swift`, `SpokenText.swift` (`isContinuation`, `isRefinement`, `isNameSwap` as the definition of "same utterance"), and the `AppLanguage`/`ScriptCounts` functions that drive confidence and preemption. `DuiyiLog.swift` is a compile-only dependency. `CaptionProjection` is the harm consumer, not compiled or executed here.

Not covered: the projection's own behavior, the single-locale `.trustedLocale` purity, the speech engine/audio pipeline and real ASR timing, languages other than Chinese/English, and every non-identity policy (translation, TTS, queues, persistence). A pass covers the assembler's identity rules up to the bound, not the whole app.

## Run

```bash
tools/verify-utterance-identity.sh
```

- No simulator, no network, no third-party dependency. It uses `xcrun swiftc` to compile the real sources and a standalone checker, then replays the sequences.
- Reference toolchain: Xcode 27.1 / Apple Swift 6.4 on Apple silicon. Depth 5 (default): ~12 s replay, ~16 s total. Depth 4: ~1 s replay, ~4 s total. Depth 6: ~3 min; run it only for a deliberate deep pass.
- Exit codes: `0` clean; `1` identity violations (a regression since the 2026-11-27 fix); `2` usage, missing toolchain, or compile failure; `3` modeling error (corpus precondition or event-coverage check changed).

## Read the output

Each property line gives the number of distinct traces, the number of sequences whose first violation belongs to that property, the **minimum trace length**, the trace-set fingerprint, and the shortest traces. A trace is the shortest event prefix that violates the property, written in the alphabet's words.

- `finalized-text-identity` — the detail line gives the ID, the previous final text, and the unrelated new final text.
- `settled-language-identity` — the detail line gives the ID, the language of the first final, and the language/text of the new final.

The counts are depth-scoped and count each sequence once per property (its first violation of that property).

## Current state (verified 2026-11-27, based on `be08989`)

The run exits `0` and both properties are clean up to the bound. The two findings recorded on 2026-11-26 were fixed in `UtteranceAssembler.ingest` with one rule: once the current row has emitted a final (`latestFinal.id == utteranceID`), only a same-language continuation or refinement may reuse the ID. A different language or an unrelated text starts a new row, and a non-confident other-language result is dropped. The fix landed in `be08989`; this verifier landed after it.

Regression reference, recorded before the fix at depth 5 (exit `1`):

1. `finalized-text-identity`: 7,874 distinct traces, 17,212 sequences with a first violation, minimum length 3, fingerprint `f82b2483e6dd4fc3`. Shortest trace: `ingest(en,base,final) → ingest(en,base,volatile) → ingest(en,unrelated,final)`.
2. `settled-language-identity`: 1,239 distinct traces, 2,849 sequences with a first violation, minimum length 3, fingerprint `ee911927a4b4f3d3`. Shortest trace: `ingest(en,base,final) → advance(3.5s) → ingest(zh,base,final)`.

A clean run is the state to preserve. If either property reports a violation, treat it as a regression. The shortest trace tells whether the old root cause returned or a new one appeared. Fingerprints are FNV-1a over the sorted distinct trace keys at depth 5 and are deterministic.

## Real bug vs modeling error

- Exit `3`: a corpus relation, confidence/preemption precondition, or the "every ingest/silence event emits" check changed. Update the corpus in `tools/verification/utterance-identity/main.swift` and this coverage record. Do not report it as a product finding.
- Exit `2`: the toolchain or compile failed. Read stderr; this is not an identity result.
- Exit `1`: a violation. The 2026-11-27 state is clean, so any violation is a regression. The two pre-fix traces above identify the old root causes; a different trace is a new finding; investigate in the code.
- Exit `0`: no violation up to the bound. This is the current expected state. Confirm the alphabet still covers the changed behavior before relying on it.

## Coverage and sync

- Covered: the files and functions listed under **What is verified**. `ScriptCounts`/`AppLanguage` changes are caught only through the corpus preconditions and the run's confidence/preemption behavior.
- Sync commit: `be08989`. The fix and the verifier were confirmed clean there; move it forward only after the next covered change is rechecked.
- When covered code changes after the sync commit, re-run the check and read the diff. Move the sync commit forward **only after** confirming the verification still describes the code — update the alphabet, corpus, or properties if the behavior space changed. Use the pstack `maintain-formal-verification-skill` workflow when the verification needs to be brought back in line.
- The check is clean and costs about 18 s. Consider adding it to the release checklist. It stays out of `tools/test-unit.sh` and the pre-commit hook unless the team wants the gate.

## Extending

Add an event to `Event` in `tools/verification/utterance-identity/main.swift`, plus any corpus string and precondition; keep the depth-5 run under ~30 s. A new property goes in `violations(for:)`, `Property.all`, the output, and this document. Do not weaken a property to make the run pass; record a product finding instead.
