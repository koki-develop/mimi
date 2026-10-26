import AVFAudio

/// Receives captured audio. `buffer` is only valid for the duration of the call.
/// `hostTime` is the host time (`mach_absolute_time`) at which the first frame was captured.
public typealias AudioBufferHandler = @Sendable (_ buffer: AVAudioPCMBuffer, _ hostTime: UInt64) -> Void

/// A source of captured audio. Follows changes of the system audio devices on its own while running.
@MainActor
public protocol AudioSource: AnyObject {
    /// Requests permission to capture, returning whether capture is allowed.
    func requestAccess() async -> Bool
    /// `onBuffer` is called on a background thread. `onFailure` is called when capture stops
    /// unexpectedly and cannot be resumed; the source is stopped by then.
    func start(onBuffer: @escaping AudioBufferHandler, onFailure: @escaping (any Error) -> Void) throws
    func stop()
}
