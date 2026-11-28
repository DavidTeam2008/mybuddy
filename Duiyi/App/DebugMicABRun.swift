#if DEBUG
import Foundation

/// DEBUG-only driver for the real-microphone P1-1 preemption A/B.
///
/// It uses the real microphone path (no `-duiyi.fixtureAudio`), opens
/// Conversation or Meeting, creates a task, starts listening, waits for a
/// fixed window, ends the task, and exports diagnostics plus a no-text marker.
/// The Mac side plays the scripted A/B audio through the phone's microphone.
///
/// Launch arguments:
///   -duiyi.micABModule conversation|meeting
///   -duiyi.micABUserLanguage english|japanese|zhHans
///   -duiyi.micABPeerLanguage english|japanese|zhHans
///   -duiyi.micABDuration 60
///   -duiyi.micABSettleSeconds 4
///   -duiyi.assemblerPreemptionPublish no|yes
///
/// This is not a product path and compiles out of Release. It never writes
/// caption text or audio; transcript rows stay in SwiftData.
@MainActor
enum DebugMicABRun {
    static func startIfRequested(
        conversationViewModel: ConversationViewModel,
        meetingViewModel: MeetingViewModel,
        coordinator: AppCoordinator,
        environment: AppEnvironment
    ) {
        guard let options = DebugMicABOptions.current,
              !DebugAudioFixture.isRequested else { return }
        Task { @MainActor in
            await run(
                options: options,
                conversationViewModel: conversationViewModel,
                meetingViewModel: meetingViewModel,
                coordinator: coordinator,
                environment: environment
            )
        }
    }

    private static func run(
        options: DebugMicABOptions,
        conversationViewModel: ConversationViewModel,
        meetingViewModel: MeetingViewModel,
        coordinator: AppCoordinator,
        environment: AppEnvironment
    ) async {
        let startedAt = Date()
        var errors: [String] = []
        var permissionStatus = "unknown"
        var speechCapable: Bool?
        var pairStatus: String?
        var listeningStarted = false
        var endOutcome = "not-run"
        var taskID: String?
        var diagnosticsFile: String?
        var entries: [TranscriptEntry] = []

        DebugMicABLog.reset()
        DebugMicABMarkerFile.remove()
        DebugMicABLog.write(
            "mic A/B requested module=\(options.module.rawValue) " +
                "languages=\(options.userLanguage.rawValue),\(options.peerLanguage.rawValue) " +
                "publish=\(options.preemptionPublish)"
        )

        defer {
            let marker = DebugMicABMarker(
                module: options.module.rawValue,
                userLanguage: options.userLanguage.rawValue,
                peerLanguage: options.peerLanguage.rawValue,
                preemptionPublish: options.preemptionPublish,
                startedAt: startedAt.formatted(.iso8601),
                finishedAt: Date().formatted(.iso8601),
                durationSeconds: Date().timeIntervalSince(startedAt),
                permissionStatus: permissionStatus,
                listeningStarted: listeningStarted,
                sessionState: options.module == .conversation
                    ? String(describing: conversationViewModel.sessionState)
                    : String(describing: meetingViewModel.sessionState),
                endOutcome: endOutcome,
                taskID: taskID,
                transcriptCount: entries.count,
                sourceNonEmptyCount: entries.filter { $0.hasUsableText }.count,
                translatedCount: entries.filter {
                    !$0.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }.count,
                diagnosticsFile: diagnosticsFile,
                speechDeviceCapable: speechCapable,
                translationPair: pairStatus,
                errors: errors
            )
            DebugMicABMarkerFile.writeDone(marker)
            DebugMicABLog.write("done errors=\(errors.count) outcome=\(endOutcome)")
        }

        applyPreferences(options, environment: environment)

        let route: AppRoute
        switch options.module {
        case .conversation:
            route = .conversation
            conversationViewModel.userLanguage = options.userLanguage
            conversationViewModel.peerLanguage = options.peerLanguage
            conversationViewModel.listeningMode = .automatic
            conversationViewModel.autoStartListening = true
        case .meeting:
            route = .meeting
            meetingViewModel.sourceLanguage = options.userLanguage
            meetingViewModel.recognizesMultipleLanguages = true
        }

        coordinator.popToHome()
        coordinator.open(route)
        try? await Task.sleep(for: .seconds(2))

        var status = await environment.permissions.currentStatus()
        if !status.isGranted {
            status = await environment.permissions.requestAccess()
        }
        permissionStatus = String(describing: status)
        DebugMicABLog.write("permissions=\(permissionStatus)")

        let languages: [AppLanguage]
        switch options.module {
        case .conversation:
            languages = [options.userLanguage, options.peerLanguage]
        case .meeting:
            languages = meetingViewModel.recognitionLanguages
        }
        let capable = await environment.speechModels.isDeviceCapable(for: languages)
        speechCapable = capable
        DebugMicABLog.write("speech device capable=\(capable) languages=\(languages.map(\.rawValue))")
        guard capable else {
            errors.append("speech device incapable")
            return
        }
        do {
            try await environment.speechModels.prepare(languages: languages) { _ in }
            DebugMicABLog.write("speech assets prepared")
        } catch {
            errors.append("speech prepare failed: \(error)")
            return
        }

        if options.module == .conversation {
            let pair = await environment.translationAvailability.pairStatus(
                from: options.userLanguage,
                to: options.peerLanguage
            )
            pairStatus = String(describing: pair)
            DebugMicABLog.write("translation pair=\(pairStatus ?? "nil")")
            if pair == .unsupported {
                errors.append("translation pair unsupported")
                return
            }
        }

        switch options.module {
        case .conversation:
            await waitUntilReady(conversationViewModel)
            await conversationViewModel.beginTask()
            DebugMicABLog.write(
                "beginTask active=\(conversationViewModel.hasActiveTask) " +
                    "state=\(String(describing: conversationViewModel.sessionState))"
            )
            guard conversationViewModel.hasActiveTask else {
                errors.append("no active task after beginTask")
                return
            }
            if !conversationViewModel.sessionState.isListening {
                await conversationViewModel.start()
                try? await Task.sleep(for: .seconds(1))
            }
            listeningStarted = conversationViewModel.sessionState.isListening
        case .meeting:
            await waitUntilReady(meetingViewModel)
            await meetingViewModel.beginTask()
            DebugMicABLog.write(
                "beginTask active=\(meetingViewModel.hasActiveTask) " +
                    "state=\(String(describing: meetingViewModel.sessionState))"
            )
            guard meetingViewModel.hasActiveTask else {
                errors.append("no active task after beginTask")
                return
            }
            await meetingViewModel.start()
            try? await Task.sleep(for: .seconds(1))
            listeningStarted = meetingViewModel.sessionState.isListening
        }

        let listeningState = options.module == .conversation
            ? String(describing: conversationViewModel.sessionState)
            : String(describing: meetingViewModel.sessionState)
        DebugMicABLog.write("listening=\(listeningStarted) state=\(listeningState)")
        guard listeningStarted else {
            errors.append("listening did not start")
            await endTask(
                options: options,
                conversationViewModel: conversationViewModel,
                meetingViewModel: meetingViewModel,
                endOutcome: &endOutcome,
                taskID: &taskID,
                entries: &entries
            )
            return
        }

        DebugMicABMarkerFile.writeReady(
            DebugMicABReady(
                module: options.module.rawValue,
                userLanguage: options.userLanguage.rawValue,
                peerLanguage: options.peerLanguage.rawValue,
                preemptionPublish: options.preemptionPublish,
                at: Date().formatted(.iso8601)
            )
        )
        DebugMicABLog.write("ready for playback duration=\(options.durationSeconds)s")
        try? await Task.sleep(for: .seconds(options.durationSeconds))

        await endTask(
            options: options,
            conversationViewModel: conversationViewModel,
            meetingViewModel: meetingViewModel,
            endOutcome: &endOutcome,
            taskID: &taskID,
            entries: &entries
        )

        try? await Task.sleep(for: .seconds(options.settleSeconds))
        if let url = environment.diagnostics.makeExportFile() {
            diagnosticsFile = url.lastPathComponent
            DebugMicABLog.write("diagnostics export=\(url.lastPathComponent)")
        } else {
            errors.append("diagnostics export returned nil")
        }
    }

    private static func applyPreferences(
        _ options: DebugMicABOptions,
        environment: AppEnvironment
    ) {
        let preferences = environment.preferences
        preferences.hasCompletedOnboarding = true
        preferences.userLanguage = options.userLanguage
        preferences.peerLanguage = options.peerLanguage
        preferences.appMode = options.module == .conversation ? .faceToFace : .meeting
        preferences.conversationListeningMode = .automatic
        preferences.autoStartListening = true
        preferences.voiceOutEnabled = false
        preferences.showsSourceLine = true
        preferences.meetingRecognizesMultipleLanguages = true
        preferences.meetingLanguage = options.userLanguage
        #if DEBUG
        preferences.debugForceSingleLocale = false
        #endif
        DebugMicABLog.write(
            "preferences user=\(preferences.userLanguage.rawValue) " +
                "peer=\(preferences.peerLanguage.rawValue) " +
                "mode=\(preferences.appMode.rawValue) " +
                "meetingMulti=\(preferences.meetingRecognizesMultipleLanguages)"
        )
    }

    private static func waitUntilReady(_ viewModel: ConversationViewModel) async {
        for _ in 0..<25 where viewModel.sessionState == .preparing {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private static func waitUntilReady(_ viewModel: MeetingViewModel) async {
        for _ in 0..<25 where viewModel.sessionState == .preparing {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private static func endTask(
        options: DebugMicABOptions,
        conversationViewModel: ConversationViewModel,
        meetingViewModel: MeetingViewModel,
        endOutcome: inout String,
        taskID: inout String?,
        entries: inout [TranscriptEntry]
    ) async {
        let session: TaskSession?
        switch options.module {
        case .conversation:
            session = await conversationViewModel.endTask()
            entries = session?.entries ?? conversationViewModel.transcript
        case .meeting:
            session = await meetingViewModel.endTask()
            entries = session?.entries ?? meetingViewModel.transcript
        }
        if let session {
            endOutcome = "ended"
            taskID = session.id.uuidString
        } else {
            endOutcome = "discardedEmptyOrNotSaved"
        }
        DebugMicABLog.write(
            "endTask outcome=\(endOutcome) task=\(taskID ?? "nil") entries=\(entries.count)"
        )
    }
}

struct DebugMicABOptions: Equatable {
    var module: DebugMicABModule
    var userLanguage: AppLanguage
    var peerLanguage: AppLanguage
    var durationSeconds: Double
    var settleSeconds: Double
    var preemptionPublish: Bool

    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    static var current: DebugMicABOptions? {
        guard let raw = value(for: "-duiyi.micABModule"),
              let module = DebugMicABModule(rawValue: raw.lowercased()) else {
            return nil
        }
        return DebugMicABOptions(
            module: module,
            userLanguage: language(for: "-duiyi.micABUserLanguage", default: .english),
            peerLanguage: language(for: "-duiyi.micABPeerLanguage", default: .japanese),
            durationSeconds: double(for: "-duiyi.micABDuration", default: 60),
            settleSeconds: double(for: "-duiyi.micABSettleSeconds", default: 4),
            preemptionPublish: UtteranceAssemblerExperimentOptions.current
                .publishesPreemptedIncumbent
        )
    }

    private static func language(
        for flag: String,
        default fallback: AppLanguage
    ) -> AppLanguage {
        value(for: flag).flatMap(AppLanguage.init(rawValue:)) ?? fallback
    }

    private static func double(for flag: String, default fallback: Double) -> Double {
        value(for: flag).flatMap(Double.init) ?? fallback
    }

    private static func value(for flag: String) -> String? {
        let args = arguments
        guard let index = args.firstIndex(of: flag) else { return nil }
        let valueIndex = args.index(after: index)
        guard valueIndex < args.endIndex else { return nil }
        return args[valueIndex]
    }
}

enum DebugMicABModule: String {
    case conversation
    case meeting
}

struct DebugMicABReady: Codable {
    var schemaVersion = 1
    var module: String
    var userLanguage: String
    var peerLanguage: String
    var preemptionPublish: Bool
    var at: String
}

struct DebugMicABMarker: Codable {
    var schemaVersion = 1
    var module: String
    var userLanguage: String
    var peerLanguage: String
    var preemptionPublish: Bool
    var startedAt: String
    var finishedAt: String
    var durationSeconds: Double
    var permissionStatus: String
    var listeningStarted: Bool
    var sessionState: String
    var endOutcome: String
    var taskID: String?
    var transcriptCount: Int
    var sourceNonEmptyCount: Int
    var translatedCount: Int
    var diagnosticsFile: String?
    var speechDeviceCapable: Bool?
    var translationPair: String?
    var errors: [String]
}

enum DebugMicABLog {
    private static let lock = NSLock()
    private static let url = URL.documentsDirectory.appending(path: "mic-ab.log")

    static func write(_ message: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "\(formatter.string(from: .now)) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }
}

enum DebugMicABMarkerFile {
    static let readyURL = URL.documentsDirectory.appending(path: "mic-ab-ready.json")
    static let doneURL = URL.documentsDirectory.appending(path: "mic-ab-done.json")

    static func writeReady(_ ready: DebugMicABReady) {
        write(ready, to: readyURL)
    }

    static func writeDone(_ marker: DebugMicABMarker) {
        write(marker, to: doneURL)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: readyURL)
        try? FileManager.default.removeItem(at: doneURL)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
#endif
