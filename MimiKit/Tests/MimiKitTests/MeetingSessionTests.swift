import AVFAudio
import MimiKit
import Synchronization
import Testing

private struct TestError: Error {}

@MainActor
private final class FakeAudioSource: AudioSource {
    var isAccessGranted = true
    /// Reported once started, as by a source that has no device to capture from.
    var availabilityOnStart: AudioSourceAvailability?
    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var accessRequestCount = 0
    /// When set, access requests are held until ``answerPendingAccessRequest(granted:)``.
    var holdsAccessRequests = false
    private var pendingAccessRequest: CheckedContinuation<Bool, Never>?

    var hasPendingAccessRequest: Bool {
        pendingAccessRequest != nil
    }

    func requestAccess() async -> Bool {
        accessRequestCount += 1
        guard holdsAccessRequests else { return isAccessGranted }
        return await withCheckedContinuation { pendingAccessRequest = $0 }
    }

    func answerPendingAccessRequest(granted: Bool = true) {
        pendingAccessRequest?.resume(returning: granted)
        pendingAccessRequest = nil
    }

    private var onBuffer: AudioBufferHandler?
    private var onAvailabilityChange: (@MainActor (AudioSourceAvailability) -> Void)?

    func start(onBuffer: @escaping AudioBufferHandler, onAvailabilityChange: @escaping @MainActor (AudioSourceAvailability) -> Void) {
        startCount += 1
        isRunning = true
        self.onBuffer = onBuffer
        self.onAvailabilityChange = onAvailabilityChange
        if let availabilityOnStart {
            onAvailabilityChange(availabilityOnStart)
        }
    }

    func stop() async {
        isRunning = false
        onBuffer = nil
        onAvailabilityChange = nil
    }

    /// Delivers captured audio as the running source would.
    func capture(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        onBuffer?(buffer, hostTime)
    }

    /// Simulates capture stopping or resuming as the devices change.
    func report(_ availability: AudioSourceAvailability) {
        onAvailabilityChange?(availability)
    }
}

/// Holds waiters until opened.
private final class Gate: Sendable {
    private let state = Mutex<(isOpen: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { continuation in
            let isOpen = state.withLock { state in
                if !state.isOpen { state.waiters.append(continuation) }
                return state.isOpen
            }
            if isOpen { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }
}

private final class FakeTranscriptionEngine: TranscriptionEngine {
    enum Event: Equatable {
        case append(frames: Int, hostTime: UInt64)
        case finalizePending
    }

    private struct State {
        var continuation: AsyncThrowingStream<TranscriptionResult, any Error>.Continuation?
        var resultsOnFinish: [TranscriptionResult] = []
        var isFinished = false
        var events: [Event] = []
    }

    private let state = Mutex(State())
    private let startError: (any Error)?
    private let startGate: Gate?

    init(startError: (any Error)? = nil, startGate: Gate? = nil) {
        self.startError = startError
        self.startGate = startGate
    }

    var isFinished: Bool {
        state.withLock { $0.isFinished }
    }

    var finalizePendingCount: Int {
        events.filter { $0 == .finalizePending }.count
    }

    var events: [Event] {
        state.withLock { $0.events }
    }

    var appendedFrameCount: Int {
        events.reduce(0) { total, event in
            guard case let .append(frames, _) = event else { return total }
            return total + frames
        }
    }

    func start(timelineOrigin: UInt64) async throws -> AsyncThrowingStream<TranscriptionResult, any Error> {
        await startGate?.wait()
        if let startError { throw startError }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TranscriptionResult.self)
        state.withLock { $0.continuation = continuation }
        return stream
    }

    func append(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        state.withLock { $0.events.append(.append(frames: Int(buffer.frameLength), hostTime: hostTime)) }
    }

    func finalizePending() async {
        state.withLock { $0.events.append(.finalizePending) }
    }

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
    let requestedDirectories = Mutex<[URL]>([])

    init(error: (any Error)? = nil) {
        self.error = error
    }

    var requestCount: Int {
        requestedDirectories.withLock { $0.count }
    }

    func generator(forModelAt directory: URL) async throws -> any TextGenerator {
        requestedDirectories.withLock { $0.append(directory) }
        if let error { throw error }
        return FakeGenerator()
    }
}

@MainActor
private final class FakeSummaryModelLibrary: SummaryModelLibrary {
    var availableModels: Set<SummaryModel> = Set(SummaryModel.all)
    private(set) var useCounts: [SummaryModel: Int] = [:]

    static func directory(of model: SummaryModel) -> URL {
        URL(filePath: "/models/\(model.id)", directoryHint: .isDirectory)
    }

    func beginUsing(_ model: SummaryModel) throws -> URL {
        guard availableModels.contains(model) else { throw TestError() }
        useCounts[model, default: 0] += 1
        return Self.directory(of: model)
    }

    func endUsing(_ model: SummaryModel) {
        useCounts[model, default: 0] -= 1
    }
}

@MainActor
private final class FakeTranscriptionEngineFactory {
    private(set) var engines: [FakeTranscriptionEngine] = []
    /// Indexes of engines, in creation order, whose start throws.
    var failingStartIndexes: Set<Int> = []
    /// Gates that hold the start of engines, by index in creation order.
    var startGates: [Int: Gate] = [:]

    func make() -> any TranscriptionEngine {
        let engine = FakeTranscriptionEngine(
            startError: failingStartIndexes.contains(engines.count) ? TestError() : nil,
            startGate: startGates[engines.count]
        )
        engines.append(engine)
        return engine
    }
}

private final class EchoCancellerFactory: Sendable {
    private struct State {
        var error: (any Error)?
        var processingError: (any Error)?
        var sampleRates: [Int] = []
    }

    private let state = Mutex(State())

    /// Thrown when creating a canceller.
    var error: (any Error)? {
        get { state.withLock { $0.error } }
        set { state.withLock { $0.error = newValue } }
    }

    /// Thrown by the cancellers created when processing audio.
    var processingError: (any Error)? {
        get { state.withLock { $0.processingError } }
        set { state.withLock { $0.processingError = newValue } }
    }

    var sampleRates: [Int] {
        state.withLock { $0.sampleRates }
    }

    func make(sampleRate: Int) throws -> any EchoCanceller {
        let processingError = try state.withLock { state in
            state.sampleRates.append(sampleRate)
            if let error = state.error { throw error }
            return state.processingError
        }
        return RecordingEchoCanceller(error: processingError)
    }
}

@MainActor
private final class Harness {
    let microphone = FakeAudioSource()
    let systemAudio = FakeAudioSource()
    let provider: FakeGeneratorProvider
    let summaryModels = FakeSummaryModelLibrary()
    let session: MeetingSession
    let engineFactory = FakeTranscriptionEngineFactory()
    let echoCancellerFactory = EchoCancellerFactory()

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
            makeEchoCanceller: { [echoCancellerFactory] in try echoCancellerFactory.make(sampleRate: $0) },
            summaryModels: summaryModels,
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
        await harness.session.start(summaryModel: .qwen3_5_4B)
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

    @Test func runningSinceCoversTheRunningSession() async {
        let harness = Harness()
        #expect(harness.session.runningSince == nil)

        let before = Date.now
        await harness.session.start(summaryModel: .qwen3_5_4B)
        let runningSince = harness.session.runningSince
        #expect(runningSince.map { $0 >= before && $0 <= .now } == true)

        await harness.session.stop()
        #expect(harness.session.runningSince == nil)
    }

    @Test func runningSinceStaysUnsetWhenStartFails() async {
        let harness = Harness()
        harness.microphone.isAccessGranted = false
        await harness.session.start(summaryModel: .qwen3_5_4B)
        #expect(harness.session.state == .idle)
        #expect(harness.session.runningSince == nil)
    }

    @Test func concurrentStartsRunOneSession() async {
        let harness = Harness()
        async let first: Void = harness.session.start(summaryModel: .qwen3_5_4B)
        async let second: Void = harness.session.start(summaryModel: .qwen3_5_4B)
        _ = await (first, second)

        #expect(harness.session.state == .running)
        #expect(harness.createdEngines.count == 2)
        #expect(harness.microphone.startCount == 1)
        await harness.session.stop()
    }

    @Test func stopWhileStartingWaitsForStart() async throws {
        let harness = Harness()
        harness.microphone.holdsAccessRequests = true
        let start = Task { await harness.session.start(summaryModel: .qwen3_5_4B) }
        try await waitUntil { harness.microphone.hasPendingAccessRequest }
        #expect(harness.session.state == .starting)

        let stop = Task { await harness.session.stop() }
        harness.microphone.answerPendingAccessRequest()
        await start.value
        await stop.value

        #expect(harness.session.state == .idle)
        #expect(!harness.microphone.isRunning)
        #expect(!harness.systemAudio.isRunning)
    }

    @Test func concurrentStopsReturnOnceIdle() async {
        let harness = Harness()
        await harness.session.start(summaryModel: .qwen3_5_4B)
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
        await harness.session.start(summaryModel: .qwen3_5_4B)

        #expect(harness.session.state == .idle)
        #expect(harness.microphone.startCount == 0)
        guard case .microphoneAccessDenied = harness.session.failure else {
            Issue.record("Unexpected failure: \(String(describing: harness.session.failure))")
            return
        }
    }

    @Test func unavailableSourceAtStartKeepsSessionRunning() async {
        let harness = Harness()
        harness.systemAudio.availabilityOnStart = .unavailable(TestError())
        await harness.session.start(summaryModel: .qwen3_5_4B)

        #expect(harness.session.state == .running)
        #expect(harness.session.failure == nil)
        #expect(harness.session.captureError(of: .others) != nil)
        #expect(harness.session.captureError(of: .me) == nil)
        #expect(harness.microphone.isRunning)

        await harness.session.stop()
        #expect(harness.session.captureError(of: .others) == nil)
    }

    @Test func failureWhileStartingKeepsRootCause() async {
        let harness = Harness()
        // Microphone access is denied, then the system audio's engine fails to start.
        harness.microphone.isAccessGranted = false
        harness.engineFactory.failingStartIndexes = [1]
        await harness.session.start(summaryModel: .qwen3_5_4B)

        #expect(harness.session.state == .idle)
        #expect(harness.createdEngines.map(\.isFinished) == [true, true])
        guard case .microphoneAccessDenied = harness.session.failure else {
            Issue.record("Unexpected failure: \(String(describing: harness.session.failure))")
            return
        }
    }

    @Test func failureWhileStartingSkipsSummary() async {
        let harness = Harness()
        // The system audio's engine fails to start after the microphone started.
        harness.engineFactory.failingStartIndexes = [1]
        await harness.session.start(summaryModel: .qwen3_5_4B)

        #expect(harness.session.state == .idle)
        #expect(!harness.microphone.isRunning)
        #expect(!harness.systemAudio.isRunning)
        #expect(harness.createdEngines.map(\.isFinished) == [true, true])
        #expect(harness.provider.requestCount == 0)
        guard case .transcription = harness.session.failure else {
            Issue.record("Unexpected failure: \(String(describing: harness.session.failure))")
            return
        }
    }

    @Test func transcriptionErrorStopsSession() async throws {
        let harness = Harness()
        await harness.session.start(summaryModel: .qwen3_5_4B)
        harness.createdEngines[1].fail()

        try await waitUntil { harness.session.state == .idle }
        #expect(!harness.microphone.isRunning)
        guard case .transcription = harness.session.failure else {
            Issue.record("Unexpected failure: \(String(describing: harness.session.failure))")
            return
        }
    }

    @Test func systemAudioUnavailableWhileRunningKeepsSessionUntilItResumes() async throws {
        let harness = Harness()
        await harness.session.start(summaryModel: .qwen3_5_4B)
        harness.systemAudio.report(.unavailable(TestError()))

        #expect(harness.session.state == .running)
        #expect(harness.session.captureError(of: .others) != nil)
        #expect(harness.microphone.isRunning)
        // The speech captured before is finalized, as the input pauses.
        try await waitUntil { harness.createdEngines[1].finalizePendingCount == 1 }
        #expect(harness.createdEngines[0].finalizePendingCount == 0)

        harness.systemAudio.report(.available)
        #expect(harness.session.captureError(of: .others) == nil)
        #expect(harness.session.failure == nil)
        await harness.session.stop()
    }

    @Test func microphoneUnavailableDeliversHeldAudioAndFinalizes() async throws {
        let harness = Harness()
        await harness.session.start(summaryModel: .qwen3_5_4B)
        harness.microphone.capture(makeBuffer([Float](repeating: 0.1, count: 1600)), hostTime: hostTime(10))
        #expect(harness.createdEngines[0].events.isEmpty)

        harness.microphone.report(.unavailable(TestError()))
        #expect(harness.session.state == .running)
        #expect(harness.session.captureError(of: .me) != nil)
        #expect(harness.createdEngines[0].appendedFrameCount == 1600)
        try await waitUntil { harness.createdEngines[0].finalizePendingCount == 1 }
        #expect(harness.createdEngines[0].events.last == .finalizePending)

        harness.microphone.report(.available)
        #expect(harness.session.captureError(of: .me) == nil)
        #expect(harness.microphone.isRunning)
        await harness.session.stop()
    }

    @Test func repeatedUnavailabilityFinalizesOnceAndKeepsTheLatestReason() async throws {
        struct FirstReason: Error {}
        struct SecondReason: Error {}
        let harness = Harness()
        await harness.session.start(summaryModel: .qwen3_5_4B)
        harness.microphone.report(.unavailable(FirstReason()))
        harness.systemAudio.report(.unavailable(FirstReason()))
        harness.microphone.report(.unavailable(SecondReason()))
        harness.systemAudio.report(.unavailable(SecondReason()))

        #expect(harness.session.captureError(of: .me) is SecondReason)
        #expect(harness.session.captureError(of: .others) is SecondReason)
        try await waitUntil { harness.createdEngines.map(\.finalizePendingCount) == [1, 1] }
        // Muting runs after any finalization scheduled before it, and finalizes once more itself.
        await harness.session.setMicrophoneMuted(true).value
        #expect(harness.createdEngines[0].finalizePendingCount == 2)
        #expect(harness.createdEngines[1].finalizePendingCount == 1)

        // Becoming unavailable again after resuming is another pause.
        harness.systemAudio.report(.available)
        harness.systemAudio.report(.unavailable(FirstReason()))
        try await waitUntil { harness.createdEngines[1].finalizePendingCount == 2 }
        await harness.session.stop()
    }

    @Test func mutingClearsMicrophoneCaptureError() async {
        let harness = Harness()
        await harness.session.start(summaryModel: .qwen3_5_4B)
        harness.microphone.report(.unavailable(TestError()))
        #expect(harness.session.captureError(of: .me) != nil)

        await harness.session.setMicrophoneMuted(true).value
        #expect(harness.session.captureError(of: .me) == nil)

        await harness.session.setMicrophoneMuted(false).value
        #expect(harness.session.captureError(of: .me) == nil)
        #expect(harness.microphone.isRunning)
        await harness.session.stop()
    }

    @Test func mutingStopsMicrophoneAndFinalizesItsSpeech() async {
        let harness = Harness()
        await harness.session.start(summaryModel: .qwen3_5_4B)

        await harness.session.setMicrophoneMuted(true).value
        #expect(harness.session.isMicrophoneMuted)
        #expect(!harness.microphone.isRunning)
        #expect(harness.systemAudio.isRunning)
        #expect(harness.createdEngines.map(\.finalizePendingCount) == [1, 0])
        #expect(harness.session.state == .running)

        await harness.session.setMicrophoneMuted(false).value
        #expect(harness.microphone.isRunning)
        #expect(harness.microphone.startCount == 2)
        #expect(harness.createdEngines.count == 2)
        await harness.session.stop()
    }

    @Test func mutingTwiceIsIdempotent() async {
        let harness = Harness()
        await harness.session.start(summaryModel: .qwen3_5_4B)
        await harness.session.setMicrophoneMuted(true).value
        await harness.session.setMicrophoneMuted(true).value
        #expect(harness.createdEngines[0].finalizePendingCount == 1)

        await harness.session.setMicrophoneMuted(false).value
        await harness.session.setMicrophoneMuted(false).value
        #expect(harness.microphone.startCount == 2)
        await harness.session.stop()
    }

    @Test func rapidTogglesFollowTheLastCall() async {
        let harness = Harness()
        await harness.session.start(summaryModel: .qwen3_5_4B)

        harness.session.setMicrophoneMuted(true)
        harness.session.setMicrophoneMuted(false)
        harness.session.setMicrophoneMuted(true)
        await harness.session.setMicrophoneMuted(false).value

        #expect(!harness.session.isMicrophoneMuted)
        #expect(harness.microphone.isRunning)
        await harness.session.stop()
    }

    @Test func muteCarriesOverToLaterSessionsWithoutRequestingAccess() async {
        let harness = Harness()
        harness.microphone.isAccessGranted = false
        await harness.session.setMicrophoneMuted(true).value
        await harness.session.start(summaryModel: .qwen3_5_4B)
        #expect(harness.session.state == .running)
        #expect(harness.session.failure == nil)
        #expect(harness.microphone.accessRequestCount == 0)
        #expect(harness.microphone.startCount == 0)
        #expect(harness.systemAudio.isRunning)

        await harness.session.stop()
        await harness.session.start(summaryModel: .qwen3_5_4B)
        #expect(harness.microphone.startCount == 0)
        await harness.session.stop()
    }

    @Test func unmutingRequestsAccess() async throws {
        let harness = Harness()
        harness.microphone.isAccessGranted = false
        await harness.session.setMicrophoneMuted(true).value
        await harness.session.start(summaryModel: .qwen3_5_4B)

        await harness.session.setMicrophoneMuted(false).value
        #expect(harness.microphone.accessRequestCount == 1)
        try await waitUntil { harness.session.state == .idle }
        guard case .microphoneAccessDenied = harness.session.failure else {
            Issue.record("Unexpected failure: \(String(describing: harness.session.failure))")
            return
        }
    }

    @Test func mutingWhileStartingStopsRunningMicrophoneImmediately() async throws {
        let harness = Harness()
        let systemAudioEngineStart = Gate()
        harness.engineFactory.startGates[1] = systemAudioEngineStart
        let start = Task { await harness.session.start(summaryModel: .qwen3_5_4B) }
        try await waitUntil { harness.microphone.isRunning }

        await harness.session.setMicrophoneMuted(true).value
        #expect(harness.session.state == .starting)
        #expect(!harness.microphone.isRunning)

        systemAudioEngineStart.open()
        await start.value
        #expect(harness.session.state == .running)
        #expect(!harness.microphone.isRunning)
        #expect(harness.systemAudio.isRunning)
        await harness.session.stop()
    }

    @Test func mutingWhileAccessIsRequestedKeepsMicrophoneOff() async throws {
        let harness = Harness()
        harness.microphone.holdsAccessRequests = true
        let start = Task { await harness.session.start(summaryModel: .qwen3_5_4B) }
        try await waitUntil { harness.microphone.hasPendingAccessRequest }

        harness.session.setMicrophoneMuted(true)
        harness.microphone.answerPendingAccessRequest()
        await start.value

        #expect(harness.session.state == .running)
        #expect(harness.microphone.startCount == 0)
        #expect(harness.systemAudio.isRunning)
        await harness.session.stop()
    }

    @Test func accessRequestFromPreviousSessionDoesNotAffectNextSession() async throws {
        let harness = Harness()
        await harness.session.setMicrophoneMuted(true).value
        await harness.session.start(summaryModel: .qwen3_5_4B)

        // Unmuting asks for access, and the session stops while the request is pending.
        harness.microphone.holdsAccessRequests = true
        harness.session.setMicrophoneMuted(false)
        try await waitUntil { harness.microphone.hasPendingAccessRequest }
        await harness.session.stop()

        // The next session waits for the pending request; denying it must not fail the next session.
        let start = Task { await harness.session.start(summaryModel: .qwen3_5_4B) }
        try await waitUntil { harness.session.state == .starting }
        harness.microphone.holdsAccessRequests = false
        harness.microphone.answerPendingAccessRequest(granted: false)
        await start.value

        #expect(harness.session.state == .running)
        #expect(harness.session.failure == nil)
        #expect(harness.microphone.isRunning)
        #expect(harness.microphone.startCount == 1)
        await harness.session.stop()
    }

    @Test func microphoneUnavailableAfterUnmuteKeepsSession() async {
        let harness = Harness()
        await harness.session.start(summaryModel: .qwen3_5_4B)
        await harness.session.setMicrophoneMuted(true).value

        harness.microphone.availabilityOnStart = .unavailable(TestError())
        await harness.session.setMicrophoneMuted(false).value

        #expect(harness.session.state == .running)
        #expect(harness.session.failure == nil)
        #expect(harness.session.captureError(of: .me) != nil)
        #expect(harness.systemAudio.isRunning)
        await harness.session.stop()
        #expect(harness.session.captureError(of: .me) == nil)
    }

    @Test func resultsAreAttributedToTheirSpeakers() async throws {
        let harness = Harness()
        await harness.session.start(summaryModel: .qwen3_5_4B)
        harness.createdEngines[0].emit(result("自分の発言", 0))
        harness.createdEngines[1].emit(result("相手の発言", 1))

        try await waitUntil { harness.session.transcript.lines.count == 2 }
        #expect(harness.session.transcript.lines.map(\.speaker) == [.me, .others])
        await harness.session.stop()
    }

    @Test func stopAppliesResultsDeliveredWhileFinishing() async {
        let harness = Harness()
        await harness.session.start(summaryModel: .qwen3_5_4B)
        harness.createdEngines[0].deliverOnFinish(result("最後の発言", 0))

        await harness.session.stop()
        #expect(harness.session.transcript.lines.map(\.text) == ["最後の発言"])
    }

    @Test func summarizesCurrentTopic() async throws {
        let harness = Harness(summaryInterval: .milliseconds(10))
        await harness.session.start(summaryModel: .qwen3_5_4B)
        harness.createdEngines[1].emit(result("議題は予算です", 0))

        try await waitUntil { !harness.session.currentTopic.isEmpty }
        #expect(harness.session.currentTopic == "話題の要約")
        await harness.session.stop()
        #expect(harness.session.summaryActivity == .idle)
    }

    @Test func summarizesSpeechInProgress() async throws {
        let harness = Harness(summaryInterval: .milliseconds(10))
        await harness.session.start(summaryModel: .qwen3_5_4B)
        harness.createdEngines[1].emit(result("議題は予算で", 0, final: false))

        try await waitUntil { !harness.session.currentTopic.isEmpty }
        #expect(harness.session.currentTopic == "話題の要約")
        await harness.session.stop()
    }

    @Test func modelLoadingFailureKeepsTranscribing() async throws {
        let harness = Harness(provider: FakeGeneratorProvider(error: TestError()))
        await harness.session.start(summaryModel: .qwen3_5_4B)

        try await waitUntil { harness.session.summaryFailure != nil }
        #expect(harness.session.state == .running)
        guard case .modelLoading = harness.session.summaryFailure else {
            Issue.record("Unexpected failure: \(String(describing: harness.session.summaryFailure))")
            return
        }
        await harness.session.stop()
    }

    @Test func summaryModelIsInUseUntilStopped() async throws {
        let harness = Harness(summaryInterval: .milliseconds(10))
        await harness.session.start(summaryModel: .qwen3_5_9B)
        #expect(harness.summaryModels.useCounts[.qwen3_5_9B] == 1)

        try await waitUntil { harness.provider.requestCount == 1 }
        #expect(harness.provider.requestedDirectories.withLock { $0 } == [FakeSummaryModelLibrary.directory(of: .qwen3_5_9B)])

        await harness.session.stop()
        #expect(harness.summaryModels.useCounts[.qwen3_5_9B] == 0)
    }

    @Test func summaryModelIsReleasedWhenStartFails() async {
        let harness = Harness()
        harness.engineFactory.failingStartIndexes = [1]
        await harness.session.start(summaryModel: .qwen3_5_4B)

        #expect(harness.session.state == .idle)
        #expect(harness.summaryModels.useCounts[.qwen3_5_4B] == 0)
    }

    @Test func summaryModelIsReleasedWhenSessionStopsUnexpectedly() async throws {
        let harness = Harness()
        await harness.session.start(summaryModel: .qwen3_5_4B)
        harness.createdEngines[1].fail()

        try await waitUntil { harness.session.state == .idle }
        #expect(harness.summaryModels.useCounts[.qwen3_5_4B] == 0)
    }

    @Test func unavailableSummaryModelKeepsTranscribing() async {
        let harness = Harness()
        harness.summaryModels.availableModels = []
        await harness.session.start(summaryModel: .qwen3_5_4B)

        #expect(harness.session.state == .running)
        #expect(harness.session.summaryActivity == .idle)
        #expect(harness.provider.requestCount == 0)
        guard case .modelLoading = harness.session.summaryFailure else {
            Issue.record("Unexpected failure: \(String(describing: harness.session.summaryFailure))")
            return
        }

        await harness.session.stop()
        #expect(harness.summaryModels.useCounts[.qwen3_5_4B] == nil)
    }

    @Test func restartClearsPreviousSession() async throws {
        let harness = Harness()
        // Engines are counted across sessions, so only the first session's system audio engine fails.
        harness.engineFactory.failingStartIndexes = [1]
        await harness.session.start(summaryModel: .qwen3_5_4B)
        #expect(harness.session.failure != nil)

        await harness.session.start(summaryModel: .qwen3_5_4B)
        #expect(harness.session.state == .running)
        #expect(harness.session.failure == nil)
        #expect(harness.session.transcript.lines.isEmpty)
        await harness.session.stop()
    }

    @Test func microphoneAudioReachesItsEngineThroughEchoCancellation() async {
        let harness = Harness()
        await harness.session.start(summaryModel: .qwen3_5_4B)
        #expect(harness.echoCancellerFactory.sampleRates == [16000])

        harness.microphone.capture(makeBuffer([Float](repeating: 0.1, count: 1600)), hostTime: hostTime(10))
        harness.systemAudio.capture(makeBuffer([Float](repeating: 0.2, count: 512), sampleRate: 48000), hostTime: hostTime(10))
        // The system audio is transcribed as captured.
        #expect(harness.createdEngines[1].events == [.append(frames: 512, hostTime: hostTime(10))])

        await harness.session.stop()
        // The microphone audio held for its reference is delivered before the engine finishes, from where it was captured.
        #expect(harness.createdEngines[0].appendedFrameCount == 1600)
        guard case let .append(_, firstHostTime) = harness.createdEngines[0].events.first else {
            Issue.record("No microphone audio was appended")
            return
        }
        #expect(abs(AVAudioTime.seconds(forHostTime: firstHostTime) - 10) < 0.001)
    }

    @Test func mutingDeliversHeldMicrophoneAudioBeforeFinalizing() async {
        let harness = Harness()
        await harness.session.start(summaryModel: .qwen3_5_4B)
        harness.microphone.capture(makeBuffer([Float](repeating: 0.1, count: 1600)), hostTime: hostTime(10))
        #expect(harness.createdEngines[0].events.isEmpty)

        await harness.session.setMicrophoneMuted(true).value
        let events = harness.createdEngines[0].events
        #expect(events.last == .finalizePending)
        #expect(harness.createdEngines[0].appendedFrameCount == 1600)
        await harness.session.stop()
    }

    @Test func echoCancellationFailureStopsOnlyTheMicrophone() async throws {
        let harness = Harness()
        harness.echoCancellerFactory.processingError = TestError()
        await harness.session.start(summaryModel: .qwen3_5_4B)
        harness.microphone.capture(makeBuffer([Float](repeating: 0.1, count: 8000)), hostTime: hostTime(10))

        try await waitUntil { !harness.microphone.isRunning }
        #expect(harness.session.state == .running)
        #expect(harness.session.failure == nil)
        #expect(harness.session.captureError(of: .me) != nil)
        #expect(harness.systemAudio.isRunning)
        try await waitUntil { harness.createdEngines[0].finalizePendingCount == 1 }

        // Muted audio is not expected to be captured, so there is nothing to report.
        await harness.session.setMicrophoneMuted(true).value
        #expect(harness.session.captureError(of: .me) == nil)

        // The microphone stays off for the rest of the session.
        await harness.session.setMicrophoneMuted(false).value
        #expect(!harness.microphone.isRunning)
        #expect(harness.microphone.startCount == 1)
        #expect(harness.session.captureError(of: .me) != nil)

        await harness.session.stop()
        #expect(harness.session.captureError(of: .me) == nil)
    }

    @Test func echoCancellerCreationFailureRunsWithoutMicrophone() async {
        let harness = Harness()
        harness.echoCancellerFactory.error = TestError()
        await harness.session.start(summaryModel: .qwen3_5_4B)

        #expect(harness.session.state == .running)
        #expect(harness.session.failure == nil)
        #expect(harness.session.captureError(of: .me) != nil)
        #expect(harness.microphone.startCount == 0)
        #expect(harness.systemAudio.isRunning)

        await harness.session.stop()
        #expect(harness.createdEngines.map(\.isFinished) == [true, true])
    }
}
