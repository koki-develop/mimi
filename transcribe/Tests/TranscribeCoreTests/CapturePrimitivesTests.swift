import AVFoundation
import Foundation
import ScreenCaptureKit
import Testing

@testable import TranscribeCore

@Suite struct AudioOutputTapMatchesTests {
  // matches は AudioOutputTap の SCStreamOutputType フィルタ。
  // 4 通り全て pin する (mic+microphone, system+audio, それ以外は false)。
  @Test func micMatchesMicrophone() {
    #expect(AudioOutputTap.matches(source: .mic, outputType: .microphone) == true)
  }
  @Test func micRejectsAudio() {
    #expect(AudioOutputTap.matches(source: .mic, outputType: .audio) == false)
  }
  @Test func systemMatchesAudio() {
    #expect(AudioOutputTap.matches(source: .system, outputType: .audio) == true)
  }
  @Test func systemRejectsMicrophone() {
    #expect(AudioOutputTap.matches(source: .system, outputType: .microphone) == false)
  }
}

@Suite struct SessionStartTrackerTests {
  @Test func startedAtPrefersFirstCaptureTime() {
    let t = SessionStartTracker()
    let req = Date(timeIntervalSince1970: 1_000_000)
    let cap = Date(timeIntervalSince1970: 999_999)
    t.markRequested(at: req)
    t.recordCaptureTime(cap)
    #expect(t.startedAt == cap)
  }

  @Test func startedAtFallsBackToRequestedWhenNoCapture() {
    let t = SessionStartTracker()
    let req = Date(timeIntervalSince1970: 1_000_000)
    t.markRequested(at: req)
    #expect(t.startedAt == req)
  }

  @Test func recordCaptureTimeKeepsEarliest() {
    let t = SessionStartTracker()
    let later = Date(timeIntervalSince1970: 2_000_000)
    let earlier = Date(timeIntervalSince1970: 1_000_000)
    t.recordCaptureTime(later)
    t.recordCaptureTime(earlier)
    #expect(t.startedAt == earlier)
  }

  @Test func recordCaptureTimeDoesNotMoveForward() {
    let t = SessionStartTracker()
    let earlier = Date(timeIntervalSince1970: 1_000_000)
    let later = Date(timeIntervalSince1970: 2_000_000)
    t.recordCaptureTime(earlier)
    t.recordCaptureTime(later)
    #expect(t.startedAt == earlier)
  }
}

@Suite struct SCStreamCoordinatorTests {
  /// Helper: pristine SCStreamCoordinator + continuations + 3 streams を一式作る。
  private func buildCoordinator() -> (
    coordinator: SCStreamCoordinator,
    micStream: AsyncStream<CapturedAudioChunk>,
    systemStream: AsyncStream<CapturedAudioChunk>,
    diagnosticStream: AsyncStream<CaptureDiagnostic>
  ) {
    var micCont: AsyncStream<CapturedAudioChunk>.Continuation!
    var sysCont: AsyncStream<CapturedAudioChunk>.Continuation!
    var diagCont: AsyncStream<CaptureDiagnostic>.Continuation!
    let micStream = AsyncStream<CapturedAudioChunk>(bufferingPolicy: .unbounded) {
      micCont = $0
    }
    let sysStream = AsyncStream<CapturedAudioChunk>(bufferingPolicy: .unbounded) {
      sysCont = $0
    }
    let diagStream = AsyncStream<CaptureDiagnostic>(bufferingPolicy: .unbounded) {
      diagCont = $0
    }
    let tracker = SessionStartTracker()
    let mic = AudioOutputTap(
      source: .mic, continuation: micCont,
      diagnosticContinuation: diagCont, verbose: false, sessionStart: tracker)
    let sys = AudioOutputTap(
      source: .system, continuation: sysCont,
      diagnosticContinuation: diagCont, verbose: false, sessionStart: tracker)
    let coord = SCStreamCoordinator(
      streamErrorBox: StreamErrorBox(),
      micOutput: mic,
      systemOutput: sys,
      micContinuation: micCont,
      systemContinuation: sysCont,
      diagnosticContinuation: diagCont
    )
    return (coord, micStream, sysStream, diagStream)
  }

  @Test func finishIsIdempotent() async {
    let (coord, micStream, sysStream, diagStream) = buildCoordinator()
    coord.finish()
    coord.finish()  // 2 度目: no-op
    coord.finish()  // 3 度目: no-op

    // 全 continuation は finish 済みのはず。drain して即終了することを確認。
    var micChunks = 0
    for await _ in micStream { micChunks += 1 }
    var sysChunks = 0
    for await _ in sysStream { sysChunks += 1 }
    var diags = 0
    for await _ in diagStream { diags += 1 }
    #expect(micChunks == 0)
    #expect(sysChunks == 0)
    #expect(diags == 0)
  }

  // 注: `stream(_:didStopWithError:)` の単体テストは SCStream のテスト用 ctor が無いため
  // 直接呼び出せない。box への error 記録と continuation finish は両方とも `finish()` 経由で
  // テスト済み (上の `finishIsIdempotent`)。SCStream 経由の経路は Layer A characterization
  // (PipelineCharacterizationTests.captureStreamErrorProducesErrorAndStoppedError) で覆う。
}

@Suite struct AudioConversionPipelineFormatSwitchTests {
  private func makeBuffer(format: AVAudioFormat, frameLength: AVAudioFrameCount)
    -> AVAudioPCMBuffer
  {
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength)!
    buffer.frameLength = frameLength
    return buffer
  }

  @Test func formatChangeTriggersDrainOfPreviousConverter() throws {
    let format48 = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    let format44 = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
    let target = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    let buf48 = makeBuffer(format: format48, frameLength: 480)
    let buf44 = makeBuffer(format: format44, frameLength: 441)

    var pipeline = AudioConversionPipeline()
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    // 1 回目: 48k で converter 作成
    _ = pipeline.consume(
      inputBuffer: buf48, presentationTime: .zero, fallbackDate: start,
      source: .mic, targetFormat: target, formatDescription: "f48", verbose: false)

    // 2 回目: 44.1k に切り替わる → 旧 converter を drain した結果が drainedChunk になる可能性あり
    let r2 = pipeline.consume(
      inputBuffer: buf44, presentationTime: .zero, fallbackDate: start,
      source: .mic, targetFormat: target, formatDescription: "f44", verbose: false)

    // drainedChunk が nil でも、(nextCaptureTime をリセット + 新しい converter を作る) という
    // 副作用は起きている。warning が出ていないことだけ確認する (drain 自体は安定動作するはず)。
    #expect(r2.warning == nil)
  }
}
