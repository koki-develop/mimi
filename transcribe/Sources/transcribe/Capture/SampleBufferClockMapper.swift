import CoreMedia
import Foundation

struct SampleBufferClockMapper: Sendable {
    private var anchorPresentationTime: CMTime?
    private var anchorDate: Date?

    mutating func captureTime(for presentationTime: CMTime, fallbackDate: Date) -> Date {
        guard presentationTime.isValid, !presentationTime.isIndefinite else {
            return fallbackDate
        }

        if let anchorPresentationTime, let anchorDate {
            let delta = CMTimeSubtract(presentationTime, anchorPresentationTime)
            guard delta.isValid, !delta.isIndefinite else {
                return fallbackDate
            }
            return anchorDate.addingTimeInterval(delta.seconds)
        }

        anchorPresentationTime = presentationTime
        anchorDate = fallbackDate
        return fallbackDate
    }
}
