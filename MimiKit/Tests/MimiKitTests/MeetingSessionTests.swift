import AVFAudio
import MimiKit
import Synchronization
import Testing

private struct TestError: Error {}

@MainActor
private final class FakeAudioSource: AudioSource {
    var isAccessGranted = true
    var startError: (any Error)?
    private(set) var isRunning = false
    private(set) var startCount = 0
    /// When set, access requests are held until ``grantPendingAccess()``.
    var holdsAccessRequests = false
    private var pendingAccessRequest: CheckedContinuation<Void, Never>?

    var hasPendingAccessRequest: Bool {
        pendingAccessRequest != nil
    }

    func requestAccess() async -> Bool {
        if holdsAccessRequests {
            await withCheckedContinuation { pendingAccessRequest = $0 }
        }
        return isAccessGranted
    }

    func grantPendingAccess() {
        pendingAccessRequest?.resume()
        pendingAccessRequest = nil
    }

    private var onFailure: ((any Error) -> Void)?

    /// Called once the source has started.
    var onStart: () -> Void = {}

    func start(onBuffer: @escaping AudioBufferHandler, onFailure: @escaping (any Error) -> Void) throws {
        startCount += 1
        if let startError { throw startError }
        isRunning = true
        self.onFailure = onFailure
        onStart()
    }

    func stop() {
        isRunning = false
        onFailure = nil
    }

    /// Simulates capture stopping unexpectedly, e.g. when the device cannot be resumed after a change.
    func fail() {
        let onFailure = onFailure
        stop()
        onFailure?(TestError())
    }
}

private final class FakeTranscriptionEngine: TranscriptionEngine {
    private struct State {
        var continuation: AsyncThrowingStream<TranscriptionResult, any Error>.Continuation?
        var resultsOnFinish: [TranscriptionResult] = []
        var isFinished = false
    }

    private let state = Mutex(State())
    private let startError: (any Error)?

    init(startError: (any Error)? = nil) {
        self.startError = startError
    }

    var isFinished: Bool {
        state.withLock { $0.isFinished }
    }

    func start(timelineOrigin: UInt64) async throws -> AsyncThrowingStream<TranscriptionResult, any Error> {
        if let startError { throw startError }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TranscriptionResult.self)
        state.withLock { $0.continuation = continuation }
        return stream
    }

    func append(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {}

    func finish() async {
        state.withLock { state in
            for result in state.resultsOnFinish {
                state.continuation?.yield(result)
            }
            state.continuation?.finish()
            state.isFinished = true
        }
    }

    func emit(_ result: TranscriptionResult) {
        state.withLock { _ = $0.continuation?.yield(result) }
    }

    func fail() {
        state.withLock { $0.continuation?.finish(throwing: TestError()) }
    }

    /// Results delivered when the engine is finished, like the analyzer finalizing pending audio.
    func deliverOnFinish(_ result: TranscriptionResult) {
        state.withLock { $0.resultsOnFinish.append(result) }
    }
}

private struct FakeGenerator: TextGenerator {
    func generate(instructions: String, prompt: String) async throws -> String {
        "話題の要約"
    }
}

private final class FakeGeneratorProvider: TextGeneratorProvider {
    let error: (any Error)?
    let requestCount = Mutex(0)

    init(error: (any Error)? = nil) {
        self.error = error
    }

    func generator(for modelID: String, progressHandler: @Sendable @escaping (Double) -> Void) async throws -> any TextGenerator {
        requestCount.withLock { $0 += 1 }
        if let error { throw error }
        progressHandler(1)
        return FakeGenerator()
    }
}

@MainActor
private final class FakeTranscriptionEngineFactory {
    private(set) var engines: [FakeTranscriptionEngine] = []
    /// Indexes of engines, in creation order, whose start throws.
    var failingStartIndexes: Set<Int> = []

    func make() -> any TranscriptionEngine {
        let engine = FakeTranscriptionEngine(startError: failingStartIndexes.contains(engines.count) ? TestError() : nil)
        engines.append(engine)
        return engine
    }
}

@MainActor
private final class Harness {
    let microphone = FakeAudioSource()
    let systemAudio = FakeAudioSource()
    let provider: FakeGeneratorProvider
    let session: MeetingSession
    let engineFactory = FakeTranscriptionEngineFactory()

    /// Engines in creation order: the microphone's first, then the system audio's.
    var createdEngines: [FakeTranscriptionEngine] {
        engineFactory.engines
    }

    init(provider: FakeGeneratorProvider = FakeGeneratorProvider(), summaryInterval: Duration = .seconds(3600)) {
        self.provider = provider
        session = MeetingSession(
            microphone: microphone,
            systemAudio: systemAudio,
            makeTranscriptionEngine: { [engineFactory] in engineFactory.make() },
            textGeneratorProvider: provider,
            summaryInterval: summaryInterval
        )
    }
}

private func result(_ text: String, _ start: Double, final isFinal: Bool = true) -> TranscriptionResult {
    TranscriptionResult(text: text, start: start, end: start + 1, isFinal: isFinal)
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for condition")
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
struct MeetingSessionTests {
    @Test func startsAndStops() async {
        let harness = Harness()
        await harness.session.start(summaryModelID: "model")
        #expect(harness.session.state == .running)
        #expect(harness.microphone.isRunning)
        #expect(harness.systemAudio.isRunning)
        #expect(harness.createdEngines.count == 2)

        await harness.session.stop()
        #expect(harness.session.state == .idle)
        #expect(!harness.microphone.isRunning)
        #expect(!harness.systemAudio.isRunning)
        #expect(harness.createdEngines.map(\.isFinished) == [true, true])
        #expect(harness.session.failure == nil)
    }

    @Test func concurrentStartsRunOneSession() async {
        let harness = Harness()
        async let first: Void = harness.session.start(summaryModelID: "model")
        async let second: Void = harness.session.start(summaryModelID: "model")
        _ = await (first, second)

        #expect(harness.session.state == .running)
        #expect(harness.createdEngines.count == 2)
        #expect(harness.microphone.startCount == 1)
        await harness.session.stop()
    }

    @Test func stopWhileStartingWaitsForStart() async throws {
        let harness = Harness()
        harness.microphone.holdsAccessRequests = true
        let start = Task { await harness.session.start(summaryModelID: "model") }
        try await waitUntil { harness.microphone.hasPendingAccessRequest }
        #expect(harness.session.state == .starting)

        let stop = Task { await harness.session.stop() }
        harness.microphone.grantPendingAccess()
        await start.value
        await stop.value

        #expect(harness.session.state == .idle)
        #expect(!harness.microphone.isRunning)
        #expect(!harness.systemAudio.isRunning)
    }

    @Test func concurrentStopsReturnOnceIdle() async {
        let harness = Harness()
        await harness.session.start(summaryModelID: "model")
        let first = Task { await harness.session.stop() }
        let second = Task {
            await harness.session.stop()
            return harness.session.state
        }
        await first.value
        #expect(await second.value == .idle)
        #expect(harness.session.state == .idle)
    }

    @Test func deniedMicrophoneAccessFailsWithoutCapturing() async {
        let harness = Harness()
        harness.microphone.isAccessGranted = false
        await harness.session.start(summaryModelID: "model")

        #expect(harness.session.state == .idle)
        #expect(harness.microphone.startCount == 0)
        guard case .microphoneAccessDenied = harness.session.failure else {
            Issue.record("Unexpected failure: \(String(describing: harness.session.failure))")
            return
        }
    }

    @Test func captureErrorTearsDownStartedComponents() async {
        let harness = Harness()
        harness.systemAudio.startError = TestError()
        await harness.session.start(summaryModelID: "model")

        #expect(harness.session.state == .idle)
        #expect(!harness.microphone.isRunning)
        #expect(harness.createdEngines.map(\.isFinished) == [true, true])
        guard case .audioCapture = harness.session.failure else {
            Issue.record("Unexpected failure: \(String(describing: harness.session.failure))")
            return
        }
    }

    @Test func failureWhileStartingKeepsRootCause() async {
        let harness = Harness()
        // The microphone fails, then the system audio's engine fails to start.
        harness.microphone.onStart = { harness.microphone.fail() }
        harness.engineFactory.failingStartIndexes = [1]
        await harness.session.start(summaryModelID: "model")

        #expect(harness.session.state == .idle)
        #expect(harness.createdEngines.map(\.isFinished) == [true, true])
        guard case .audioCapture = harness.session.failure else {
            Issue.record("Unexpected failure: \(String(describing: harness.session.failure))")
            return
        }
    }

    @Test func failureWhileStartingSkipsSummary() async {
        let harness = Harness()
        // The microphone fails while the system audio is still starting, which then succeeds.
        harness.microphone.onStart = { harness.microphone.fail() }
        await harness.session.start(summaryModelID: "model")

        #expect(harness.session.state == .idle)
        #expect(!harness.systemAudio.isRunning)
        #expect(harness.createdEngines.map(\.isFinished) == [true, true])
        #expect(harness.provider.requestCount.withLock { $0 } == 0)
        guard case .audioCapture = harness.session.failure else {
            Issue.record("Unexpected failure: \(String(describing: harness.session.failure))")
            return
        }
    }

    @Test func transcriptionErrorStopsSession() async throws {
        let harness = Harness()
        await harness.session.start(summaryModelID: "model")
        harness.createdEngines[1].fail()

        try await waitUntil { harness.session.state == .idle }
        #expect(!harness.microphone.isRunning)
        guard case .transcription = harness.session.failure else {
            Issue.record("Unexpected failure: \(String(describing: harness.session.failure))")
            return
        }
    }

    @Test func captureFailureWhileRunningStopsSession() async throws {
        let harness = Harness()
        await harness.session.start(summaryModelID: "model")
        harness.systemAudio.fail()

        try await waitUntil { harness.session.state == .idle }
        #expect(!harness.microphone.isRunning)
        #expect(harness.createdEngines.map(\.isFinished) == [true, true])
        guard case .audioCapture = harness.session.failure else {
            Issue.record("Unexpected failure: \(String(describing: harness.session.failure))")
            return
        }
    }

    @Test func resultsAreAttributedToTheirSpeakers() async throws {
        let harness = Harness()
        await harness.session.start(summaryModelID: "model")
        harness.createdEngines[0].emit(result("自分の発言", 0))
        harness.createdEngines[1].emit(result("相手の発言", 1))

        try await waitUntil { harness.session.transcript.lines.count == 2 }
        #expect(harness.session.transcript.lines.map(\.speaker) == [.me, .others])
        await harness.session.stop()
    }

    @Test func stopAppliesResultsDeliveredWhileFinishing() async {
        let harness = Harness()
        await harness.session.start(summaryModelID: "model")
        harness.createdEngines[0].deliverOnFinish(result("最後の発言", 0))

        await harness.session.stop()
        #expect(harness.session.transcript.lines.map(\.text) == ["最後の発言"])
    }

    @Test func summarizesCurrentTopic() async throws {
        let harness = Harness(summaryInterval: .milliseconds(10))
        await harness.session.start(summaryModelID: "model")
        harness.createdEngines[1].emit(result("議題は予算です", 0))

        try await waitUntil { !harness.session.currentTopic.isEmpty }
        #expect(harness.session.currentTopic == "話題の要約")
        #expect(harness.session.lastSummaryDuration != nil)
        await harness.session.stop()
        #expect(harness.session.summaryActivity == .idle)
    }

    @Test func modelLoadingFailureKeepsTranscribing() async throws {
        let harness = Harness(provider: FakeGeneratorProvider(error: TestError()))
        await harness.session.start(summaryModelID: "model")

        try await waitUntil { harness.session.summaryFailure != nil }
        #expect(harness.session.state == .running)
        guard case .modelLoading = harness.session.summaryFailure else {
            Issue.record("Unexpected failure: \(String(describing: harness.session.summaryFailure))")
            return
        }
        await harness.session.stop()
    }

    @Test func restartClearsPreviousSession() async throws {
        let harness = Harness()
        harness.systemAudio.startError = TestError()
        await harness.session.start(summaryModelID: "model")
        #expect(harness.session.failure != nil)

        harness.systemAudio.startError = nil
        await harness.session.start(summaryModelID: "model")
        #expect(harness.session.state == .running)
        #expect(harness.session.failure == nil)
        #expect(harness.session.transcript.lines.isEmpty)
        await harness.session.stop()
    }
}
