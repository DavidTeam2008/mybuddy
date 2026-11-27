#if DEBUG
import AVFAudio
import Foundation

/// Debug-only capturer that replays a fixture file through the same buffer
/// contract as `AudioEngineCapturer`.
///
/// The fixture is read in the file's processing format (float32, deinterleaved)
/// and yielded in production-sized chunks. `BilingualSpeechEngine` still runs
/// its normal `BufferConverter` step, so the rest of the pipeline is unchanged.
/// Release builds compile this type out.
actor FixtureAudioCapturer: AudioCapturing {
    enum Pacing: String, Sendable {
        /// Pace buffers against the wall clock, matching live microphone input.
        case realtime
        /// Yield as fast as the decoder can read. Useful for ASR-only sweeps;
        /// wall-clock settle windows (silence finalize, translation debounce)
        /// are not preserved.
        case max
    }

    struct Configuration: Sendable {
        var url: URL
        var pacing: Pacing
        var chunkFrames: AVAudioFrameCount = 1024
    }

    struct Stats: Sendable {
        var started: Bool
        var finished: Bool
        var sentFrames: AVAudioFramePosition
        var sampleRate: Double
        var channels: AVAudioChannelCount
        var formatDescription: String
    }

    private let configuration: Configuration
    private var readTask: Task<Void, Never>?
    private var continuation: AsyncStream<SendablePCMBuffer>.Continuation?
    private var started = false
    private var finishedNaturally = false
    private var sentFrames: AVAudioFramePosition = 0
    private var sampleRate: Double = 0
    private var channels: AVAudioChannelCount = 0
    private var formatDescription = "not-started"

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func start() async throws -> AsyncStream<SendablePCMBuffer> {
        await stop()

        let file = try AVAudioFile(forReading: configuration.url)
        let format = file.processingFormat
        sampleRate = format.sampleRate
        channels = format.channelCount
        formatDescription = "\(format.channelCount)ch \(Int(format.sampleRate))Hz \(format.commonFormat)"
        sentFrames = 0
        started = true
        finishedNaturally = false

        let (stream, continuation) = AsyncStream<SendablePCMBuffer>.makeStream()
        self.continuation = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.consumerTerminated() }
        }

        let chunkFrames = configuration.chunkFrames
        let pacing = configuration.pacing
        let totalFrames = file.length
        DuiyiLog.audio.info(
            "Fixture audio start \(self.configuration.url.lastPathComponent, privacy: .public) format=\(self.formatDescription, privacy: .public) frames=\(totalFrames, privacy: .public) pacing=\(pacing.rawValue, privacy: .public)"
        )

        readTask = Task { [weak self] in
            await self?.readLoop(
                file: file,
                format: format,
                totalFrames: totalFrames,
                chunkFrames: chunkFrames,
                pacing: pacing,
                continuation: continuation
            )
        }
        return stream
    }

    func stop() async {
        readTask?.cancel()
        readTask = nil
        started = false
        continuation?.finish()
        continuation = nil
    }

    func stats() -> Stats {
        Stats(
            started: started,
            finished: finishedNaturally,
            sentFrames: sentFrames,
            sampleRate: sampleRate,
            channels: channels,
            formatDescription: formatDescription
        )
    }

    private func consumerTerminated() async {
        readTask?.cancel()
        readTask = nil
    }

    private func readLoop(
        file: AVAudioFile,
        format: AVAudioFormat,
        totalFrames: AVAudioFramePosition,
        chunkFrames: AVAudioFrameCount,
        pacing: Pacing,
        continuation: AsyncStream<SendablePCMBuffer>.Continuation
    ) async {
        let clock = ContinuousClock()
        let startedAt = clock.now
        var framesSent: AVAudioFramePosition = 0

        while !Task.isCancelled, file.framePosition < totalFrames {
            let remaining = totalFrames - file.framePosition
            let frameCount = AVAudioFrameCount(min(Int64(chunkFrames), remaining))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                DuiyiLog.audio.error("Fixture audio buffer allocation failed")
                break
            }
            do {
                try file.read(into: buffer, frameCount: frameCount)
            } catch {
                DuiyiLog.audio.error(
                    "Fixture audio read failed at frame \(file.framePosition, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                break
            }
            guard buffer.frameLength > 0 else { break }
            continuation.yield(SendablePCMBuffer(buffer: buffer))
            framesSent += AVAudioFramePosition(buffer.frameLength)
            sentFrames = framesSent

            guard pacing == .realtime, format.sampleRate > 0 else { continue }
            let audioSeconds = Double(framesSent) / format.sampleRate
            let deadline = startedAt + .seconds(audioSeconds)
            try? await Task.sleep(
                until: deadline,
                tolerance: .milliseconds(2),
                clock: .continuous
            )
        }

        guard !Task.isCancelled else { return }
        finishedNaturally = true
        continuation.finish()
        DuiyiLog.audio.info(
            "Fixture audio finished frames=\(framesSent, privacy: .public) duration=\(Double(framesSent) / max(format.sampleRate, 1), privacy: .public)s"
        )
    }
}
#endif
