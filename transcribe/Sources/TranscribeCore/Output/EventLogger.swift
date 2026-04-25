import Foundation

public actor EventLogger {
  private let sink: any EventSink
  private let console: ConsoleReporter
  private var reportedWriteFailure = false

  public init(sink: any EventSink, console: ConsoleReporter) {
    self.sink = sink
    self.console = console
  }

  public func sessionStarted(model: String) async {
    let event = Event.sessionStarted(
      timestamp: Date(),
      data: SessionStartedData(model: model)
    )
    await tryWrite(event)
  }

  public func stateChanged(_ state: State) async {
    let event = Event.stateChanged(
      timestamp: Date(),
      data: StateChangedData(state: state)
    )
    await tryWrite(event)
  }

  public func sessionStopped(reason: StopReason) async {
    let event = Event.sessionStopped(
      timestamp: Date(),
      data: SessionStoppedData(reason: reason)
    )
    await tryWrite(event)
  }

  public func report(_ segment: Segment) async {
    let event = Event.segment(
      timestamp: segment.timestamp,
      data: SegmentData(source: segment.source, duration: segment.duration, text: segment.text)
    )
    await tryWrite(event)
    await console.report(segment)
  }

  public func warning(_ message: String) async {
    let event = Event.warning(
      timestamp: Date(),
      data: WarningData(message: message)
    )
    await tryWrite(event)
    await console.reportWarning(message)
  }

  public func error(_ message: String) async {
    let event = Event.error(
      timestamp: Date(),
      data: ErrorData(message: message)
    )
    await tryWrite(event)
    await console.reportError(message)
  }

  public func statusMessage(_ message: String) async {
    await console.reportStatus(message)
  }

  /// セッション中に 1 回でも sink への write が失敗していたかを返す。
  /// daemon では各セッションの後始末経路で参照することがある (現状は flushedWithErrors を
  /// 直接 exit code に紐付けないが、stderr 通知の判定に使う)。
  public func flushedWithErrors() -> Bool {
    reportedWriteFailure
  }

  private func tryWrite(_ event: Event) async {
    do {
      try await sink.write(event)
    } catch {
      // best-effort: sink への書き込み失敗は本メソッドからは throw しない。
      // 失敗を stderr で 1 回だけ通知する (後続の呼び出しで flood しないようフラグで制御)。
      if !reportedWriteFailure {
        reportedWriteFailure = true
        await console.reportError(
          "event sink write failed; subsequent events may be missing: \(error)"
        )
      }
    }
  }
}
