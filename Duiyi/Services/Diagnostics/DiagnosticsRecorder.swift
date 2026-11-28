import Foundation

/// DEBUG-only, per-task diagnostics ring buffer (P1-4a).
///
/// ASR events arrive from the speech actor and translation events from the main
/// actor, so every access is serialized by one lock. The buffer is bounded and
/// aggregate counters are maintained incrementally: evicting an old event never
/// changes the summary. Nothing is uploaded; `makeExportJSON` and
/// `makeExportFile` are local DEBUG conveniences for the TED fixture.
final class DiagnosticsRecorder: DiagnosticsRecording, @unchecked Sendable {
    struct ExportPayload: Codable {
        var schemaVersion: Int
        var generatedAt: Date
        var appVersion: String?
        var appBuild: String?
        var deviceModel: String?
        var systemName: String?
        var systemVersion: String?
        var session: DiagnosticsSessionInfo?
        var summary: DiagnosticsSummary
        var events: [DiagnosticsEvent]
    }

    static let schemaVersion = 1

    private let lock = NSLock()
    private let eventLimit: Int
    private let now: @Sendable () -> Date
    private let submitTimeLimit: Int

    private var session: DiagnosticsSessionInfo?
    private var summary = DiagnosticsSummary()
    private var buffer: [DiagnosticsEvent] = []
    private var bufferStart = 0
    private var submitTimes: [UUID: Date] = [:]
    private var submitOrder: [UUID] = []
    private var settledIDs: Set<UUID> = []
    private var appendedEventCount = 0

    init(
        eventLimit: Int = 4096,
        submitTimeLimit: Int = 4096,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.eventLimit = max(1, eventLimit)
        self.submitTimeLimit = max(1, submitTimeLimit)
        self.now = now
    }

    // MARK: - Session

    var hasSession: Bool {
        lock.lock()
        defer { lock.unlock() }
        return session != nil
    }

    func beginSession(feature: FeatureID, taskID: UUID?) {
        #if DEBUG
        lock.lock()
        defer { lock.unlock() }
        // Bootstrap/restore can run again for an already-active task (module
        // re-entry). Keep its events; only a different or ended session resets.
        if let session,
           session.feature == feature.rawValue,
           session.taskID == taskID?.uuidString,
           session.endedAt == nil {
            return
        }
        session = DiagnosticsSessionInfo(
            feature: feature.rawValue,
            taskID: taskID?.uuidString,
            startedAt: now(),
            endedAt: nil
        )
        summary = DiagnosticsSummary()
        buffer.removeAll(keepingCapacity: true)
        bufferStart = 0
        submitTimes.removeAll(keepingCapacity: true)
        submitOrder.removeAll(keepingCapacity: true)
        settledIDs.removeAll(keepingCapacity: true)
        appendedEventCount = 0
        #endif
    }

    func endSession(taskID: UUID?) {
        #if DEBUG
        lock.lock()
        defer { lock.unlock() }
        guard var session else { return }
        if let taskID, session.taskID != taskID.uuidString { return }
        guard session.endedAt == nil else { return }
        session.endedAt = now()
        self.session = session
        #endif
    }

    // MARK: - ASR

    func record(_ record: ASRDiagnosticsRecord) {
        #if DEBUG
        lock.lock()
        defer { lock.unlock() }
        ensureSessionLocked()
        summary.asrResultCount += 1
        if record.accepted, record.isFinal, record.published, let id = record.utteranceID {
            if settledIDs.insert(id).inserted {
                summary.settledUtterances += 1
            }
        }
        appendLocked(
            DiagnosticsEvent(
                kind: "asr.result",
                at: now(),
                feature: session?.feature,
                utteranceID: record.utteranceID?.uuidString,
                language: record.language.rawValue,
                isFinal: record.isFinal,
                textLength: record.textLength,
                synthetic: record.synthetic,
                scriptMismatch: record.scriptMismatch,
                accepted: record.accepted,
                published: record.published,
                revision: record.revision,
                rangeStart: record.rangeStartSeconds,
                rangeDuration: record.rangeDurationSeconds,
                resultsFinalizationTime: record.resultsFinalizationTimeSeconds,
                confidenceRunCount: record.confidenceRunCount,
                confidenceMinimum: record.confidenceMinimum,
                confidenceMean: record.confidenceMean,
                confidenceBuckets: record.confidenceBuckets,
                style: record.style
            )
        )
        #endif
    }

    func record(_ record: ASRDropRecord) {
        #if DEBUG
        lock.lock()
        defer { lock.unlock() }
        ensureSessionLocked()
        summary.asrDropCount += 1
        appendLocked(
            DiagnosticsEvent(
                kind: "asr.drop",
                at: now(),
                feature: session?.feature,
                language: record.language.rawValue,
                isFinal: record.isFinal,
                textLength: record.textLength,
                rangeStart: record.rangeStartSeconds,
                rangeDuration: record.rangeDurationSeconds,
                dropReason: record.reason,
                style: record.style
            )
        )
        #endif
    }

    func record(_ record: SpeechPreemptionRecord) {
        #if DEBUG
        lock.lock()
        defer { lock.unlock() }
        ensureSessionLocked()
        summary.preemptionCount += 1
        appendLocked(
            DiagnosticsEvent(
                kind: "speech.preemption",
                at: now(),
                feature: session?.feature,
                language: record.incumbentLanguage.rawValue,
                textLength: record.incumbentTextLength,
                applied: record.applied,
                rangeStart: record.rangeStartSeconds,
                rangeDuration: record.rangeDurationSeconds,
                challengerLanguage: record.challengerLanguage.rawValue,
                challengerLength: record.challengerTextLength,
                incumbentConfident: record.incumbentConfident,
                challengerConfident: record.challengerConfident,
                incumbentVisible: record.incumbentVisible,
                queuedFinal: record.queuedFinal,
                style: record.style
            )
        )
        #endif
    }

    func record(_ record: SpeechStartRecord) {
        #if DEBUG
        lock.lock()
        defer { lock.unlock() }
        ensureSessionLocked()
        summary.speechStartCount += 1
        appendLocked(
            DiagnosticsEvent(
                kind: "speech.start",
                at: now(),
                feature: session?.feature,
                requestedLanguages: record.requestedLanguages,
                activeLanguages: record.activeLanguages,
                usingDual: record.usingDual,
                style: record.style
            )
        )
        #endif
    }

    // MARK: - Speech failures

    func record(_ record: SpeechFailureRecord) {
        #if DEBUG
        lock.lock()
        defer { lock.unlock() }
        ensureSessionLocked()
        appendLocked(
            DiagnosticsEvent(
                kind: "speech.failure",
                at: now(),
                feature: session?.feature,
                language: record.language.rawValue,
                style: record.style,
                errorDomain: record.errorDomain,
                errorCode: record.errorCode,
                recovery: record.recovery.rawValue
            )
        )
        #endif
    }

    // MARK: - Translation

    func recordSubmit(_ record: TranslationSubmitRecord) {
        #if DEBUG
        lock.lock()
        defer { lock.unlock() }
        ensureSessionLocked()
        summary.translationSubmitCount += 1
        if record.isFinal {
            summary.finalJobCount += 1
        }
        rememberSubmitLocked(jobID: record.jobID, at: now())
        appendLocked(
            DiagnosticsEvent(
                kind: "translation.submit",
                at: now(),
                feature: session?.feature,
                utteranceID: record.utteranceID.uuidString,
                jobID: record.jobID.uuidString,
                sequence: record.sequence,
                isFinal: record.isFinal,
                style: record.strategy,
                sourceLanguage: record.source.rawValue,
                targetLanguage: record.target.rawValue,
                sourceLength: record.sourceLength,
                sourceHash: record.sourceHash
            )
        )
        #endif
    }

    func recordApply(_ record: TranslationApplyRecord) {
        #if DEBUG
        lock.lock()
        defer { lock.unlock() }
        ensureSessionLocked()
        if record.isFinal, record.applied {
            summary.finalAppliedCount += 1
        }
        let latency = latencyLocked(jobID: record.jobID)
        if record.applied { forgetSubmitLocked(jobID: record.jobID) }
        appendLocked(
            DiagnosticsEvent(
                kind: "translation.apply",
                at: now(),
                feature: session?.feature,
                utteranceID: record.utteranceID.uuidString,
                jobID: record.jobID.uuidString,
                sequence: record.sequence,
                isFinal: record.isFinal,
                accepted: record.applied,
                translatedLength: record.translatedLength,
                replacementCharacters: record.replacementCharacterCount,
                latencyMilliseconds: latency,
                reason: record.reason
            )
        )
        #endif
    }

    func recordResponse(_ record: TranslationResponseRecord) {
        #if DEBUG
        lock.lock()
        defer { lock.unlock() }
        ensureSessionLocked()
        summary.translationResponseCount += 1
        let latency = latencyLocked(jobID: record.jobID)
        appendLocked(
            DiagnosticsEvent(
                kind: "translation.result",
                at: now(),
                feature: session?.feature,
                utteranceID: record.utteranceID.uuidString,
                jobID: record.jobID.uuidString,
                sequence: record.sequence,
                isFinal: record.isFinal,
                translatedLength: record.translatedLength,
                replacementCharacters: record.replacementCharacterCount,
                responseSourceLanguage: record.responseSourceLanguage,
                responseTargetLanguage: record.responseTargetLanguage,
                latencyMilliseconds: latency,
                retryCount: record.retryCount
            )
        )
        #endif
    }

    func recordFailure(_ record: TranslationFailureRecord) {
        #if DEBUG
        lock.lock()
        defer { lock.unlock() }
        ensureSessionLocked()
        summary.permanentFailureCount += 1
        if record.failure == "corruptedOutput" {
            summary.rejectedCorruptionCount += 1
        }
        let latency = latencyLocked(jobID: record.jobID)
        forgetSubmitLocked(jobID: record.jobID)
        appendLocked(
            DiagnosticsEvent(
                kind: "translation.failure",
                at: now(),
                feature: session?.feature,
                utteranceID: record.utteranceID.uuidString,
                jobID: record.jobID.uuidString,
                sequence: record.sequence,
                isFinal: record.isFinal,
                latencyMilliseconds: latency,
                retryCount: record.retryCount,
                failure: record.failure
            )
        )
        #endif
    }

    // MARK: - Export

    func snapshot() -> DiagnosticsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        var currentSummary = summary
        currentSummary.droppedEventCount = droppedCountLocked()
        return DiagnosticsSnapshot(
            schemaVersion: Self.schemaVersion,
            session: session,
            summary: currentSummary,
            events: eventsLocked()
        )
    }

    func makeExportJSON() -> Data? {
        #if DEBUG
        let snapshot = snapshot()
        guard snapshot.session != nil else { return nil }
        let payload = ExportPayload(
            schemaVersion: Self.schemaVersion,
            generatedAt: now(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
            deviceModel: Self.deviceModel(),
            systemName: Self.systemName,
            systemVersion: Self.systemVersion,
            session: snapshot.session,
            summary: snapshot.summary,
            events: snapshot.events
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601.string(from: date))
        }
        return try? encoder.encode(payload)
        #else
        return nil
        #endif
    }

    func makeExportFile() -> URL? {
        #if DEBUG
        guard let data = makeExportJSON() else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "duiyi-diagnostics-\(formatter.string(from: now())).json"
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = directory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            DuiyiLog.session.error(
                "Diagnostics export failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
        #else
        return nil
        #endif
    }

    // MARK: - Locked helpers

    private func ensureSessionLocked() {
        guard session == nil else { return }
        session = DiagnosticsSessionInfo(
            feature: "unattributed",
            taskID: nil,
            startedAt: now(),
            endedAt: nil
        )
    }

    private func appendLocked(_ event: DiagnosticsEvent) {
        appendedEventCount += 1
        if buffer.count < eventLimit {
            buffer.append(event)
        } else {
            buffer[bufferStart] = event
            bufferStart = (bufferStart + 1) % eventLimit
        }
    }

    private func droppedCountLocked() -> Int {
        max(0, appendedEventCount - eventLimit)
    }

    private func eventsLocked() -> [DiagnosticsEvent] {
        guard buffer.count >= eventLimit else { return buffer }
        return Array(buffer[bufferStart...]) + Array(buffer[..<bufferStart])
    }

    private func rememberSubmitLocked(jobID: UUID, at date: Date) {
        if submitTimes[jobID] == nil {
            submitOrder.append(jobID)
        }
        submitTimes[jobID] = date
        while submitOrder.count > submitTimeLimit {
            let oldest = submitOrder.removeFirst()
            submitTimes[oldest] = nil
        }
    }

    private func forgetSubmitLocked(jobID: UUID) {
        guard submitTimes.removeValue(forKey: jobID) != nil else { return }
        submitOrder.removeAll { $0 == jobID }
    }

    private func latencyLocked(jobID: UUID) -> Double? {
        guard let submitted = submitTimes[jobID] else { return nil }
        return max(0, now().timeIntervalSince(submitted) * 1000)
    }

    private static func deviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static var systemName: String {
        #if os(iOS)
        "iOS"
        #elseif os(macOS)
        "macOS"
        #else
        ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }

    private static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
