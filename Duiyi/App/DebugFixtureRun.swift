#if DEBUG
import AVFAudio
import Foundation

/// Debug-only driver for a fixture replay. It navigates to interpretation,
/// creates a task, starts listening through the real ViewModel/lifecycle, waits
/// for the fixture to reach EOF, settles, ends the task, and writes a marker
/// plus the diagnostics export to Documents.
///
/// This is not a product path: it only runs when `-duiyi.fixtureAudio` is
/// present, and the whole file compiles out of Release.
@MainActor
enum DebugFixtureRun {
    static func startIfRequested(
        viewModel: InterpretationViewModel,
        coordinator: AppCoordinator,
        environment: AppEnvironment
    ) {
        guard DebugAudioFixture.isRequested, DebugAudioFixture.autoRun else { return }
        Task { @MainActor in
            await run(viewModel: viewModel, coordinator: coordinator, environment: environment)
        }
    }

    private static func run(
        viewModel: InterpretationViewModel,
        coordinator: AppCoordinator,
        environment: AppEnvironment
    ) async {
        let startedAt = Date()
        let fixture = DebugAudioFixture.fixtureURL
        var errors: [String] = []
        var permissionStatus = "unknown"
        var speechCapable: Bool?
        var pairStatus: String?
        var listeningStarted = false
        var endOutcome = "not-run"
        var taskID: String?
        var diagnosticsFile: String?
        var entries: [TranscriptEntry] = []
        var capturerStats: [String: String] = [:]

        DebugFixtureLog.reset()
        try? FileManager.default.removeItem(at: DebugFixtureMarkerFile.url)
        DebugFixtureLog.write("fixture run requested")
        defer {
            let marker = DebugFixtureMarker(
                fixture: fixture?.lastPathComponent ?? "missing",
                pacing: DebugAudioFixture.pacing.rawValue,
                startedAt: startedAt.formatted(.iso8601),
                finishedAt: Date().formatted(.iso8601),
                durationSeconds: Date().timeIntervalSince(startedAt),
                permissionStatus: permissionStatus,
                listeningStarted: listeningStarted,
                sessionState: String(describing: viewModel.sessionState),
                endOutcome: endOutcome,
                taskID: taskID,
                transcriptCount: entries.count,
                sourceNonEmptyCount: entries.filter { $0.hasUsableText }.count,
                translatedCount: entries.filter {
                    !$0.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }.count,
                diagnosticsFile: diagnosticsFile,
                capturer: capturerStats,
                speechDeviceCapable: speechCapable,
                translationPair: pairStatus,
                errors: errors
            )
            DebugFixtureMarkerFile.write(marker)
            DebugFixtureLog.write("marker written errors=\(errors.count)")
        }

        guard let fixture else {
            errors.append("missing -duiyi.fixtureAudio")
            return
        }
        let fixtureExists = FileManager.default.fileExists(atPath: fixture.path)
        DebugFixtureLog.write("fixture path=\(fixture.path) exists=\(fixtureExists)")
        guard fixtureExists else {
            errors.append("fixture file not found: \(fixture.path)")
            return
        }

        environment.preferences.hasCompletedOnboarding = true
        environment.preferences.sourceLanguage = .english
        environment.preferences.targetLanguage = .zhHans
        environment.preferences.voiceOutEnabled = false
        viewModel.sourceLanguage = .english
        viewModel.targetLanguage = .zhHans
        viewModel.voiceOutEnabled = false

        coordinator.popToHome()
        coordinator.open(.interpretation)
        try? await Task.sleep(for: .seconds(2))

        var status = await environment.permissions.currentStatus()
        if !status.isGranted {
            status = await environment.permissions.requestAccess()
        }
        permissionStatus = String(describing: status)
        DebugFixtureLog.write("permissions=\(permissionStatus)")

        let languages: [AppLanguage] = [.english]
        let capable = await environment.speechModels.isDeviceCapable(for: languages)
        speechCapable = capable
        DebugFixtureLog.write("speech device capable=\(capable)")
        guard capable else {
            errors.append("speech device incapable")
            return
        }
        do {
            try await environment.speechModels.prepare(languages: languages) { _ in }
            DebugFixtureLog.write("speech assets prepared")
        } catch {
            errors.append("speech prepare failed: \(error)")
            return
        }

        let pair = await environment.translationAvailability.pairStatus(
            from: .english,
            to: .zhHans
        )
        pairStatus = String(describing: pair)
        DebugFixtureLog.write("translation pair=\(pairStatus ?? "nil")")
        if pair == .unsupported {
            errors.append("translation pair unsupported")
            return
        }

        // Let the view's bootstrap() finish before creating a task.
        for _ in 0..<25 where viewModel.sessionState == .preparing {
            try? await Task.sleep(for: .milliseconds(200))
        }

        await viewModel.beginTask()
        DebugFixtureLog.write(
            "beginTask active=\(viewModel.hasActiveTask) state=\(String(describing: viewModel.sessionState))"
        )
        guard viewModel.hasActiveTask else {
            errors.append("no active task after beginTask")
            return
        }

        await viewModel.start()
        try? await Task.sleep(for: .seconds(1))
        listeningStarted = viewModel.sessionState.isListening
        DebugFixtureLog.write(
            "start state=\(String(describing: viewModel.sessionState)) listening=\(listeningStarted)"
        )
        guard listeningStarted else {
            errors.append("listening did not start")
            let session = await viewModel.endTask()
            endOutcome = session == nil ? "not-listening-discarded" : "not-listening-ended"
            taskID = session?.id.uuidString
            entries = session?.entries ?? []
            return
        }

        let duration = fixtureDuration(fixture)
        let timeout = duration + 120
        DebugFixtureLog.write("waiting for EOF timeout=\(timeout)s duration=\(duration)s")
        let reachedEOF = await waitForEOF(capturer: environment.fixtureCapturer, timeout: timeout)
        DebugFixtureLog.write("EOF reached=\(reachedEOF)")
        if !reachedEOF {
            errors.append("fixture EOF timeout")
        }

        let settle = DebugAudioFixture.settleSeconds
        DebugFixtureLog.write("settling \(settle)s")
        try? await Task.sleep(for: .seconds(settle))

        if let capturer = environment.fixtureCapturer {
            let stats = await capturer.stats()
            capturerStats = [
                "started": String(stats.started),
                "finished": String(stats.finished),
                "sentFrames": String(stats.sentFrames),
                "sampleRate": String(stats.sampleRate),
                "channels": String(stats.channels),
                "format": stats.formatDescription,
            ]
            DebugFixtureLog.write("capturer stats=\(capturerStats)")
        }

        let session = await viewModel.endTask()
        if let session {
            endOutcome = "ended"
            taskID = session.id.uuidString
            entries = session.entries
        } else {
            endOutcome = "discardedEmptyOrNotSaved"
            entries = viewModel.transcript
        }
        DebugFixtureLog.write(
            "endTask outcome=\(endOutcome) task=\(taskID ?? "nil") entries=\(entries.count)"
        )

        // Give late final translations a bounded window to backfill before the
        // diagnostics snapshot is exported.
        try? await Task.sleep(for: .seconds(2))
        if let url = environment.diagnostics.makeExportFile() {
            diagnosticsFile = url.lastPathComponent
            DebugFixtureLog.write("diagnostics export=\(url.lastPathComponent)")
        } else {
            errors.append("diagnostics export returned nil")
        }

        if DebugAudioFixture.deleteAfterRun {
            do {
                try FileManager.default.removeItem(at: fixture)
                DebugFixtureLog.write("fixture deleted")
            } catch {
                errors.append("fixture delete failed: \(error)")
            }
        }
    }

    private static func waitForEOF(
        capturer: FixtureAudioCapturer?,
        timeout: Double
    ) async -> Bool {
        guard let capturer else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await capturer.stats().finished { return true }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    private static func fixtureDuration(_ url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url),
              file.processingFormat.sampleRate > 0 else {
            return 900
        }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
#endif
