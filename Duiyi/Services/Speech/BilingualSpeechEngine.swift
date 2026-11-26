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
    private static let stopDrain: Duration = .milliseconds(300)
    private static let finalizeTimeout: Duration = .seconds(1)
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

    private func startSinglePipeline(language: AppLanguage) async throws {
        // Trust the single transcriber only when the session was genuinely
        // requested as one language. A dual request that degraded after a
        // resource limit keeps the strict gate, and meeting notes stay strict.
        assembler.languagePurity = requestedLanguageCount <= 1 && style != .meetingNotes
            ? .trustedLocale
            : .strict
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
                    await self?.fail()
                }
            }
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
        guard let utterance = assembler.ingest(language: language, text: text, isFinal: isFinal) else {
            diagnostics.record(
                ASRDiagnosticsRecord(
                    language: language,
                    textLength: text.count,
                    isFinal: isFinal,
                    synthetic: false,
                    scriptMismatch: scriptMismatch,
                    accepted: false,
                    published: false,
                    utteranceID: nil,
                    revision: false,
                    rangeStartSeconds: rangeStart,
                    rangeDurationSeconds: rangeDuration,
                    resultsFinalizationTimeSeconds: resultsFinalizationTime,
                    style: styleName
                )
            )
            return
        }
        let published = publish(utterance)
        diagnostics.record(
            ASRDiagnosticsRecord(
                language: language,
                textLength: text.count,
                isFinal: isFinal,
                synthetic: false,
                scriptMismatch: scriptMismatch,
                accepted: true,
                published: published,
                utteranceID: utterance.id,
                revision: utterance.isRevision,
                rangeStartSeconds: rangeStart,
                rangeDurationSeconds: rangeDuration,
                resultsFinalizationTimeSeconds: resultsFinalizationTime,
                style: styleName
            )
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
        diagnostics.record(
            ASRDiagnosticsRecord(
                language: utterance.language,
                textLength: utterance.text.count,
                isFinal: true,
                synthetic: true,
                scriptMismatch: false,
                accepted: true,
                published: published,
                utteranceID: utterance.id,
                revision: false,
                rangeStartSeconds: nil,
                rangeDurationSeconds: nil,
                resultsFinalizationTimeSeconds: nil,
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

    private func finalizeFromSilence() {
        guard !isStopping else { return }
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
        guard !isStopping, !usingDual, language != singleLanguage else { return }
        Task { [weak self] in
            await self?.restartSingle(language: language)
        }
    }

    private func restartSingle(language: AppLanguage) async {
        guard !isStopping else { return }
        DuiyiLog.speech.info("Switching single transcriber to \(language.rawValue, privacy: .public)")
        await resetPipelineKeepingStream()
        guard !isStopping else { return }
        assembler.reset()
        do {
            try await startSinglePipeline(language: language)
            guard !isStopping else { return }
            usingDual = false
        } catch {
            DuiyiLog.speech.error("Single locale restart failed: \(error.localizedDescription, privacy: .public)")
            fail()
        }
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
        let filtered = utterance.text.lowercased().filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
        return "\(utterance.language.rawValue)-\(filtered)"
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
