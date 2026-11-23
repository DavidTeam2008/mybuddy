# MyBuddy

End-to-end, on-device iOS real-time translation app. See `README.md` for build/test entry points, `GLOSSARY.md` for product language, and `docs/decisions.md` for the frozen v1 scope.

## Project rules

- Architecture: `docs/02-architecture.md`; tech choices: `docs/03-tech-choices.md`; current issues and schedule: `docs/04-roadmap.md`.
- Frozen v1 decisions: `docs/decisions.md` (D1–D7 + v1 冻结口径).
- Domain vocabulary: `GLOSSARY.md`; use its terms in issues, tests, and proposals.
- No third-party dependencies; iPhone portrait only; on-device, no backend, no API key.

## Agent skills

### Issue tracker

Issues and specs live as GitHub issues in `DavidTeam2008/mybuddy`, created and read with the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Five canonical triage roles, each label string equal to its role name: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` at the repo root and the D-series decision record in `docs/decisions.md`. See `docs/agents/domain.md`.
