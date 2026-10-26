import AVFAudio

public protocol TranscriptionEngine: Sendable {
    /// Starts transcription. Result times are in seconds since `timelineOrigin`, a host time.
    /// The returned stream finishes after ``finish()`` once all results have been delivered.
    func start(timelineOrigin: UInt64) async throws -> AsyncThrowingStream<TranscriptionResult, any Error>
    /// Safe to call from any thread. `buffer` only needs to stay valid for the duration of the call.
    func append(_ buffer: AVAudioPCMBuffer, hostTime: UInt64)
    func finish() async
}
