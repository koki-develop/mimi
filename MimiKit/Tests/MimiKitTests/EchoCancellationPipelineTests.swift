import AVFAudio
@testable import MimiKit
import Synchronization
import Testing

private struct TestError: Error {}

/// The audio a pipeline delivered.
private final class Output: Sendable {
    private let buffers = Mutex<[(samples: [Float], hostTime: UInt64)]>([])
    private let failures = Mutex(0)

    var deliveries: [(samples: [Float], hostTime: UInt64)] {
        buffers.withLock { $0 }
    }

    var samples: [Float] {
        deliveries.flatMap(\.samples)
    }

    var failureCount: Int {
        failures.withLock { $0 }
    }

    func pipeline(canceller: sending any EchoCanceller) -> EchoCancellationPipeline {
        EchoCancellationPipeline(
            canceller: canceller,
            onOutput: { buffer, hostTime in
                let delivered = MimiKitTests.samples(of: buffer)
                self.buffers.withLock { $0.append((delivered, hostTime)) }
            },
            onFailure: { _ in self.failures.withLock { $0 += 1 } }
        )
    }
}

private let rate = Double(EchoCancellationPipeline.sampleRate)
private let frameLength = EchoCancellationPipeline.frameLength
private let leadFrames = Int(EchoCancellationPipeline.referenceLead * rate)

/// Appends `samples` in chunks of `chunk` frames, timestamped from `start` at `sampleRate`.
private func append(
    _ samples: [Float],
    chunk: Int,
    from start: Double,
    sampleRate: Double = rate,
    timeScale: Double = 1,
    to append: (AVAudioPCMBuffer, UInt64) -> Void
) {
    var index = 0
    while index < samples.count {
        let end = min(index + chunk, samples.count)
        append(makeBuffer(Array(samples[index..<end]), sampleRate: sampleRate), hostTime(start + Double(index) / sampleRate * timeScale))
        index = end
    }
}

/// Distinct values that identify the position of each sample.
private func ramp(_ count: Int) -> [Float] {
    (0..<count).map { Float($0 + 1) }
}

struct EchoCancellationPipelineTests {
    @Test func pairsEachMicrophoneFrameWithTheReferenceFromTheLeadLater() {
        let log = EchoCancellerLog()
        let output = Output()
        let pipeline = output.pipeline(canceller: RecordingEchoCanceller(log: log))

        append(ramp(16000), chunk: 512, from: 10, to: pipeline.appendReference)
        append([Float](repeating: 0.5, count: 8000), chunk: 1600, from: 10, to: pipeline.appendCapture)
        pipeline.flush()

        let frames = log.referenceFrames
        #expect(frames.count == 8000 / frameLength)
        for (index, frame) in frames.enumerated() {
            let first = index * frameLength + leadFrames + 1
            #expect(frame == (first..<first + frameLength).map(Float.init))
        }
    }

    @Test func pairingStaysStableThroughResampling() {
        let log = EchoCancellerLog()
        let output = Output()
        let pipeline = output.pipeline(canceller: RecordingEchoCanceller(log: log))
        let deviceRate = 48000.0
        // A ramp stays a ramp through resampling, so each value tells the position it came from.
        let reference = (0..<(10 * Int(deviceRate))).map { Float($0) }
        var referenceIndex = 0
        var captureIndex = 0
        // Buffers as the devices deliver them: 512 frames of system audio, 100 ms of microphone audio.
        while captureIndex + 4800 <= 9 * Int(deviceRate) {
            while referenceIndex < captureIndex + 4800 + 2 * Int(EchoCancellationPipeline.referenceLead * deviceRate) {
                let end = referenceIndex + 512
                pipeline.appendReference(makeBuffer(Array(reference[referenceIndex..<end]), sampleRate: deviceRate),
                                         hostTime: hostTime(110 + Double(referenceIndex) / deviceRate))
                referenceIndex = end
            }
            pipeline.appendCapture(makeBuffer([Float](repeating: 0.5, count: 4800), sampleRate: deviceRate),
                                   hostTime: hostTime(110 + Double(captureIndex) / deviceRate))
            captureIndex += 4800
        }
        pipeline.flush()

        // The offset between each frame and the reference it gets is the same throughout.
        let ratio = deviceRate / rate
        let offsets = log.referenceFrames.enumerated().dropFirst(10).dropLast(10).map { index, frame in
            Double(frame[frameLength / 2]) / ratio - Double(index * frameLength + frameLength / 2 + leadFrames)
        }
        // The resampler computes in single precision, so a ramp this large comes out up to about 0.0016% off
        // (2.2 positions at 9 s). The pairing itself must not move.
        let precision = 2e-5 * Double(reference.count) / ratio
        #expect(offsets.max()! - offsets.min()! < precision, "Offsets range from \(offsets.min()!) to \(offsets.max()!)")
        #expect(abs(offsets[0]) < Double(frameLength), "Offset \(offsets[0])")
    }

    @Test func deliversEveryMicrophoneSampleFromWhereItWasCaptured() {
        let output = Output()
        let pipeline = output.pipeline(canceller: RecordingEchoCanceller())
        let captured = ramp(5000)

        append(captured, chunk: 1234, from: 20, to: pipeline.appendCapture)
        pipeline.flush()

        #expect(output.samples == captured)
        let first = output.deliveries[0].hostTime
        #expect(abs(AVAudioTime.seconds(forHostTime: first) - 20) < 1 / rate)
        var position = 0
        for delivery in output.deliveries {
            let expected = 20 + Double(position) / rate
            #expect(abs(AVAudioTime.seconds(forHostTime: delivery.hostTime) - expected) < 1 / rate)
            position += delivery.samples.count
        }
    }

    @Test func waitsForTheReferenceUpToTheLimit() {
        let output = Output()
        let pipeline = output.pipeline(canceller: RecordingEchoCanceller())
        let waitLimit = Int(EchoCancellationPipeline.referenceWaitLimit * rate)

        append([Float](repeating: 0.5, count: 1600), chunk: 1600, from: 30, to: pipeline.appendCapture)
        #expect(output.samples.isEmpty)

        append([Float](repeating: 0.5, count: 6400), chunk: 1600, from: 30.1, to: pipeline.appendCapture)
        // Frames are processed without their reference once the audio after them exceeds the limit.
        let processed = output.samples.count
        #expect(processed > 0)
        #expect(8000 - processed >= waitLimit)
        #expect(8000 - processed < waitLimit + frameLength)
    }

    @Test func arrivingReferenceProcessesWaitingMicrophoneAudio() {
        let output = Output()
        let pipeline = output.pipeline(canceller: RecordingEchoCanceller())

        append([Float](repeating: 0.5, count: 1600), chunk: 1600, from: 40, to: pipeline.appendCapture)
        #expect(output.samples.isEmpty)

        append(ramp(1600 + leadFrames), chunk: 512, from: 40, to: pipeline.appendReference)
        #expect(output.samples.count == 1600)
    }

    @Test func missingReferenceIsSilence() {
        let log = EchoCancellerLog()
        let output = Output()
        let pipeline = output.pipeline(canceller: RecordingEchoCanceller(log: log))

        append([Float](repeating: 0.5, count: 3200), chunk: 1600, from: 50, to: pipeline.appendCapture)
        pipeline.flush()

        #expect(log.referenceFrames.allSatisfy { $0.allSatisfy { $0 == 0 } })
        #expect(output.samples.count == 3200)
    }

    @Test func followsReferenceDriftingFromTheMicrophoneClock() {
        let log = EchoCancellerLog()
        let output = Output()
        let pipeline = output.pipeline(canceller: RecordingEchoCanceller(log: log))
        // The reference device runs 0.1% slow: its samples span more host time than their count suggests.
        let drift = 1.001
        let duration = 10 * Int(rate)

        let reference = ramp(duration + 2 * leadFrames)
        var referenceIndex = 0
        var captureIndex = 0
        // Interleaves the streams as they would arrive.
        while captureIndex < duration {
            let captureEnd = captureIndex + 1600
            while Double(referenceIndex) * drift < Double(captureEnd + leadFrames + frameLength) {
                let end = referenceIndex + 512
                pipeline.appendReference(makeBuffer(Array(reference[referenceIndex..<end])), hostTime: hostTime(60 + Double(referenceIndex) / rate * drift))
                referenceIndex = end
            }
            pipeline.appendCapture(makeBuffer([Float](repeating: 0.5, count: 1600)), hostTime: hostTime(60 + Double(captureIndex) / rate))
            captureIndex = captureEnd
        }
        pipeline.flush()

        // Each sample is the reference captured at its time plus the lead, within the drift tolerance. Corrections
        // fill the reference with silence where they move it forward.
        let tolerance = EchoCancellationPipeline.driftTolerance * rate + 2
        let frames = log.referenceFrames
        #expect(frames.count == duration / frameLength)
        for (index, frame) in frames.enumerated() {
            for (offset, value) in frame.enumerated() where value != 0 {
                let expectedReferenceIndex = Double(index * frameLength + offset + leadFrames) / drift
                #expect(abs(Double(value - 1) - expectedReferenceIndex) <= tolerance)
            }
            #expect(frame.filter { $0 == 0 }.count <= Int(tolerance))
        }
    }

    @Test func discontinuousMicrophoneAudioStartsANewRun() {
        let output = Output()
        let pipeline = output.pipeline(canceller: RecordingEchoCanceller())

        append(ramp(800), chunk: 800, from: 70, to: pipeline.appendCapture)
        append(ramp(800), chunk: 800, from: 71, to: pipeline.appendCapture)
        pipeline.flush()

        let deliveries = output.deliveries
        #expect(deliveries.map(\.samples.count) == [800, 800])
        #expect(abs(AVAudioTime.seconds(forHostTime: deliveries[0].hostTime) - 70) < 1 / rate)
        #expect(abs(AVAudioTime.seconds(forHostTime: deliveries[1].hostTime) - 71) < 1 / rate)
    }

    @Test func overlappingMicrophoneAudioKeepsItsTimeAndReference() {
        let log = EchoCancellerLog()
        let output = Output()
        let pipeline = output.pipeline(canceller: RecordingEchoCanceller(log: log))
        append(ramp(16000), chunk: 512, from: 80, to: pipeline.appendReference)

        append([Float](repeating: 0.5, count: 1600), chunk: 1600, from: 80, to: pipeline.appendCapture)
        // In another format and timestamped within the audio of the first run, such as after a device restart,
        // so the first run ends with this buffer.
        append([Float](repeating: 0.5, count: 4800), chunk: 4800, from: 80.05, sampleRate: 48000, to: pipeline.appendCapture)
        pipeline.flush()

        let deliveries = output.deliveries
        #expect(deliveries.map(\.samples.count).reduce(0, +) >= 3200 - frameLength)
        #expect(abs(AVAudioTime.seconds(forHostTime: deliveries[0].hostTime) - 80) < 1 / rate)
        let secondRun = deliveries.first { $0.hostTime > hostTime(80.01) }
        #expect(abs(AVAudioTime.seconds(forHostTime: secondRun!.hostTime) - 80.05) < 1 / rate)
        // The second run is processed with the reference from its own capture time, past the overlap whose
        // reference the first run already used.
        let firstRunFrames = 1600 / frameLength
        let laterFrame = log.referenceFrames[firstRunFrames + 5]
        let expected = Float(Int(0.05 * rate) + 5 * frameLength + leadFrames + 1)
        // The second run is resampled from 48 kHz, which delays its samples by the converter's latency.
        #expect(abs(laterFrame[frameLength / 2] - (expected + Float(frameLength / 2))) < 32)
    }

    @Test func convertsOtherFormats() {
        let output = Output()
        let pipeline = output.pipeline(canceller: RecordingEchoCanceller())

        append([Float](repeating: 0.5, count: 48000), chunk: 4800, from: 90, sampleRate: 48000, to: pipeline.appendCapture)
        pipeline.flush()

        #expect(abs(output.samples.count - 16000) <= frameLength)
    }

    @Test func failureStopsProcessing() {
        let output = Output()
        let pipeline = output.pipeline(canceller: RecordingEchoCanceller(error: TestError()))

        append([Float](repeating: 0.5, count: 1600), chunk: 1600, from: 100, to: pipeline.appendCapture)
        pipeline.flush()
        append([Float](repeating: 0.5, count: 1600), chunk: 1600, from: 100.1, to: pipeline.appendCapture)
        pipeline.flush()

        #expect(output.failureCount == 1)
        #expect(output.samples.isEmpty)
    }
}

/// Runs the WebRTC canceller through the pipeline on a simulated echo of the reference.
struct WebRTCEchoCancellationTests {
    /// Deterministic noise with speech-like pauses, standing in for the other side of a meeting.
    private static func farEnd(_ count: Int, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<count).map { index in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(Int64(bitPattern: state) >> 40) / Float(1 << 23)
            // 1.5 s of sound, then 0.5 s of silence.
            return index % 32000 < 24000 ? noise * 0.3 : 0
        }
    }

    /// What the microphone picks up: `near` plus the far end, `delay` seconds after its timestamps, with reflections.
    private static func microphone(far: [Float], near: [Float], delay: Double) -> [Float] {
        var mic = near
        let reflections: [(Double, Float)] = [(0, 0.4), (0.007, 0.2), (0.019, 0.1)]
        for (offset, gain) in reflections {
            let shift = Int(((delay + offset) * rate).rounded())
            for index in mic.indices where index - shift >= 0 && index - shift < far.count {
                mic[index] += far[index - shift] * gain
            }
        }
        return mic
    }

    private static func run(far: [Float], mic: [Float]) throws -> [Float] {
        let output = Output()
        let pipeline = output.pipeline(canceller: try WebRTCEchoCanceller(sampleRate: EchoCancellationPipeline.sampleRate))
        var farIndex = 0
        var micIndex = 0
        // Delivered like the devices do: the system audio in 512-frame buffers, the microphone in 100 ms ones.
        while micIndex < mic.count {
            let micEnd = min(micIndex + 1600, mic.count)
            while farIndex < far.count, farIndex < micEnd + leadFrames + 512 {
                let end = min(farIndex + 512, far.count)
                pipeline.appendReference(makeBuffer(Array(far[farIndex..<end])), hostTime: hostTime(200 + Double(farIndex) / rate))
                farIndex = end
            }
            pipeline.appendCapture(makeBuffer(Array(mic[micIndex..<micEnd])), hostTime: hostTime(200 + Double(micIndex) / rate))
            micIndex = micEnd
        }
        pipeline.flush()
        #expect(output.failureCount == 0)
        return output.samples
    }

    private static func powerDecibels(_ samples: ArraySlice<Float>) -> Double {
        let meanSquare = samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(samples.count, 1))
        return 10 * log10(max(meanSquare, 1e-12))
    }

    @Test(arguments: [0.025, -0.02, 0.2])
    func removesEchoFollowingOrSlightlyPrecedingItsTimestamp(delay: Double) throws {
        let count = 12 * Int(rate)
        let far = Self.farEnd(count, seed: 1)
        let mic = Self.microphone(far: far, near: [Float](repeating: 0, count: count), delay: delay)

        let output = try Self.run(far: far, mic: mic)
        #expect(output.count == mic.count)
        // After the canceller has converged.
        let tail = (count - 4 * Int(rate))..<count
        let reduction = Self.powerDecibels(mic[tail]) - Self.powerDecibels(output[tail])
        #expect(reduction > 15, "Echo reduced by \(reduction) dB")
    }

    @Test func keepsTheUserSpeechWhenNothingPlays() throws {
        let count = 6 * Int(rate)
        let near = Self.farEnd(count, seed: 2)
        let output = try Self.run(far: [], mic: near)

        #expect(output.count == near.count)
        let change = Self.powerDecibels(output[...]) - Self.powerDecibels(near[...])
        #expect(abs(change) < 1, "Speech changed by \(change) dB")
    }

    @Test func keepsTheUserSpeechOverEcho() throws {
        let count = 16 * Int(rate)
        let far = Self.farEnd(count, seed: 3)
        // The user starts speaking after the canceller has had time to converge on the echo.
        var near = [Float](repeating: 0, count: count)
        let speech = Self.farEnd(4 * Int(rate), seed: 4)
        near.replaceSubrange((10 * Int(rate))..<(14 * Int(rate)), with: speech)
        let mic = Self.microphone(far: far, near: near, delay: 0.025)

        let output = try Self.run(far: far, mic: mic)
        let speaking = (10 * Int(rate))..<(14 * Int(rate))
        // Removing the echo leaves most of the speech.
        let kept = Self.powerDecibels(output[speaking]) - Self.powerDecibels(near[speaking])
        #expect(kept > -6, "Speech kept at \(kept) dB")
    }

    @Test func rejectsUnsupportedSampleRates() {
        #expect(throws: EchoCancellerError.self) {
            try WebRTCEchoCanceller(sampleRate: 44100)
        }
    }
}
