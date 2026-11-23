# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Before exploring, read these

- **`GLOSSARY.md`** at the repo root: the product vocabulary (面对面 / 同声传译 / 会议记录 / 任务 / 文字稿 / 串音 / 倒字侧 / 实验语言 …).
- **`docs/decisions.md`**: the D-series decision record plus the frozen "v1 冻结口径" section. Read the D rows and the scope/quality sections relevant to the area you're about to work in.
- There is no `docs/adr/` in this repo; do not create one. `docs/decisions.md` is the single decision table, and other docs reference D numbers.

If any of these files don't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. The `/domain-modeling` skill creates them lazily when terms or decisions actually get resolved.

## File structure

Single-context repo:

```
/
├── GLOSSARY.md
├── docs/
│   ├── decisions.md          ← D-series decisions + v1 frozen scope
│   ├── 01-product-design.md
│   ├── 02-architecture.md
│   ├── 03-tech-choices.md
│   └── 04-roadmap.md
└── Duiyi/
```

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `GLOSSARY.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal: either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Flag decision conflicts

If your output contradicts D1–D7 or the "v1 冻结口径", surface it explicitly rather than silently overriding:

> _Contradicts D6 (no digest fallback), but worth reopening because…_
