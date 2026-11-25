import Foundation
import Testing
@testable import Duiyi

struct TaskMappingTests {
    @Test("A stored corrupted translation is read as absent")
    func corruptedStoredTranslationBecomesEmpty() {
        let entity = TaskEntity(
            id: UUID(),
            featureRaw: FeatureID.faceToFace.rawValue,
            statusRaw: TaskStatus.ended.rawValue,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_060),
            title: "Test",
            sourceLanguageRaw: AppLanguage.english.rawValue,
            targetLanguageRaw: AppLanguage.zhHans.rawValue
        )
        let entry = TranscriptEntity(
            id: UUID(),
            speakerRaw: SpeakerSide.user.rawValue,
            sourceRaw: AppLanguage.english.rawValue,
            sourceText: "Hello",
            translatedText: "你\u{FFFD}好",
            isFinal: true,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_001),
            sortIndex: 0
        )
        entity.entries = [entry]

        let session = TaskMapping.session(from: entity)

        #expect(session?.entries.first?.translatedText == "")
        #expect(session?.entries.first?.sourceText == "Hello")
    }
}
