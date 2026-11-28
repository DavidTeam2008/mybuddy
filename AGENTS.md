# MyBuddy

End-to-end, on-device iOS real-time translation app. See `README.md` for build/test entry points, `GLOSSARY.md` for product language, and `docs/decisions.md` for the frozen v1 scope.

## Project rules

- Architecture: `docs/02-architecture.md`; tech choices: `docs/03-tech-choices.md`; current issues and schedule: `docs/04-roadmap.md`.
- Frozen v1 decisions: `docs/decisions.md` (D1–D11 + v1 冻结口径).
- Domain vocabulary: `GLOSSARY.md`; use its terms in issues, tests, and proposals.
- No third-party dependencies; iPhone portrait only; on-device, no backend, no API key.

## 问题排查与根因记录

- 每次完成问题排查/根因分析（包括“不是 bug”“无法复现”的结论）后，必须把结论落到仓库：优先 `docs/research/<topic>-YYYY-MM-DD.md`，流程性结论写对应 `docs/agents/`；ticket 里链接该文件，不只留在对话或 commit message。
- 记录至少包含：症状与复现命令、证据路径/运行 ID/commit/设备、根因分层（已证实/假设/未验证）、已排除项、修复及开关/回滚、残余风险与“不要做”清单。
- 单次 ASR/翻译随机波动不能写成因果；A/B 必须同夹具、同构建、交错运行，并写明样本数、指标与限制。没有证据的结论标 `hypothesis`，不能写成 `confirmed`；完成判据/roadmap 只在证据满足时更新。
- 排查过程中的临时 raw 证据、日志、设备产物留在本机 `.device-state/` 或等价目录，不提交正文；仓库只提交脱敏后的结论、命令和证据路径。

## Agent skills

### Issue tracker

Issues and specs live as GitHub issues in `DavidTeam2008/mybuddy`, created and read with the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Five canonical triage roles, each label string equal to its role name: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` at the repo root and the D-series decision record in `docs/decisions.md`. See `docs/agents/domain.md`.

### Device testing

Physical iPhone builds, signing, UI automation, acoustic smoke, and the DEBUG fixture-audio replay: see `docs/agents/device-testing.md`.

### Formal verification

`verify-utterance-identity` (`.claude/skills/verify-utterance-identity/SKILL.md`) checks the D8 utterance-identity promise with bounded exhaustive replay of the real assembler: `tools/verify-utterance-identity.sh`.

`verify-tts-text-fidelity` (`.claude/skills/verify-tts-text-fidelity/SKILL.md`) checks that settled TTS clauses cover new meaning-bearing content, fabricate nothing, and settle idempotently: `tools/verify-tts-text-fidelity.sh`.
