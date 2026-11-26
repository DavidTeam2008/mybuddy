# MyBuddy

End-to-end, on-device iOS real-time translation app. See `README.md` for build/test entry points, `GLOSSARY.md` for product language, and `docs/decisions.md` for the frozen v1 scope.

## Project rules

- Architecture: `docs/02-architecture.md`; tech choices: `docs/03-tech-choices.md`; current issues and schedule: `docs/04-roadmap.md`.
- Frozen v1 decisions: `docs/decisions.md` (D1–D8 + v1 冻结口径).
- Domain vocabulary: `GLOSSARY.md`; use its terms in issues, tests, and proposals.
- No third-party dependencies; iPhone portrait only; on-device, no backend, no API key.

## Agent skills

### Issue tracker

Issues and specs live as GitHub issues in `DavidTeam2008/mybuddy`, created and read with the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Five canonical triage roles, each label string equal to its role name: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` at the repo root and the D-series decision record in `docs/decisions.md`. See `docs/agents/domain.md`.

### Device testing

Physical iPhone builds, signing, UI automation, and acoustic smoke: see `docs/agents/device-testing.md`.

### Formal verification

`verify-utterance-identity` (`.claude/skills/verify-utterance-identity/SKILL.md`) checks the D8 utterance-identity promise with bounded exhaustive replay of the real assembler: `tools/verify-utterance-identity.sh`.

`verify-tts-text-fidelity` (`.claude/skills/verify-tts-text-fidelity/SKILL.md`) checks that settled TTS clauses cover new meaning-bearing content, fabricate nothing, and settle idempotently: `tools/verify-tts-text-fidelity.sh`.
