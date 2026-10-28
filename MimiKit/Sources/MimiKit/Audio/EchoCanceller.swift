import CEchoCanceller
import Foundation

/// Removes the echo of a reference signal, the audio played through the speakers, from a captured signal.
/// Processes mono 10 ms frames at the sample rate it was created for. Not thread-safe.
public protocol EchoCanceller: AnyObject {
    /// Analyzes one frame of the reference. Each call is followed by ``removeEcho(from:)`` for the frame
    /// captured at the same time.
    func analyzeReference(_ frame: UnsafeBufferPointer<Float>) throws
    /// Removes the echo of the reference from one captured frame, in place.
    func removeEcho(from frame: UnsafeMutableBufferPointer<Float>) throws
}

public enum EchoCancellerError: LocalizedError {
    /// The sample rate is not supported, or the canceller could not be set up.
    case unavailable(sampleRate: Int)
    case processingFailed(operation: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case let .unavailable(sampleRate):
            "Echo cancellation could not be set up for \(sampleRate) Hz"
        case let .processingFailed(operation, code):
            "Echo cancellation \(operation) failed (error \(code))"
        }
    }
}

/// WebRTC AEC3, which estimates the delay of the echo behind the reference on its own.
final class WebRTCEchoCanceller: EchoCanceller {
    private let canceller: OpaquePointer

    init(sampleRate: Int) throws(EchoCancellerError) {
        guard let canceller = mimi_echo_canceller_create(Int32(sampleRate)) else {
            throw .unavailable(sampleRate: sampleRate)
        }
        self.canceller = canceller
    }

    deinit {
        mimi_echo_canceller_destroy(canceller)
    }

    func analyzeReference(_ frame: UnsafeBufferPointer<Float>) throws {
        try check(mimi_echo_canceller_analyze_render(canceller, frame.baseAddress), "analyzeReference")
    }

    func removeEcho(from frame: UnsafeMutableBufferPointer<Float>) throws {
        try check(mimi_echo_canceller_process_capture(canceller, frame.baseAddress), "removeEcho")
    }

    private func check(_ code: Int32, _ operation: String) throws(EchoCancellerError) {
        guard code == 0 else {
            throw .processingFailed(operation: operation, code: code)
        }
    }
}
