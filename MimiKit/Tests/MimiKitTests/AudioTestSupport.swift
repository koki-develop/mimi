import AVFAudio
import MimiKit
import Synchronization

/// A mono buffer holding `samples`.
func makeBuffer(_ samples: [Float], sampleRate: Double = 16000) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    for (index, sample) in samples.enumerated() {
        buffer.floatChannelData![0][index] = sample
    }
    return buffer
}

func samples(of buffer: AVAudioPCMBuffer) -> [Float] {
    Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

func hostTime(_ seconds: Double) -> UInt64 {
    AVAudioTime.hostTime(forSeconds: seconds)
}

/// The frames a ``RecordingEchoCanceller`` was given, readable after the canceller has been handed over.
final class EchoCancellerLog: Sendable {
    private let frames = Mutex<(reference: [[Float]], capture: [[Float]])>(([], []))

    var referenceFrames: [[Float]] {
        frames.withLock { $0.reference }
    }

    var captureFrames: [[Float]] {
        frames.withLock { $0.capture }
    }

    fileprivate func record(reference frame: [Float]) {
        frames.withLock { $0.reference.append(frame) }
    }

    fileprivate func record(capture frame: [Float]) {
        frames.withLock { $0.capture.append(frame) }
    }
}

/// Leaves the captured audio unchanged and records the frames it was given.
final class RecordingEchoCanceller: EchoCanceller {
    let log: EchoCancellerLog
    private let error: (any Error)?

    init(log: EchoCancellerLog = EchoCancellerLog(), error: (any Error)? = nil) {
        self.log = log
        self.error = error
    }

    func analyzeReference(_ frame: UnsafeBufferPointer<Float>) throws {
        if let error { throw error }
        log.record(reference: Array(frame))
    }

    func removeEcho(from frame: UnsafeMutableBufferPointer<Float>) throws {
        if let error { throw error }
        log.record(capture: Array(frame))
    }
}
