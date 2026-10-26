import AVFAudio

public protocol TranscriptionEngine: AnyObject, Sendable {
    /// Starts transcription. Result times are in seconds since `timelineOrigin`, a host time.
    /// The returned stream finishes after ``finish()`` once all results have been delivered.
    func start(timelineOrigin: UInt64) async throws -> AsyncThrowingStream<TranscriptionResult, any Error>
    /// Safe to call from any thread. `buffer` only needs to stay valid for the duration of the call.
    func append(_ buffer: AVAudioPCMBuffer, hostTime: UInt64)
    /// Delivers final results for all audio appended so far, and keeps transcribing audio appended later.
    /// Used when the input pauses, so that the speech before the pause does not stay in progress.
    func finalizePending() async
    func finish() async
}
