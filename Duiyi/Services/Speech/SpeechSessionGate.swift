import Foundation

/// A stream identity handed back by `SpeechSessionGate.start`. The owner and
/// monotonically increasing generation make stale `stop` calls and superseded
/// stream endings distinguishable from a real engine failure.
struct SpeechSessionHandle: Sendable {
    let owner: FeatureID
    let generation: UInt64
    let stream: AsyncStream<Utterance>
}

extension SpeechSessionHandle: Equatable {
    /// Identity is owner + generation; the stream itself is not comparable.
    static func == (lhs: SpeechSessionHandle, rhs: SpeechSessionHandle) -> Bool {
        lhs.owner == rhs.owner && lhs.generation == rhs.generation
    }
}

/// The gate seam consumed by `TaskLifecycle`. Declaring it as a protocol keeps
/// the lifecycle testable with a fake arbiter while the app injects the real
/// `SpeechSessionGate` in the composition root.
protocol SpeechSessionGating: Sendable {
    func start(
        owner: FeatureID,
        languages: [AppLanguage],
        fallbackLanguage: AppLanguage,
        style: SpeechRecognitionStyle
    ) async throws -> SpeechSessionHandle
    func stop(_ handle: SpeechSessionHandle) async
    func isCurrent(_ handle: SpeechSessionHandle) async -> Bool
}

/// Single entry point for the app's one shared speech engine.
///
/// The gate arbitrates which module owns the sole listening stream. A new
/// `start` immediately supersedes the previous owner: the old stream ends and
/// the old owner's later `stop` becomes a no-op. It does not own task or
/// `SessionState`; callers classify a stream end by asking `isCurrent(_:)`:
/// a still-current handle ended unexpectedly (`recognitionInterrupted`),
/// while a superseded handle ended silently.
actor SpeechSessionGate: SpeechSessionGating {
    private let engine: any SpeechRecognizing
    private var generation: UInt64 = 0
    private var current: SessionIdentity?
    private var isOperating = false
    private var pendingOperations: [CheckedContinuation<Void, Never>] = []

    private struct SessionIdentity {
        let owner: FeatureID
        let generation: UInt64
    }

    init(engine: any SpeechRecognizing) {
        self.engine = engine
    }

    func start(
        owner: FeatureID,
        languages: [AppLanguage],
        fallbackLanguage: AppLanguage,
        style: SpeechRecognitionStyle
    ) async throws -> SpeechSessionHandle {
        await acquireOperationSlot()
        defer { releaseOperationSlot() }

        generation &+= 1
        let startGeneration = generation
        let previous = current
        // Invalidate the old owner before any suspension so its stale stop and
        // stream-end checks become no-ops immediately.
        current = nil
        if previous != nil {
            await engine.stop()
        }

        let stream = try await engine.start(
            languages: languages,
            fallbackLanguage: fallbackLanguage,
            style: style
        )
        current = SessionIdentity(owner: owner, generation: startGeneration)
        return SpeechSessionHandle(
            owner: owner,
            generation: startGeneration,
            stream: stream
        )
    }

    func stop(_ handle: SpeechSessionHandle) async {
        await acquireOperationSlot()
        defer { releaseOperationSlot() }

        guard let current,
              current.owner == handle.owner,
              current.generation == handle.generation else {
            return
        }
        self.current = nil
        await engine.stop()
    }

    func isCurrent(_ handle: SpeechSessionHandle) async -> Bool {
        guard let current else { return false }
        return current.owner == handle.owner && current.generation == handle.generation
    }

    /// Serializes start/stop across suspension points so engine teardown and
    /// startup cannot interleave. Actor isolation alone is not enough because
    /// every engine call suspends.
    private func acquireOperationSlot() async {
        if !isOperating {
            isOperating = true
            return
        }
        await withCheckedContinuation { continuation in
            pendingOperations.append(continuation)
        }
    }

    private func releaseOperationSlot() {
        if pendingOperations.isEmpty {
            isOperating = false
        } else {
            pendingOperations.removeFirst().resume()
        }
    }
}
