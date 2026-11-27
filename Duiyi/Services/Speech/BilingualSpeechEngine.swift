import AVFAudio
import CoreMedia
import Foundation
import Speech

actor BilingualSpeechEngine: SpeechRecognizing {
    private let capturer: AudioCapturing
    private let diagnostics: any DiagnosticsRecording
    private var assembler = UtteranceAssembler()
    private var utteranceContinuation: AsyncStream<Utterance>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var consumeTasks: [Task<Void, Never>] = []
    private var audioTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?
    private var reservedLocales: [Locale] = []
    private var lastFinalSignature: String?
    private var ignoreTranscriptionUntil: Date = .distantPast
    private var converter = BufferConverter()
    private var analyzerFormat: AVAudioFormat?
    private var stopDepth = 0
    private var isStopping: Bool { stopDepth > 0 }
    private var usingDual = true
    /// True from the moment a dual transcriber failure schedules a single-locale
    /// fallback until that fallback finishes. Other failing consumers defer to
    /// the in-flight restart instead of finishing the stream themselves.
    private var isRecoveringFromTranscriberFailure = false
    /// The scheduled single-locale fallback. `stop()` cancels it so a failure
    /// reported just before a pause cannot restart the microphone afterwards.
    private var fallbackTask: Task<Void, Never>?
    private static let stopDrain: Duration = .milliseconds(300)
    private static let finalizeTimeout: Duration = .seconds(1)
    /// How long a silence boundary waits for the transcriber's own final after
    /// `finalize(through: nil)` before synthesizing one.
    private static let silenceFinalizeWindow: Duration = .milliseconds(350)
    private var pairLanguages: [AppLanguage] = [.zhHans, .english]
    private var requestedLanguageCount = 0
    private var singleLanguage: AppLanguage = .english
    private var style: SpeechRecognitionStyle = .liveCaptions

    init(
        capturer: AudioCapturing = AudioEngineCapturer(),
        diagnostics: any DiagnosticsRecording = NoOpDiagnosticsRecorder()
    ) {
        self.capturer = capturer
        self.diagnostics = diagnostics
    }

    func start(
        languages: [AppLanguage],
        fallbackLanguage: AppLanguage,
        style: SpeechRecognitionStyle
    ) async throws -> AsyncStream<Utterance> {
        await stop()
        isRecoveringFromTranscriberFailure = false
        assembler.reset()
        lastFinalSignature = nil
        self.style = style
        let requested = Array(
            Self.normalizedLanguages(languages: languages, fallback: fallbackLanguage).prefix(2)
        )
        requestedLanguageCount = requested.count
        pairLanguages = requested
        singleLanguage = fallbackLanguage

        let (stream, continuation) = AsyncStream<Utterance>.makeStream()
        utteranceContinuation = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stop() }
        }

        do {
            try await startBestPipeline(languages: requested, fallback: fallbackLanguage)
        } catch {
            throw error
        }

        return stream
    }

    func stop() async {
        stopDepth += 1
        defer { stopDepth -= 1 }

        fallbackTask?.cancel()
        fallbackTask = nil
        silenceTask?.cancel()
        silenceTask = nil
        audioTask?.cancel()
        audioTask = nil
        await capturer.stop()
        inputContinuation?.finish()
        inputContinuation = nil

        await finalizeOpenRange()

        for task in consumeTasks {
            task.cancel()
        }
        consumeTasks.removeAll()
        converter = BufferConverter()
        utteranceContinuation?.finish()
        utteranceContinuation = nil
        for locale in reservedLocales {
            _ = await AssetInventory.release(reservedLocale: locale)
        }
        reservedLocales.removeAll()
    }

    /// Let the analyzer publish the final for the open range, then give the
    /// transcriber consumers a bounded window to deliver it. A synthetic final
    /// covers a framework that returns no final at all.
    private func finalizeOpenRange() async {
        guard let analyzer else { return }
        let finalized = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                    return true
                } catch {
                    DuiyiLog.speech.error(
                        "Analyzer finalize failed: \(error.localizedDescription, privacy: .public)"
                    )
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(for: Self.finalizeTimeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        if !finalized {
            DuiyiLog.speech.error("Analyzer finalize failed or timed out")
            await analyzer.cancelAndFinishNow()
        }
        self.analyzer = nil
        try? await Task.sleep(for: Self.stopDrain)
        if let utterance = assembler.silenceTimedOut() {
            publishSynthetic(utterance)
        }
    }

    private func startBestPipeline(languages: [AppLanguage], fallback: AppLanguage) async throws {
        var remaining = languages
        while !remaining.isEmpty {
            do {
                if remaining.count >= 2 {
                    try await startMultiPipeline(languages: remaining)
                    usingDual = true
                    pairLanguages = Array(remaining.prefix(2))
                    return
                }
                try await startSinglePipeline(language: remaining[0])
                usingDual = false
                return
            } catch {
                guard Self.isResourceLimit(error), remaining.count > 1 else {
                    throw error
                }
                DuiyiLog.speech.error(
                    "Locale set of \(remaining.count, privacy: .public) failed, dropping \(remaining.last?.rawValue ?? "", privacy: .public)"
                )
                remaining.removeLast()
                await resetPipelineKeepingStream()
            }
        }
        DuiyiLog.speech.error("Dual transcribers unavailable, falling back to single locale")
        try await startSinglePipeline(language: fallback)
        usingDual = false
    }

    private func startMultiPipeline(languages: [AppLanguage]) async throws {
        let pair = Array(languages.prefix(2))
        pairLanguages = pair
        guard pair.count == 2 else {
            try await startSinglePipeline(language: pair[0])
            return
        }
        try await startDualPipeline()
    }

    private func resetPipelineKeepingStream() async {
        stopDepth += 1
        defer { stopDepth -= 1 }

        silenceTask?.cancel()
        silenceTask = nil
        audioTask?.cancel()
        audioTask = nil
        await capturer.stop()
        inputContinuation?.finish()
        inputContinuation = nil
        await finalizeOpenRange()
        for task in consumeTasks {
            task.cancel()
        }
        consumeTasks.removeAll()
        converter = BufferConverter()
        for locale in reservedLocales {
            _ = await AssetInventory.release(reservedLocale: locale)
        }
        reservedLocales.removeAll()
    }

    private func startDualPipeline() async throws {
        // Two transcribers: keep rejecting results that look like the other
        // locale, otherwise the rows can leak into each other.
        assembler.languagePurity = .strict
        let firstLanguage = pairLanguages[0]
        let secondLanguage = pairLanguages[1]
        let firstLocale = try await resolvedLocale(for: firstLanguage)
        let secondLocale = try await resolvedLocale(for: secondLanguage)
        try await reserve([firstLocale, secondLocale])

        let first = Self.makeTranscriber(locale: firstLocale)
        let second = Self.makeTranscriber(locale: secondLocale)
        let detector = SpeechDetector(
            detectionOptions: SpeechDetector.DetectionOptions(sensitivityLevel: .medium),
            reportResults: true
        )
        var modules: [any SpeechModule] = [first, second, detector]

        do {
            try await run(modules: modules)
        } catch {
            if Self.isResourceLimit(error) {
                DuiyiLog.speech.error("Detector plus dual transcribers failed, retrying without detector")
                modules = [first, second]
                try await run(modules: modules)
            } else {
                throw error
            }
        }

        consume(transcriber: first, language: firstLanguage)
        consume(transcriber: second, language: secondLanguage)
        consume(detector: detector)
    }

    private func startSinglePipeline(
        language: AppLanguage,
        forceTrustedLocale: Bool = false
    ) async throws {
        assembler.languagePurity = Self.singleLocalePurity(
            forceTrustedLocale: forceTrustedLocale,
            requestedLanguageCount: requestedLanguageCount,
            style: style
        )
        singleLanguage = language
        let locale = try await resolvedLocale(for: language)
        try await reserve([locale])
        let transcriber = Self.makeTranscriber(locale: locale)
        try await run(modules: [transcriber])
        consume(transcriber: transcriber, language: language)
    }

    private func run(modules: [any SpeechModule]) async throws {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw DuiyiError.deviceIncapable
        }
        analyzerFormat = format
        let options = style == .meetingNotes
            ? SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse)
            : nil
        let analyzer = SpeechAnalyzer(modules: modules, options: options)
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: format)

        let (input, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        let audioStream = try await capturer.start()
        audioTask = Task { [weak self] in
            guard let self else { return }
            for await packet in audioStream {
                await self.ingest(packet.buffer)
            }
        }

        consumeTasks.append(
            Task { [weak self] in
                do {
                    try await analyzer.start(inputSequence: input)
                } catch is CancellationError {
                    return
                } catch {
                    DuiyiLog.speech.error("Analyzer failed: \(error.localizedDescription, privacy: .public)")
                    await self?.fail()
                }
            }
        )
    }

    private func ingest(_ buffer: AVAudioPCMBuffer) async {
        guard let format = analyzerFormat, let inputContinuation else { return }
        do {
            let converted = try converter.convert(buffer, to: format)
            inputContinuation.yield(AnalyzerInput(buffer: converted))
        } catch {
            DuiyiLog.audio.error("Audio convert failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func consume(transcriber: SpeechTranscriber, language: AppLanguage) {
        consumeTasks.append(
            Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        await self?.handleTranscription(
                            language: language,
                            text: text,
                            isFinal: result.isFinal,
                            rangeStart: Self.seconds(result.range.start),
                            rangeDuration: Self.seconds(result.range.duration),
                            resultsFinalizationTime: Self.seconds(result.resultsFinalizationTime)
                        )
                    }
                } catch is CancellationError {
                    return
                } catch {
                    DuiyiLog.speech.error("Transcriber failed: \(error.localizedDescription, privacy: .public)")
                    let nsError = error as NSError
                    await self?.handleTranscriberFailure(
                        language: language,
                        errorDomain: nsError.domain,
                        errorCode: nsError.code
                    )
                }
            }
        )
    }

    /// A dual-locale failure restarts the failed language as the only
    /// transcriber. The restart runs on a separate task because it cancels the
    /// consume tasks, including the one that reported this failure; calling it
    /// inline would make the failing consumer cancel itself.
    private func handleTranscriberFailure(
        language: AppLanguage,
        errorDomain: String,
        errorCode: Int
    ) {
        let plan = Self.transcriberFailurePlan(
            usingDual: usingDual,
            isStopping: isStopping,
            isRecovering: isRecoveringFromTranscriberFailure
        )
        recordSpeechFailure(
            language: language,
            errorDomain: errorDomain,
            errorCode: errorCode,
            recovery: plan.recovery
        )
        if plan.failStream {
            fail()
            return
        }
        guard plan.recovery == .singleFallback else { return }
        isRecoveringFromTranscriberFailure = true
        fallbackTask = Task { [weak self] in
            await self?.fallbackToSingle(language: language)
        }
    }

    private func fallbackToSingle(language: AppLanguage) async {
        defer {
            isRecoveringFromTranscriberFailure = false
            fallbackTask = nil
        }
        guard !Task.isCancelled else { return }
        guard !isStopping else {
            fail()
            return
        }
        DuiyiLog.speech.info(
            "Falling back to single locale \(language.rawValue, privacy: .public) after transcriber failure"
        )
        do {
            try await restartPipelineSingle(language: language, forceTrustedLocale: true)
        } catch {
            guard !Task.isCancelled else { return }
            DuiyiLog.speech.error(
                "Single locale fallback failed: \(error.localizedDescription, privacy: .public)"
            )
            let nsError = error as NSError
            recordSpeechFailure(
                language: language,
                errorDomain: nsError.domain,
                errorCode: nsError.code,
                recovery: .restartFailed
            )
            fail()
        }
    }

    private func recordSpeechFailure(
        language: AppLanguage,
        errorDomain: String,
        errorCode: Int,
        recovery: SpeechFailureRecovery
    ) {
        diagnostics.record(
            SpeechFailureRecord(
                language: language,
                errorDomain: errorDomain,
                errorCode: errorCode,
                recovery: recovery,
                style: styleName
            )
        )
    }

    private func consume(detector: SpeechDetector) {
        consumeTasks.append(
            Task { [weak self] in
                do {
                    for try await result in detector.results {
                        await self?.handleVoiceActivity(result.speechDetected)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    DuiyiLog.speech.error("Detector failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        )
    }

    private func handleTranscription(
        language: AppLanguage,
        text: String,
        isFinal: Bool,
        rangeStart: Double?,
        rangeDuration: Double?,
        resultsFinalizationTime: Double?
    ) {
        if Date() < ignoreTranscriptionUntil {
            return
        }
        let scriptMismatch = UtteranceAssembler.isScriptMismatch(text, claimed: language)
        let range = SpeechRange(rangeStart: rangeStart, rangeDuration: rangeDuration)
        guard let utterance = assembler.ingest(
            language: language,
            text: text,
            isFinal: isFinal,
            range: range
        ) else {
            recordASR(
                language: language,
                textLength: text.count,
                isFinal: isFinal,
                synthetic: false,
                scriptMismatch: scriptMismatch,
                accepted: false,
                published: false,
                utterance: nil,
                rangeStart: rangeStart,
                rangeDuration: rangeDuration,
                resultsFinalizationTime: resultsFinalizationTime
            )
            return
        }
        let published = publish(utterance)
        recordASR(
            language: language,
            textLength: text.count,
            isFinal: isFinal,
            synthetic: false,
            scriptMismatch: scriptMismatch,
            accepted: true,
            published: published,
            utterance: utterance,
            rangeStart: rangeStart,
            rangeDuration: rangeDuration,
            resultsFinalizationTime: resultsFinalizationTime
        )
        if Self.shouldAcknowledgeFinal(utterance) {
            assembler.acknowledgeFinal(language: utterance.language)
            scheduleSingleLocaleSwitchIfNeeded(to: utterance.language)
        }
        pingSilenceTimer()
    }

    private var styleName: String {
        style == .meetingNotes ? "meetingNotes" : "liveCaptions"
    }

    private func publishSynthetic(_ utterance: Utterance) {
        let published = publish(utterance)
        recordASR(
            language: utterance.language,
            textLength: utterance.text.count,
            isFinal: true,
            synthetic: true,
            scriptMismatch: false,
            accepted: true,
            published: published,
            utterance: utterance,
            rangeStart: nil,
            rangeDuration: nil,
            resultsFinalizationTime: nil
        )
    }

    private func recordASR(
        language: AppLanguage,
        textLength: Int,
        isFinal: Bool,
        synthetic: Bool,
        scriptMismatch: Bool,
        accepted: Bool,
        published: Bool,
        utterance: Utterance?,
        rangeStart: Double?,
        rangeDuration: Double?,
        resultsFinalizationTime: Double?
    ) {
        diagnostics.record(
            ASRDiagnosticsRecord(
                language: language,
                textLength: textLength,
                isFinal: isFinal,
                synthetic: synthetic,
                scriptMismatch: scriptMismatch,
                accepted: accepted,
                published: published,
                utteranceID: utterance?.id,
                revision: utterance?.isRevision ?? false,
                rangeStartSeconds: rangeStart,
                rangeDurationSeconds: rangeDuration,
                resultsFinalizationTimeSeconds: resultsFinalizationTime,
                style: styleName
            )
        )
    }

    /// A revision updates an utterance that was already closed; it is not the
    /// current final, so it must not re-lock the language or switch the
    /// single-locale pipeline.
    nonisolated static func shouldAcknowledgeFinal(_ utterance: Utterance) -> Bool {
        utterance.isFinal && !utterance.isRevision
    }

    /// What a failed transcriber consumer should do. Pure so the fallback
    /// branches stay unit-testable without constructing `SpeechTranscriber`s.
    struct SpeechFailurePlan: Equatable, Sendable {
        var recovery: SpeechFailureRecovery
        var failStream: Bool
    }

    nonisolated static func transcriberFailurePlan(
        usingDual: Bool,
        isStopping: Bool,
        isRecovering: Bool
    ) -> SpeechFailurePlan {
        if isStopping {
            return SpeechFailurePlan(recovery: .none, failStream: true)
        }
        if isRecovering {
            // Another failure already scheduled the fallback; let that task
            // own the outcome instead of ending the stream from here.
            return SpeechFailurePlan(recovery: .none, failStream: false)
        }
        if usingDual {
            return SpeechFailurePlan(recovery: .singleFallback, failStream: false)
        }
        return SpeechFailurePlan(recovery: .none, failStream: true)
    }

    /// A genuinely single-locale request trusts its transcriber; a degraded
    /// dual request and meeting notes stay strict. A failure fallback is an
    /// explicit single-locale pipeline, so it forces trusted locale for live
    /// captions even when the session originally requested two; meeting notes
    /// always stay strict.
    nonisolated static func singleLocalePurity(
        forceTrustedLocale: Bool,
        requestedLanguageCount: Int,
        style: SpeechRecognitionStyle
    ) -> SpeechLanguagePurity {
        if style == .meetingNotes { return .strict }
        if forceTrustedLocale { return .trustedLocale }
        return requestedLanguageCount <= 1 ? .trustedLocale : .strict
    }

    private func handleVoiceActivity(_ speechDetected: Bool) {
        if speechDetected {
            silenceTask?.cancel()
            silenceTask = nil
        } else {
            pingSilenceTimer()
        }
    }

    private func pingSilenceTimer() {
        guard !isStopping else { return }
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(ConversationLayout.silenceCommitMilliseconds))
            guard !Task.isCancelled else { return }
            await self?.finalizeFromSilence()
        }
    }

    private func finalizeFromSilence() async {
        guard !isStopping, assembler.hasOpenRow else { return }
        // Ask the analyzer to finalize only when a volatile tail still exists.
        // A row made only of finalized phrases has nothing to synthesize; the
        // silence timer just advances the row boundary so a long pause cannot
        // be swallowed by the next contiguous range.
        if assembler.hasOpenRange, let analyzer {
            do {
                try await analyzer.finalize(through: nil)
            } catch {
                DuiyiLog.speech.error(
                    "Analyzer finalize on silence failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            try? await Task.sleep(for: Self.silenceFinalizeWindow)
            guard !Task.isCancelled, !isStopping else { return }
        }
        guard let utterance = assembler.silenceTimedOut() else { return }
        publishSynthetic(utterance)
        scheduleSingleLocaleSwitchIfNeeded(to: utterance.language)
    }

    @discardableResult
    private func publish(_ utterance: Utterance) -> Bool {
        if utterance.isFinal {
            let signature = Self.signature(utterance)
            if signature == lastFinalSignature {
                return false
            }
            lastFinalSignature = signature
        }
        utteranceContinuation?.yield(utterance)
        return true
    }

    private func fail() {
        utteranceContinuation?.finish()
    }

    private func scheduleSingleLocaleSwitchIfNeeded(to language: AppLanguage) {
        guard !isStopping,
              !usingDual,
              !isRecoveringFromTranscriberFailure,
              language != singleLanguage else { return }
        Task { [weak self] in
            await self?.restartSingle(language: language)
        }
    }

    /// The ordinary single-locale drift switch. It keeps the existing purity
    /// rule: an explicit single-locale request is trusted, while a degraded
    /// dual request and meeting notes stay strict.
    private func restartSingle(language: AppLanguage) async {
        guard !isStopping, !isRecoveringFromTranscriberFailure else { return }
        do {
            try await restartPipelineSingle(language: language)
        } catch {
            DuiyiLog.speech.error("Single locale restart failed: \(error.localizedDescription, privacy: .public)")
            fail()
        }
    }

    /// Shared single-locale restart for the drift switch and the failure
    /// fallback. Throws when the new pipeline cannot start so the caller can
    /// decide whether to record `restartFailed` and finish the stream.
    private func restartPipelineSingle(
        language: AppLanguage,
        forceTrustedLocale: Bool = false
    ) async throws {
        guard !Task.isCancelled, !isStopping else { return }
        DuiyiLog.speech.info("Switching single transcriber to \(language.rawValue, privacy: .public)")
        await resetPipelineKeepingStream()
        guard !Task.isCancelled, !isStopping else { return }
        assembler.reset()
        try await startSinglePipeline(language: language, forceTrustedLocale: forceTrustedLocale)
        guard !Task.isCancelled, !isStopping else { return }
        usingDual = false
    }

    private func resolvedLocale(for language: AppLanguage) async throws -> Locale {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: language.locale) else {
            throw DuiyiError.languageUnsupported
        }
        return locale
    }

    private func reserve(_ locales: [Locale]) async throws {
        for locale in locales {
            do {
                _ = try await AssetInventory.reserve(locale: locale)
                reservedLocales.append(locale)
            } catch {
                if Self.isResourceLimit(error) {
                    throw error
                }
                DuiyiLog.speech.error("Locale reserve failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [.etiquetteReplacements],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.transcriptionConfidence]
        )
    }

    /// CMTime may be indefinite or invalid; only finite seconds are recorded.
    private static func seconds(_ time: CMTime) -> Double? {
        guard time.isNumeric else { return nil }
        let value = time.seconds
        return value.isFinite ? value : nil
    }

    private static func signature(_ utterance: Utterance) -> String {
        // Include the row id: an identical sentence repeated in a new row must
        // not be dropped, while duplicate finals for the same row still are.
        let filtered = utterance.text.lowercased().filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
        return "\(utterance.id.uuidString)-\(utterance.language.rawValue)-\(filtered)"
    }

    static func normalizedLanguages(languages: [AppLanguage], fallback: AppLanguage) -> [AppLanguage] {
        var unique: [AppLanguage] = []
        for language in languages where !unique.contains(language) {
            unique.append(language)
        }
        if unique.isEmpty {
            unique.append(fallback)
        }
        return unique
    }

    private static func isResourceLimit(_ error: Error) -> Bool {
        if let speechError = error as? SFSpeechError {
            switch speechError.code {
            case .insufficientResources, .tooManyAssetLocalesAllocated:
                return true
            default:
                return false
            }
        }
        let nsError = error as NSError
        return nsError.domain.contains("Speech") && [
            SFSpeechError.Code.insufficientResources.rawValue,
            SFSpeechError.Code.tooManyAssetLocalesAllocated.rawValue
        ].contains(nsError.code)
    }
}
