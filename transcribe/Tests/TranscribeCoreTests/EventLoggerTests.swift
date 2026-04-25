import Foundation
import Testing

@testable import TranscribeCore

@Suite struct EventLoggerTests {
  private func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "transcribe-test-\(UUID().uuidString).jsonl")
  }

  final class InMemoryStream: TextOutputStream, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    func write(_ string: String) {
      lock.lock()
      defer { lock.unlock() }
      buffer += string
    }
    var content: String {
      lock.lock()
      defer { lock.unlock() }
      return buffer
    }
  }

  @Test func sessionStartedWritesJSONLOnly() async throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try JSONLWriter(output: url)
    let stream = InMemoryStream()
    let console = ConsoleReporter(stream: stream)
    let logger = EventLogger(writer: writer, console: console)

    await logger.sessionStarted(model: "m")
    try await writer.close()

    #expect(stream.content.isEmpty)
    let content = try String(contentsOf: url, encoding: .utf8)
    #expect(content.contains("\"type\":\"session_started\""))
    #expect(content.contains("\"model\":\"m\""))
  }

  @Test func stateChangedWritesJSONLOnly() async throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try JSONLWriter(output: url)
    let stream = InMemoryStream()
    let console = ConsoleReporter(stream: stream)
    let logger = EventLogger(writer: writer, console: console)

    await logger.stateChanged(.capturing)
    try await writer.close()

    #expect(stream.content.isEmpty)
    let content = try String(contentsOf: url, encoding: .utf8)
    #expect(content.contains("\"type\":\"state_changed\""))
    #expect(content.contains("\"state\":\"capturing\""))
  }

  @Test func sessionStoppedWritesJSONLOnly() async throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try JSONLWriter(output: url)
    let stream = InMemoryStream()
    let console = ConsoleReporter(stream: stream)
    let logger = EventLogger(writer: writer, console: console)

    await logger.sessionStopped(reason: .sigint)
    try await writer.close()

    #expect(stream.content.isEmpty)
    let content = try String(contentsOf: url, encoding: .utf8)
    #expect(content.contains("\"type\":\"session_stopped\""))
    #expect(content.contains("\"reason\":\"sigint\""))
  }

  @Test func warningWritesBoth() async throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try JSONLWriter(output: url)
    let stream = InMemoryStream()
    let console = ConsoleReporter(stream: stream)
    let logger = EventLogger(writer: writer, console: console)

    await logger.warning("slow network")
    try await writer.close()

    #expect(stream.content.contains("Warning: slow network"))
    let content = try String(contentsOf: url, encoding: .utf8)
    #expect(content.contains("\"type\":\"warning\""))
    #expect(content.contains("\"message\":\"slow network\""))
  }

  @Test func errorWritesBoth() async throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try JSONLWriter(output: url)
    let stream = InMemoryStream()
    let console = ConsoleReporter(stream: stream)
    let logger = EventLogger(writer: writer, console: console)

    await logger.error("boom")
    try await writer.close()

    #expect(stream.content.contains("Error: boom"))
    let content = try String(contentsOf: url, encoding: .utf8)
    #expect(content.contains("\"type\":\"error\""))
    #expect(content.contains("\"message\":\"boom\""))
  }

  @Test func reportWritesSegmentAndConsoleLine() async throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try JSONLWriter(output: url)
    let stream = InMemoryStream()
    let console = ConsoleReporter(stream: stream)
    let logger = EventLogger(writer: writer, console: console)

    let seg = Segment(
      source: .mic, timestamp: Date(timeIntervalSince1970: 0), duration: 1.0, text: "hi")
    await logger.report(seg)
    try await writer.close()

    #expect(stream.content.hasPrefix("[mic] "))
    #expect(stream.content.contains("hi"))
    let content = try String(contentsOf: url, encoding: .utf8)
    #expect(content.contains("\"type\":\"segment\""))
    #expect(content.contains("\"text\":\"hi\""))
  }

  @Test func reportPreservesSegmentTimestamp() async throws {
    // segment.timestamp は発話時刻(PTS 由来)で、emit 時刻 (Date()) とは独立。
    // EventLogger.report が Date() で上書きしないことを確認する。
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try JSONLWriter(output: url)
    let stream = InMemoryStream()
    let console = ConsoleReporter(stream: stream)
    let logger = EventLogger(writer: writer, console: console)

    let segTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let seg = Segment(source: .mic, timestamp: segTimestamp, duration: 1.0, text: "hi")
    await logger.report(seg)
    try await writer.close()

    let lines = try String(contentsOf: url, encoding: .utf8)
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map(String.init)
    #expect(lines.count == 1)
    let decoded = try JSONDecoder().decode(Event.self, from: lines[0].data(using: .utf8)!)
    guard case .segment(let ts, let data) = decoded else {
      Issue.record("expected .segment variant, got \(decoded.typeString)")
      return
    }
    // fractional seconds 精度でほぼ一致すること
    #expect(abs(ts.timeIntervalSince(segTimestamp)) < 0.002)
    #expect(data.source == .mic)
    #expect(data.text == "hi")
  }

  @Test func statusMessageWritesStderrOnly() async throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try JSONLWriter(output: url)
    let stream = InMemoryStream()
    let console = ConsoleReporter(stream: stream)
    let logger = EventLogger(writer: writer, console: console)

    await logger.statusMessage("Loading model (m)...")
    try await writer.close()

    #expect(stream.content.contains("Loading model (m)..."))
    let content = try String(contentsOf: url, encoding: .utf8)
    // JSONL にイベントが全く書かれていないことを確認(単に空ではなく)
    #expect(!content.contains("\"type\""))
  }

  @Test func bestEffortSwallowsJSONLErrorsForAllEmitMethods() async throws {
    // writer を事前に閉じて全 write を失敗させ、EventLogger の全 emit メソッドが
    // throw しないこと + stderr に相応の出力が出ることを確認する。
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try JSONLWriter(output: url)
    try await writer.close()

    let stream = InMemoryStream()
    let console = ConsoleReporter(stream: stream)
    let logger = EventLogger(writer: writer, console: console)

    // JSONL のみのメソッドも throw しないこと
    await logger.sessionStarted(model: "m")
    await logger.stateChanged(.loadingModel)
    await logger.sessionStopped(reason: .error)

    // JSONL + stderr のメソッドは stderr に出続けること
    await logger.warning("disk full?")
    await logger.error("really broken")
    let seg = Segment(source: .system, timestamp: Date(), duration: 0.5, text: "x")
    await logger.report(seg)

    #expect(stream.content.contains("Warning: disk full?"))
    #expect(stream.content.contains("Error: really broken"))
    #expect(stream.content.contains("[sys] "))
    #expect(stream.content.contains("x"))
  }

  @Test func bestEffortSurvivesMultipleSubsequentFailures() async throws {
    // 初回の JSONL 失敗以降も、後続の warning/error が stderr に出続けることを確認する。
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try JSONLWriter(output: url)
    try await writer.close()

    let stream = InMemoryStream()
    let console = ConsoleReporter(stream: stream)
    let logger = EventLogger(writer: writer, console: console)

    await logger.warning("first")
    await logger.warning("second")
    await logger.error("third")

    #expect(stream.content.contains("Warning: first"))
    #expect(stream.content.contains("Warning: second"))
    #expect(stream.content.contains("Error: third"))

    // JSONL write failed 通知は flood しないよう 1 度だけであることを確認。
    let failureMarker = "JSONL write failed"
    let occurrences = stream.content.components(separatedBy: failureMarker).count - 1
    #expect(occurrences == 1, "expected exactly 1 JSONL failure warning, got \(occurrences)")
  }

  @Test func happyPathSequenceHasCorrectEventOrder() async throws {
    // 正常経路の JSONL 並び順を end-to-end で pin する。
    // 1 行目 = session_started、中間 = state_changed 群 + segment、最終 = session_stopped。
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try JSONLWriter(output: url)
    let stream = InMemoryStream()
    let console = ConsoleReporter(stream: stream)
    let logger = EventLogger(writer: writer, console: console)

    await logger.sessionStarted(model: "m")
    await logger.stateChanged(.loadingModel)
    await logger.stateChanged(.capturing)
    let seg = Segment(
      source: .mic, timestamp: Date(timeIntervalSince1970: 1_700_000_000), duration: 1.0, text: "hi"
    )
    await logger.report(seg)
    await logger.stateChanged(.stopping)
    await logger.sessionStopped(reason: .sigint)
    try await writer.close()

    let content = try String(contentsOf: url, encoding: .utf8)
    let lines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    let decoder = JSONDecoder()
    let events = try lines.map { try decoder.decode(Event.self, from: $0.data(using: .utf8)!) }

    #expect(events.count == 6)
    #expect(events[0].typeString == "session_started")
    if case .stateChanged(_, let d) = events[1] {
      #expect(d.state == .loadingModel)
    } else {
      Issue.record("events[1] != state_changed")
    }
    if case .stateChanged(_, let d) = events[2] {
      #expect(d.state == .capturing)
    } else {
      Issue.record("events[2] != state_changed")
    }
    #expect(events[3].typeString == "segment")
    if case .stateChanged(_, let d) = events[4] {
      #expect(d.state == .stopping)
    } else {
      Issue.record("events[4] != state_changed")
    }
    if case .sessionStopped(_, let d) = events.last! {
      #expect(d.reason == .sigint)
    } else {
      Issue.record("last != session_stopped")
    }
  }

  @Test func errorPathSequenceOmitsStoppingAndReportsReasonError() async throws {
    // スペック上のエラー経路: session_started → error → session_stopped{reason:error}
    // `state_changed: stopping` は発行されないこと (`stopping` は SIGINT 経由のみ発行) を検証する。
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try JSONLWriter(output: url)
    let stream = InMemoryStream()
    let console = ConsoleReporter(stream: stream)
    let logger = EventLogger(writer: writer, console: console)

    // Pipeline.run の fail(...) パスを模倣する
    await logger.sessionStarted(model: "m")
    await logger.error("Screen Recording permission required.")
    await logger.sessionStopped(reason: .error)
    try await writer.close()

    let content = try String(contentsOf: url, encoding: .utf8)
    let lines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    let decoder = JSONDecoder()
    let events = try lines.map { try decoder.decode(Event.self, from: $0.data(using: .utf8)!) }

    #expect(events.count == 3)
    #expect(events[0].typeString == "session_started")
    #expect(events[1].typeString == "error")
    if case .sessionStopped(_, let d) = events[2] {
      #expect(d.reason == .error)
    } else {
      Issue.record("events[2] != session_stopped")
    }
    // stopping は一度も現れないこと
    #expect(
      !events.contains { event in
        if case .stateChanged(_, let d) = event, d.state == .stopping { return true }
        return false
      })
  }

  @Test func sessionStartedTimestampUsesEmitTime() async throws {
    // session_started.timestamp は呼び出し時点の Date() であること。
    // refactor で init 時刻などに固定されたら気付けるよう before <= ts <= after で pin する。
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try JSONLWriter(output: url)
    let stream = InMemoryStream()
    let console = ConsoleReporter(stream: stream)
    let logger = EventLogger(writer: writer, console: console)

    let before = Date()
    await logger.sessionStarted(model: "m")
    let after = Date()
    try await writer.close()

    let content = try String(contentsOf: url, encoding: .utf8)
    let line = content.split(separator: "\n").first.map(String.init)!
    let event = try JSONDecoder().decode(Event.self, from: line.data(using: .utf8)!)
    let ts = event.timestamp
    // ISO8601 fractional seconds の丸め誤差を許容して前後を比較する。
    #expect(ts.timeIntervalSince(before) >= -0.002)
    #expect(after.timeIntervalSince(ts) >= -0.002)
  }

  @Test func nonSegmentEventsUseEmitTimeTimestamp() async throws {
    // 「segment 以外は Date() 発行時点」契約を、残り 4 methods でも pin する。
    // segment は別途 reportPreservesSegmentTimestamp で PTS 保持を検証済み。
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try JSONLWriter(output: url)
    let stream = InMemoryStream()
    let console = ConsoleReporter(stream: stream)
    let logger = EventLogger(writer: writer, console: console)

    let before = Date()
    await logger.stateChanged(.capturing)
    await logger.warning("w")
    await logger.error("e")
    await logger.sessionStopped(reason: .sigint)
    let after = Date()
    try await writer.close()

    let decoder = JSONDecoder()
    let lines = try String(contentsOf: url, encoding: .utf8)
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map { try decoder.decode(Event.self, from: $0.data(using: .utf8)!) }

    #expect(lines.count == 4)
    for event in lines {
      let ts = event.timestamp
      #expect(
        ts.timeIntervalSince(before) >= -0.002,
        "\(event.typeString) timestamp predates 'before'")
      #expect(
        after.timeIntervalSince(ts) >= -0.002,
        "\(event.typeString) timestamp postdates 'after'")
    }
  }
}
