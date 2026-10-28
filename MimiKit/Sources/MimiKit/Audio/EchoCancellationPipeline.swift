import AVFAudio
import Synchronization

/// Removes the echo of the system audio from the microphone audio, so that what the microphone picks up from the
/// speakers or earphones is not taken for the user's speech.
///
/// Both streams are converted to mono at ``sampleRate`` and placed on one timeline by their host times. Each 10 ms
/// microphone frame is processed with the system audio from ``referenceLead`` later: the system audio can be
/// timestamped after the microphone picks it up (by about 20 ms through wired earphones), and echo is only removed
/// when it follows its reference.
///
/// Microphone audio is never dropped. A frame whose reference has not arrived within ``referenceWaitLimit``, such as
/// while nothing is playing and no system audio is delivered, is processed without the missing reference.
final class EchoCancellationPipeline: Sendable {
    static let sampleRate = 16000
    static let referenceLead: TimeInterval = 0.06
    static let referenceWaitLimit: TimeInterval = 0.2
    /// A buffer placed further than this from where its stream continues starts a new run of that stream.
    static let continuityTolerance = AnalyzerTimeline.continuityTolerance
    /// Differences beyond this between where the reference continues and where its host time places it are clock
    /// drift between the devices, corrected by moving the reference. Smaller ones are timestamp jitter.
    static let driftTolerance: TimeInterval = 0.002
    /// How much reference is kept while no microphone audio is waiting for it.
    static let idleReferenceRetention: TimeInterval = 1

    static let frameLength = sampleRate / 100

    private static func frames(_ duration: TimeInterval) -> Int {
        Int((duration * Double(sampleRate)).rounded())
    }

    /// Processed microphone audio whose first sample was captured at `hostTime`.
    private struct Segment {
        var hostTime: UInt64
        var samples: [Float]
    }

    private struct State {
        let canceller: any EchoCanceller
        let format: AVAudioFormat
        var hasFailed = false
        /// Relates timeline positions, in samples, to host time. Follows the microphone, so that the microphone
        /// audio stays contiguous and only the reference moves when the clocks of the devices drift apart.
        var anchor: (position: Double, hostSeconds: Double)?

        /// `nil` while no run of microphone audio is in progress.
        var captureConverter: AudioStreamConverter?
        var hasCaptured = false
        /// Where the next microphone buffer goes, counted in the samples supplied to the converter. Positions of
        /// buffers are tracked by their input because the converter delivers its output in irregular chunks.
        var captureInputPosition: Double = 0
        /// Microphone samples not processed yet. The first one is at `captureStart`.
        var captureSamples: [Float] = []
        var captureStart = 0

        /// `nil` while no run of system audio is in progress.
        var referenceConverter: AudioStreamConverter?
        /// Where the host time of the next system audio buffer is expected to place it, counted in the samples
        /// supplied to the converter.
        var expectedReferencePosition: Double = 0
        /// The first one is at `referenceStart`.
        var referenceSamples: [Float] = []
        var referenceStart = 0

        var captureEnd: Int { captureStart + captureSamples.count }
        var referenceEnd: Int { referenceStart + referenceSamples.count }

        mutating func position(at hostSeconds: Double) -> Double {
            guard let anchor else {
                anchor = (0, hostSeconds)
                return 0
            }
            return anchor.position + (hostSeconds - anchor.hostSeconds) * Double(sampleRate)
        }

        func hostTime(at position: Int) -> UInt64 {
            let anchor = anchor ?? (0, 0)
            return AVAudioTime.hostTime(forSeconds: anchor.hostSeconds + (Double(position) - anchor.position) / Double(sampleRate))
        }
    }

    private let state: Mutex<State>
    private let onOutput: AudioBufferHandler
    private let onFailure: @Sendable (any Error) -> Void

    /// `onOutput` receives the microphone audio with the echo removed, in order, on the thread that appended the
    /// audio completing it. `onFailure` is called once if processing fails; later audio is ignored.
    init(
        canceller: sending any EchoCanceller,
        onOutput: @escaping AudioBufferHandler,
        onFailure: @escaping @Sendable (any Error) -> Void
    ) {
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(Self.sampleRate), channels: 1)!
        state = Mutex(State(canceller: canceller, format: format))
        self.onOutput = onOutput
        self.onFailure = onFailure
    }

    /// Appends system audio, the reference for the echo. Safe to call from any thread.
    func appendReference(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        perform { state in
            let expected = state.position(at: AVAudioTime.seconds(forHostTime: hostTime))
            let deviation = expected - state.expectedReferencePosition
            if let converter = state.referenceConverter, converter.inputFormat == buffer.format,
               abs(deviation) <= Double(Self.frames(Self.continuityTolerance)) {
                if abs(deviation) > Double(Self.frames(Self.driftTolerance)) {
                    Self.moveReferenceEnd(of: &state, to: state.referenceEnd + Int(deviation.rounded()))
                } else {
                    // Keeps following the samples, not the jitter of the timestamps.
                    state.expectedReferencePosition -= deviation
                }
            } else {
                if let remaining = try state.referenceConverter?.drain() {
                    Self.append(remaining, to: &state.referenceSamples)
                }
                state.referenceConverter = try AudioStreamConverter(from: buffer.format, to: state.format)
                Self.moveReferenceEnd(of: &state, to: Int(expected.rounded()))
            }
            state.expectedReferencePosition += deviation + Double(buffer.frameLength) * Double(Self.sampleRate) / buffer.format.sampleRate
            if let converted = try state.referenceConverter?.convert(buffer) {
                Self.append(converted, to: &state.referenceSamples)
            }
            return try [Self.processFrames(of: &state, flushing: false)]
        }
    }

    /// Appends microphone audio. Safe to call from any thread.
    func appendCapture(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        perform { state in
            let hostSeconds = AVAudioTime.seconds(forHostTime: hostTime)
            let expected = state.position(at: hostSeconds)
            var segments: [Segment] = []
            if state.captureConverter?.inputFormat != buffer.format
                || abs(expected - state.captureInputPosition) > Double(Self.frames(Self.continuityTolerance)) {
                segments.append(try Self.endCaptureRun(of: &state))
                // A new run never overlaps audio already delivered. Moving it moves the whole timeline relative
                // to host time, so the reference placed so far moves with it.
                let placed = Int(expected.rounded())
                state.captureStart = state.hasCaptured ? max(placed, state.captureEnd) : placed
                let shift = state.captureStart - placed
                state.referenceStart += shift
                state.expectedReferencePosition += Double(shift)
                state.captureInputPosition = Double(state.captureStart)
                state.captureConverter = try AudioStreamConverter(from: buffer.format, to: state.format)
                state.hasCaptured = true
            }
            state.anchor = (state.captureInputPosition, hostSeconds)
            state.captureInputPosition += Double(buffer.frameLength) * Double(Self.sampleRate) / buffer.format.sampleRate
            if let converted = try state.captureConverter?.convert(buffer) {
                Self.append(converted, to: &state.captureSamples)
            }
            segments.append(try Self.processFrames(of: &state, flushing: false))
            return segments
        }
    }

    /// Processes all microphone audio appended so far, without waiting for its reference, and ends the run of
    /// microphone audio. Used when the microphone stops, so that its last audio is delivered.
    func flush() {
        perform { state in try [Self.endCaptureRun(of: &state)] }
    }

    /// Runs `body` under the lock and delivers the audio it processed before releasing the lock, keeping the order.
    private func perform(_ body: (inout State) throws -> [Segment]) {
        let failure: (any Error)? = state.withLock { state in
            guard !state.hasFailed else { return nil }
            do {
                for segment in try body(&state) where !segment.samples.isEmpty {
                    let count = segment.samples.count
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: state.format, frameCapacity: AVAudioFrameCount(count)) else {
                        throw AudioConversionError.failed("Could not allocate an output buffer of \(count) frames")
                    }
                    buffer.frameLength = AVAudioFrameCount(count)
                    segment.samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: count) }
                    onOutput(buffer, segment.hostTime)
                }
                return nil
            } catch {
                state.hasFailed = true
                return error
            }
        }
        if let failure {
            onFailure(failure)
        }
    }

    private static func endCaptureRun(of state: inout State) throws -> Segment {
        if let remaining = try state.captureConverter?.drain() {
            append(remaining, to: &state.captureSamples)
        }
        state.captureConverter = nil
        return try processFrames(of: &state, flushing: true)
    }

    /// Makes the reference continue at `position`, filling a gap with silence or dropping the samples it overlaps.
    private static func moveReferenceEnd(of state: inout State, to position: Int) {
        if state.referenceSamples.isEmpty || position <= state.referenceStart {
            state.referenceSamples = []
            state.referenceStart = position
        } else if position > state.referenceEnd {
            state.referenceSamples.append(contentsOf: repeatElement(0, count: position - state.referenceEnd))
        } else {
            state.referenceSamples.removeLast(state.referenceEnd - position)
        }
    }

    /// Processes the microphone frames whose reference has arrived or that waited too long, or all of them when
    /// `flushing`, padding the last one with silence.
    private static func processFrames(of state: inout State, flushing: Bool) throws -> Segment {
        // Timed now, since starting the next run moves the anchor.
        var segment = Segment(hostTime: state.hostTime(at: state.captureStart), samples: [])
        var render = [Float](repeating: 0, count: frameLength)
        var frame = [Float](repeating: 0, count: frameLength)
        while state.captureSamples.count >= frameLength || (flushing && !state.captureSamples.isEmpty) {
            let referenceFrom = state.captureStart + frames(referenceLead)
            let isReferenceComplete = state.referenceEnd >= referenceFrom + frameLength
            let hasWaitedTooLong = state.captureSamples.count >= frameLength + frames(referenceWaitLimit)
            guard isReferenceComplete || hasWaitedTooLong || flushing else { break }

            for index in 0..<frameLength {
                let offset = referenceFrom + index - state.referenceStart
                render[index] = offset >= 0 && offset < state.referenceSamples.count ? state.referenceSamples[offset] : 0
            }
            let count = min(frameLength, state.captureSamples.count)
            for index in 0..<frameLength {
                frame[index] = index < count ? state.captureSamples[index] : 0
            }
            try render.withUnsafeBufferPointer { try state.canceller.analyzeReference($0) }
            try frame.withUnsafeMutableBufferPointer { try state.canceller.removeEcho(from: $0) }
            segment.samples.append(contentsOf: frame[0..<count])
            state.captureSamples.removeFirst(count)
            state.captureStart += count
        }
        trimReference(of: &state)
        return segment
    }

    /// Drops the reference that no microphone frame will be processed with.
    private static func trimReference(of state: inout State) {
        let isCaptureInProgress = state.captureConverter != nil
        let keepFrom = isCaptureInProgress
            ? state.captureStart + frames(referenceLead)
            : state.referenceEnd - frames(idleReferenceRetention)
        let dropCount = min(max(keepFrom - state.referenceStart, 0), state.referenceSamples.count)
        state.referenceSamples.removeFirst(dropCount)
        state.referenceStart += dropCount
    }

    /// Reads the samples while `buffer`, which owns their memory, is kept alive as an argument.
    private static func append(_ buffer: AVAudioPCMBuffer, to samples: inout [Float]) {
        samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
}
