import Foundation

/// Pipeline 停止時の責務を集中させた actor。
public actor ShutdownCoordinator {
  /// `finalize(streamError:)` の戻り値。
  /// 不可能な状態 (e.g. `.sigint` + errorMessage="boom") を型レベルで排除するため sum 型。
  public enum Outcome: Sendable, Equatable {
    case sigint(segmentCount: Int)
    case error(message: String?, segmentCount: Int)

    public var reason: StopReason {
      switch self {
      case .sigint: return .sigint
      case .error: return .error
      }
    }

    public var segmentCount: Int {
      switch self {
      case .sigint(let count), .error(_, let count):
        return count
      }
    }
  }

  private var stopReason: StopReason?
  private var segmentCount: Int = 0

  public init() {}

  public func recordSegment() {
    segmentCount += 1
  }

  public func recordSIGINT() {
    trySetReason(.sigint)
  }

  public func recordConsumerEOF() {
    // consumer の早期終了は本来異常系なので `.error` を tryset。
    // SIGINT が先に set されていれば SIGINT が優先される。
    trySetReason(.error)
  }

  /// 現時点で記録されている stop reason をそのまま返す (まだ何も記録されていなければ nil)。
  /// SIGINT 経路を取ったかどうかの判定に使う shortcut。
  public func currentReason() -> StopReason? {
    stopReason
  }

  /// 停止原因を確定する。
  /// stream error が検出されていれば SIGINT より優先して `.error` 扱いになり、
  /// `Outcome.error(message: ...)` で文字列を載せる。
  public func finalize(streamError: Error?) -> Outcome {
    if let streamError {
      return .error(
        message: "Capture stopped unexpectedly: \(streamError)",
        segmentCount: segmentCount
      )
    }
    switch stopReason ?? .error {
    case .sigint:
      return .sigint(segmentCount: segmentCount)
    case .error:
      return .error(message: nil, segmentCount: segmentCount)
    }
  }

  private func trySetReason(_ reason: StopReason) {
    if stopReason == nil { stopReason = reason }
  }
}
