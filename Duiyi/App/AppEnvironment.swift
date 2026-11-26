import Foundation

@MainActor
@Observable
final class AppEnvironment {
    let preferences: PreferencesStore
    let permissions: any PermissionGranting
    let speechModels: any SpeechModelPreparing
    let translationAvailability: any TranslationAvailabilityChecking
    let speechEngine: any SpeechRecognizing
    /// The one arbitration seam for the shared engine. Features migrating to
    /// `TaskLifecycle` listen through this gate.
    let speechGate: any SpeechSessionGating
    let summarizer: any ConversationSummarizing
    let audioSession: any AudioSessionConfiguring
    let synthesizer: any SpeechSynthesizing
    let taskStore: any TaskStoreV2
    let exporter: any ExportSharing
    let languageCatalog: any LanguageCataloging
    /// Per-task DEBUG diagnostics shared by the speech engine, pipelines, and
    /// the export entry point.
    let diagnostics: any DiagnosticsRecording

    init(
        preferences: PreferencesStore = PreferencesStore(),
        permissions: any PermissionGranting = PermissionService(),
        speechModels: any SpeechModelPreparing = SpeechAssetPreparer(),
        translationAvailability: any TranslationAvailabilityChecking = TranslationAvailabilityService(),
        speechEngine: (any SpeechRecognizing)? = nil,
        speechGate: (any SpeechSessionGating)? = nil,
        summarizer: any ConversationSummarizing = FoundationModelsSummarizer(),
        audioSession: any AudioSessionConfiguring = AudioSessionPolicy(),
        synthesizer: any SpeechSynthesizing = SystemSpeechSynthesizer(),
        taskStore: (any TaskStoreV2)? = nil,
        exporter: any ExportSharing = TranscriptExportService(),
        languageCatalog: any LanguageCataloging = SystemLanguageCatalog(),
        diagnostics: any DiagnosticsRecording = DiagnosticsRecorder()
    ) {
        self.preferences = preferences
        self.permissions = permissions
        self.speechModels = speechModels
        self.translationAvailability = translationAvailability
        let engine = speechEngine ?? BilingualSpeechEngine(diagnostics: diagnostics)
        self.speechEngine = engine
        self.speechGate = speechGate ?? SpeechSessionGate(engine: engine)
        self.summarizer = summarizer
        self.audioSession = audioSession
        self.synthesizer = synthesizer
        self.taskStore = taskStore ?? Self.makeTaskStore()
        self.exporter = exporter
        self.languageCatalog = languageCatalog
        self.diagnostics = diagnostics
    }

    static func makeTaskStore() -> any TaskStoreV2 {
        #if DEBUG
        if let storeURL = DebugIsolatedStore.storeURL {
            return DeferredTaskStore(openContainer: {
                DeferredTaskStore.openContainer(storeURL: storeURL)
            })
        }
        #endif
        // Deferred: zero I/O at init. Real ModelContainer opens after first frame
        // on a utility queue (see DeferredTaskStore). Open failure is exposed as
        // `unavailable`; callers can `retry()`.
        return DeferredTaskStore()
    }
}
