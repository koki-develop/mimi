import AVFAudio
import Synchronization

/// Holds the latest level of an audio stream. Updated from the audio thread and read by the UI at its own pace.
public final class AudioLevelMeter: Sendable {
    private let value = Mutex<Float>(0)

    public init() {}

    /// The latest level in 0...1. See ``AudioLevel/normalized(_:floorDecibels:)``.
    public var level: Float {
        value.withLock { $0 }
    }

    public func update(with buffer: AVAudioPCMBuffer) {
        let level = AudioLevel.normalized(buffer)
        value.withLock { $0 = level }
    }

    public func reset() {
        value.withLock { $0 = 0 }
    }
}
