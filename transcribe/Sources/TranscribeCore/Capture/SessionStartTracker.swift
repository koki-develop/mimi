import Foundation

/// SCStream 開始時刻と最初に観測された capture 時刻のうち早い方を保持する。
/// `AudioCapture` のライフサイクルから独立してテスト可能。
final class SessionStartTracker: @unchecked Sendable {
  private let lock = NSLock()
  private var requestedAt: Date?
  private var firstCaptureTime: Date?

  var startedAt: Date? {
    lock.lock()
    defer { lock.unlock() }
    return firstCaptureTime ?? requestedAt
  }

  func markRequested(at date: Date) {
    lock.lock()
    defer { lock.unlock() }

    requestedAt = date
  }

  func recordCaptureTime(_ date: Date) {
    lock.lock()
    defer { lock.unlock() }

    if let firstCaptureTime {
      if date < firstCaptureTime {
        self.firstCaptureTime = date
      }
    } else {
      firstCaptureTime = date
    }
  }
}
