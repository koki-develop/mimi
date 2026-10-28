import AVFAudio

/// Receives captured audio. `buffer` is only valid for the duration of the call.
/// `hostTime` is the host time (`mach_absolute_time`) at which the first frame was captured.
public typealias AudioBufferHandler = @Sendable (_ buffer: AVAudioPCMBuffer, _ hostTime: UInt64) -> Void

public enum AudioSourceAvailability: Sendable {
    case available
    /// No audio is captured until the devices change in a way that lets capture resume.
    case unavailable(any Error)
}

/// A source of captured audio. Follows changes of the system audio devices on its own while running.
@MainActor
public protocol AudioSource: AnyObject {
    /// Requests permission to capture, returning whether capture is allowed.
    func requestAccess() async -> Bool
    /// Starts capturing, or waiting for a device to capture from. The source is available until it reports otherwise.
    /// `onBuffer` is called on a background thread. `onAvailabilityChange` is called when capture stops or resumes
    /// because of the devices, and not after ``stop()`` is called.
    func start(onBuffer: @escaping AudioBufferHandler, onAvailabilityChange: @escaping @MainActor (AudioSourceAvailability) -> Void)
    /// Returns once no more audio is delivered.
    func stop() async
}
