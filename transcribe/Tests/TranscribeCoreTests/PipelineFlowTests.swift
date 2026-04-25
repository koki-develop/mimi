import Foundation
import Testing

@testable import TranscribeCore

/// Pipeline 内部フローの test。Layer A characterization で扱わない:
///   - diagnostic stream → JSONL warning event の経路
///   - segment fan-in (mic + system → JSONL segment events + 最終 stderr "Wrote N segments")
@Suite struct PipelineFlowTests {
  private func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "transcribe-flow-\(UUID().uuidString).jsonl")
  }

  private func decodeEvents(from url: URL) throws -> [Event] {
    let content = try String(contentsOf: url, encoding: .utf8)
    let lines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    let decoder = JSONDecoder()
    return try lines.map { line in
      try decoder.decode(Event.self, from: Data(line.utf8))
    }
  }

  @Test func diagnosticStreamWarningsAreEmittedToJSONL() async throws {
    let output = tempURL()
    defer { try? FileManager.default.removeItem(at: output) }

    let signal = ControllableSignalWaiter()
    let cap = FakeCapture(
      diagnostics: [
        .warning(source: .mic, message: "scripted-warning"),
        .status(message: "scripted-status"),
      ]
    )

    let d = PipelineDependencies(
      permissionCheck: {},
      transcriberFactory: FakeTranscriberFactory(
        mic: FakeTranscriber(), system: FakeTranscriber()),
      captureFactory: { _ in cap },
      signalWaiter: { await signal.wait() },
      writerFactory: { url in try JSONLWriter(output: url) }
    )

    signal.trigger()

    try await Pipeline(
      configuration: PipelineConfiguration(output: output, modelName: "test-model"),
      dependencies: d
    ).run()

    let events = try decodeEvents(from: output)
    let warnings = events.compactMap { event -> String? in
      if case .warning(_, let data) = event { return data.message }
      return nil
    }
    #expect(warnings.contains("scripted-warning"))
  }

  @Test func segmentFanInRecordsBothSourcesAndCounts() async throws {
    let output = tempURL()
    defer { try? FileManager.default.removeItem(at: output) }

    let micSeg = Segment(source: .mic, timestamp: Date(), duration: 1.0, text: "mic-text")
    let sysSeg = Segment(source: .system, timestamp: Date(), duration: 1.5, text: "sys-text")

    let signal = ControllableSignalWaiter()
    let cap = FakeCapture()

    let d = PipelineDependencies(
      permissionCheck: {},
      transcriberFactory: FakeTranscriberFactory(
        mic: FakeTranscriber(segments: [micSeg]),
        system: FakeTranscriber(segments: [sysSeg])
      ),
      captureFactory: { _ in cap },
      signalWaiter: { await signal.wait() },
      writerFactory: { url in try JSONLWriter(output: url) }
    )

    signal.trigger()

    try await Pipeline(
      configuration: PipelineConfiguration(output: output, modelName: "test-model"),
      dependencies: d
    ).run()

    let events = try decodeEvents(from: output)
    let segments = events.compactMap { event -> SegmentData? in
      if case .segment(_, let data) = event { return data }
      return nil
    }
    #expect(segments.count == 2)
    let texts = Set(segments.map(\.text))
    #expect(texts == ["mic-text", "sys-text"])
    let sources = Set(segments.map(\.source))
    #expect(sources == [.mic, .system])
  }
}
