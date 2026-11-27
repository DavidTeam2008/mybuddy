#if DEBUG
import AVFAudio
import Foundation
import Testing
@testable import Duiyi

struct FixtureAudioCapturerTests {
    @Test func replaysEveryFrameAndReportsEOF() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "fixture-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let frames: AVAudioFrameCount = 4_800
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            try file.write(from: buffer)
        }

        let capturer = FixtureAudioCapturer(
            configuration: .init(url: url, pacing: .max)
        )
        let stream = try await capturer.start()
        var received: AVAudioFramePosition = 0
        var buffers = 0
        for await packet in stream {
            received += AVAudioFramePosition(packet.buffer.frameLength)
            buffers += 1
        }

        #expect(received == AVAudioFramePosition(frames))
        #expect(buffers == 5)
        let stats = await capturer.stats()
        #expect(stats.finished)
        #expect(stats.sentFrames == AVAudioFramePosition(frames))
    }
}
#endif
