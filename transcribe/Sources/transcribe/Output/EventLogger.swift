import Foundation

public actor EventLogger {
  private let writer: JSONLWriter
  private let console: ConsoleReporter
  private var reportedWriteFailure = false

  public init(writer: JSONLWriter, console: ConsoleReporter) {
    self.writer = writer
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

  private func tryWrite(_ event: Event) async {
    do {
      try await writer.write(event)
    } catch {
      // best-effort: JSONL 書き込み失敗は呼び出し側に伝播しない。
      // ただし spec line 214 に従い、失敗を stderr で 1 回だけ通知する
      // (後続の呼び出しで flood しないようフラグで制御)。
      // 以降のイベントが欠落し得るため severity は error 相当。
      if !reportedWriteFailure {
        reportedWriteFailure = true
        await console.reportError(
          "JSONL write failed; subsequent events may be missing from the file: \(error)"
        )
      }
    }
  }
}
