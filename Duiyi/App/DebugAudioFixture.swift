#if DEBUG
import Foundation

/// Launch-argument configuration for replaying a fixture through the real
/// speech engine. Debug builds only; absent arguments mean no fixture path.
///
/// Example:
///   -duiyi.fixtureAudio Documents/TED.wav
///   -duiyi.fixturePacing realtime
///   -duiyi.fixtureAutoRun YES
///   -duiyi.fixtureSettleSeconds 10
enum DebugAudioFixture {
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    static var isRequested: Bool {
        value(for: "-duiyi.fixtureAudio") != nil
    }

    static var autoRun: Bool {
        guard let raw = value(for: "-duiyi.fixtureAutoRun") else { return true }
        return !["no", "false", "0"].contains(raw.lowercased())
    }

    static var settleSeconds: Double {
        value(for: "-duiyi.fixtureSettleSeconds").flatMap(Double.init) ?? 10
    }

    static var deleteAfterRun: Bool {
        guard let raw = value(for: "-duiyi.fixtureDeleteAfterRun") else { return false }
        return !["no", "false", "0"].contains(raw.lowercased())
    }

    static var fixtureURL: URL? {
        guard let raw = value(for: "-duiyi.fixtureAudio"), !raw.isEmpty else { return nil }
        if raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw)
        }
        // Accept both `smoke.wav` and `Documents/smoke.wav`; the latter is how
        // devicectl destinations are usually written.
        let relative = raw.hasPrefix("Documents/")
            ? String(raw.dropFirst("Documents/".count))
            : raw
        return URL.documentsDirectory.appending(path: relative)
    }

    static var pacing: FixtureAudioCapturer.Pacing {
        guard let raw = value(for: "-duiyi.fixturePacing"),
              let pacing = FixtureAudioCapturer.Pacing(rawValue: raw.lowercased()) else {
            return .realtime
        }
        return pacing
    }

    static func makeCapturerIfRequested() -> FixtureAudioCapturer? {
        guard let url = fixtureURL else { return nil }
        return FixtureAudioCapturer(configuration: .init(url: url, pacing: pacing))
    }

    private static func value(for flag: String) -> String? {
        let args = arguments
        guard let index = args.firstIndex(of: flag) else { return nil }
        let valueIndex = args.index(after: index)
        guard valueIndex < args.endIndex else { return nil }
        return args[valueIndex]
    }
}

struct DebugFixtureMarker: Codable {
    var schemaVersion = 1
    var fixture: String
    var pacing: String
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
    var capturer: [String: String]
    var speechDeviceCapable: Bool?
    var translationPair: String?
    var errors: [String]
}

enum DebugFixtureLog {
    private static let lock = NSLock()
    private static let url = URL.documentsDirectory.appending(path: "fixture-run.log")

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

enum DebugFixtureMarkerFile {
    static let url = URL.documentsDirectory.appending(path: "fixture-run-done.json")

    static func write(_ marker: DebugFixtureMarker) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(marker) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
#endif
