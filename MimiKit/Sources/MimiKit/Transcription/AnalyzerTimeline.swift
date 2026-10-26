import Foundation

/// Maps captured audio onto a timeline shared by every transcription engine in a session,
/// so that results from different audio sources can be ordered against each other.
///
/// Times are in seconds. The timeline starts at `origin`, a host time in seconds.
struct AnalyzerTimeline {
    /// Gaps or overlaps between consecutive captured buffers beyond this are treated as a discontinuity.
    static let continuityTolerance: TimeInterval = 0.1

    let origin: TimeInterval
    /// The end of the audio supplied to the analyzer so far.
    private(set) var end: TimeInterval = 0
    private var expectedNextCaptureTime: TimeInterval?

    init(origin: TimeInterval) {
        self.origin = origin
    }

    /// Registers a captured buffer and returns whether it does not directly follow the previous one.
    mutating func registerCapture(at captureTime: TimeInterval, duration: TimeInterval) -> Bool {
        defer { expectedNextCaptureTime = captureTime + duration }
        guard let expectedNextCaptureTime else { return true }
        return abs(captureTime - expectedNextCaptureTime) > Self.continuityTolerance
    }

    /// The analyzer start time for audio captured at `captureTime` that begins a new contiguous run.
    /// Never precedes audio already supplied, since the analyzer rejects overlapping input.
    func startTime(forRunCapturedAt captureTime: TimeInterval) -> TimeInterval {
        max(captureTime - origin, end)
    }

    /// Registers audio supplied to the analyzer. `start` is `nil` when it directly follows the previous audio.
    mutating func registerAnalyzerInput(start: TimeInterval?, duration: TimeInterval) {
        end = (start ?? end) + duration
    }
}
