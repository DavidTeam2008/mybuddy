# MyBuddy（对译 Duiyi）

End-to-end, on-device iOS real-time translation app. Microphone → speech recognition → Apple Translation.framework → live captions / optional TTS. No backend, no API key, audio never leaves the device.

This repository is the product-only extraction of the working app from the original harness-engineering showcase repository. Source: realtimeTranslatorOptimize, tag v1.1.0. The old repository keeps the full history, harness evidence and tooling; this one starts clean so the app can be reorganized and improved without the meta layer.

## Status

- Initial extraction: app sources, tests, Xcode project, product docs, diagrams and screenshots.
- Harness / evidence / agent tooling from the source repo intentionally not carried over.
- docs are the v1.1.0 product docs; they will be reorganized and re-linked before feature work.
- Order/ is kept temporarily because the Release build still references ORDER_FILE; it will be removed in the cleanup plan.

## Product

Three modes:

- Face-to-face: screen split, one side rotated 180°, bilingual captions.
- Simultaneous interpretation: one column, optional headphone TTS.
- Meeting notes: monolingual transcript, summary and export.
- Shared: six languages, task history, local persistence, onboarding, settings.

## Requirements

- macOS with Xcode 26.4+ (validated with Xcode 27.1)
- iOS 26.4+ simulator or device, iPhone portrait only
- No third-party dependencies

## Build and test

Open Duiyi.xcodeproj in Xcode, or use xcodebuild:

    xcodebuild -project Duiyi.xcodeproj -scheme Duiyi -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build

    xcodebuild -project Duiyi.xcodeproj -scheme Duiyi -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test

For device builds, set your own Team and a unique Bundle ID. The old repository's Makefile and harness gates are not part of this repository.

## Structure

    Duiyi/
      App/             entry, dependency assembly, navigation
      Features/        Home, Conversation, Interpretation, Meeting, History, Onboarding, Settings, Shared
      Domain/          pure models, routing, task semantics
      Services/        audio, speech, translation, TTS, persistence, summary, export, permissions
      DesignSystem/    tokens, cards, list rows, safe areas
    DuiyiTests/        unit tests (Swift Testing)
    DuiyiUITests/      launch performance, navigation, simultaneous listening UI
    docs/              product, architecture, tech choices, roadmap, decisions, specs
    Order/             Release binary-order artifact, temporary

## License

MIT. See LICENSE. The app was extracted from the original repository at tag v1.1.0.
