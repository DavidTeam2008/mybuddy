# MyBuddy（对译）

End-to-end, on-device iOS real-time translation app. Microphone → speech recognition → Apple Translation.framework → live captions / optional TTS. No backend, no API key, audio never leaves the device.

This repository is the product-only extraction of the working app from the original harness-engineering showcase repository. Source: realtimeTranslatorOptimize, tag v1.1.0. The old repository keeps the full history, harness evidence and tooling; this one starts clean so the app can be reorganized and improved without the meta layer.

## Status

- Initial extraction: app sources, tests, Xcode project, product docs, diagrams and screenshots.
- Harness / evidence / agent tooling from the source repo intentionally not carried over.
- docs are aligned to the frozen v1 decisions (2026-11-23); see `docs/decisions.md` and `GLOSSARY.md`.
- Order/ is kept because the Release build still references ORDER_FILE; do not hand-edit it.

## Product

Three modes:

- Face-to-face: screen split, one side rotated 180°, bilingual captions.
- Simultaneous interpretation: one column, optional headphone TTS.
- Meeting notes: monolingual transcript, summary and export.
- Shared: six languages (v1 commits Chinese↔English; Japanese/Korean/Thai/Vietnamese are experimental), task history, local persistence, onboarding, settings.

## Requirements

- macOS with Xcode 26.4+ (validated with Xcode 27.1)
- iOS 26.4+ simulator or device, iPhone 13 or later, portrait only
- No third-party dependencies

## Build and test

Open Duiyi.xcodeproj in Xcode, or use xcodebuild:

    xcodebuild -project Duiyi.xcodeproj -scheme Duiyi -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build

    xcodebuild -project Duiyi.xcodeproj -scheme Duiyi -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test

For device builds, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` (gitignored) and set your Team ID and device UDID; Xcode picks up the team automatically. Set a unique Bundle ID if needed. Physical-device automation uses `tools/device.sh` (see `docs/agents/device-testing.md`). The old repository's Makefile and harness gates are not part of this repository.

For agent or CI runs, use the wrappers. They select and boot a simulator, parse the xcresult summary, print logical and expanded counts, and treat skips as failures except the known simulator speech skip:

    tools/test-unit.sh
    tools/test-ui.sh
    tools/test-tools.sh

`tools/test-unit.sh` also runs the deterministic tooling tests first; `tools/test-tools.sh` runs only those (Python stdlib, including the fixture scorer's short-cue and baseline checks).

Physical iPhone verification: run `tools/device.sh check` and follow `docs/agents/device-testing.md` (signing, UI automation, acoustic smoke). Debug builds also accept a fixture audio path through the real speech engine, so the ASR → translation → persistence path can run without a quiet room: `tools/fixture-run.sh` (see §5.1 in that page). The default fixture run now fails on a relative regression against `tools/fixtures/ted-baseline.json`, including short-cue retention; this is still a mechanical gate, not semantic translation signoff.

Fast static checks, plus the optional committed pre-commit hook:

    tools/check-static.sh
    tools/install-hooks.sh

## Structure

    Duiyi/
      App/             entry, dependency assembly, navigation
      Features/        Home, Conversation, Interpretation, Meeting, History, Onboarding, Settings, Shared
      Domain/          pure models, routing, task semantics
      Services/        audio, speech, translation, TTS, persistence, summary, export, permissions
      DesignSystem/    tokens, cards, list rows, safe areas
    DuiyiTests/        unit tests (Swift Testing)
    DuiyiUITests/      launch performance, navigation, simultaneous listening UI
    docs/              product, architecture, tech choices, roadmap, decisions, specs, agents/
    GLOSSARY.md        product vocabulary
    AGENTS.md          agent skills configuration
    Order/             Release binary-order artifact (do not hand-edit)

## License

MIT. See LICENSE. The app was extracted from the original repository at tag v1.1.0.
