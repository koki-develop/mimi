import Foundation

public enum Event: Sendable, Equatable {
  case sessionStarted(timestamp: Date, data: SessionStartedData)
  case stateChanged(timestamp: Date, data: StateChangedData)
  case segment(timestamp: Date, data: SegmentData)
  case warning(timestamp: Date, data: WarningData)
  case error(timestamp: Date, data: ErrorData)
  case sessionStopped(timestamp: Date, data: SessionStoppedData)
}

public struct SessionStartedData: Sendable, Codable, Equatable {
  public let model: String

  public init(model: String) {
    self.model = model
  }
}

public struct StateChangedData: Sendable, Codable, Equatable {
  public let state: State

  public init(state: State) {
    self.state = state
  }
}

public enum State: String, Sendable, Codable, Equatable {
  case loadingModel = "loading_model"
  case ready
  case capturing
  case stopping
  case fatal
}

public struct SegmentData: Sendable, Codable, Equatable {
  public let source: AudioSource
  public let duration: Double
  public let text: String

  public init(source: AudioSource, duration: Double, text: String) {
    self.source = source
    self.duration = duration
    self.text = text
  }
}

public struct WarningData: Sendable, Codable, Equatable {
  public let message: String

  public init(message: String) {
    self.message = message
  }
}

public struct ErrorData: Sendable, Codable, Equatable {
  public let message: String

  public init(message: String) {
    self.message = message
  }
}

public struct SessionStoppedData: Sendable, Codable, Equatable {
  public let reason: StopReason

  public init(reason: StopReason) {
    self.reason = reason
  }
}

public enum StopReason: String, Sendable, Codable, Equatable {
  case stop
  case error
}

extension Event {
  /// ワイヤ上の `type` 文字列との対応を単一の enum で表現する。
  /// encode/decode の両方でこの enum を通すことで、case 追加漏れを
  /// コンパイラが検出できるようにしている。
  fileprivate enum Kind: String {
    case sessionStarted = "session_started"
    case stateChanged = "state_changed"
    case segment
    case warning
    case error
    case sessionStopped = "session_stopped"
  }

  fileprivate var kind: Kind {
    switch self {
    case .sessionStarted: return .sessionStarted
    case .stateChanged: return .stateChanged
    case .segment: return .segment
    case .warning: return .warning
    case .error: return .error
    case .sessionStopped: return .sessionStopped
    }
  }

  public var typeString: String { kind.rawValue }

  public var timestamp: Date {
    switch self {
    case .sessionStarted(let ts, _): return ts
    case .stateChanged(let ts, _): return ts
    case .segment(let ts, _): return ts
    case .warning(let ts, _): return ts
    case .error(let ts, _): return ts
    case .sessionStopped(let ts, _): return ts
    }
  }
}

extension Event: Codable {
  private enum CodingKeys: String, CodingKey {
    case type, timestamp, data
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(typeString, forKey: .type)
    try container.encode(Timestamp.string(from: timestamp), forKey: .timestamp)

    switch self {
    case .sessionStarted(_, let d): try container.encode(d, forKey: .data)
    case .stateChanged(_, let d): try container.encode(d, forKey: .data)
    case .segment(_, let d): try container.encode(d, forKey: .data)
    case .warning(_, let d): try container.encode(d, forKey: .data)
    case .error(_, let d): try container.encode(d, forKey: .data)
    case .sessionStopped(_, let d): try container.encode(d, forKey: .data)
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let typeString = try container.decode(String.self, forKey: .type)
    guard let kind = Kind(rawValue: typeString) else {
      throw DecodingError.dataCorruptedError(
        forKey: .type,
        in: container,
        debugDescription: "Unknown event type: \(typeString)"
      )
    }
    let tsString = try container.decode(String.self, forKey: .timestamp)
    guard let ts = Timestamp.date(from: tsString) else {
      throw DecodingError.dataCorruptedError(
        forKey: .timestamp,
        in: container,
        debugDescription: "Invalid ISO8601 timestamp: \(tsString)"
      )
    }

    // switch を Kind に対して行うことで case 追加漏れをコンパイラが検出する。
    switch kind {
    case .sessionStarted:
      self = .sessionStarted(
        timestamp: ts, data: try container.decode(SessionStartedData.self, forKey: .data))
    case .stateChanged:
      self = .stateChanged(
        timestamp: ts, data: try container.decode(StateChangedData.self, forKey: .data))
    case .segment:
      self = .segment(timestamp: ts, data: try container.decode(SegmentData.self, forKey: .data))
    case .warning:
      self = .warning(timestamp: ts, data: try container.decode(WarningData.self, forKey: .data))
    case .error:
      self = .error(timestamp: ts, data: try container.decode(ErrorData.self, forKey: .data))
    case .sessionStopped:
      self = .sessionStopped(
        timestamp: ts, data: try container.decode(SessionStoppedData.self, forKey: .data))
    }
  }
}
