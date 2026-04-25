import AVFoundation
import Foundation
import Testing

@testable import TranscribeCore

/// `AudioConversionPipeline` 単体ユニットテスト。
/// converter 詳細 (drain, format 切り替え) は `AudioSampleConverterTests` が
/// `AudioConversionPipeline` 経由で被覆しているので、ここではエッジケースのみ。
@Suite struct AudioConversionPipelineTests {
  private func makeBuffer(format: AVAudioFormat, frameLength: AVAudioFrameCount) -> AVAudioPCMBuffer
  {
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength)!
    buffer.frameLength = frameLength
    return buffer
  }

  @Test func firstConsumeWithVerboseEmitsFormatLog() {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 16_000,
      channels: 1,
      interleaved: false
    )!
    let buffer = makeBuffer(format: format, frameLength: 16)
    var pipeline = AudioConversionPipeline()

    let result = pipeline.consume(
      inputBuffer: buffer,
      presentationTime: .zero,
      fallbackDate: Date(),
      source: .mic,
      targetFormat: format,
      formatDescription: "16000Hz, 1ch, format=1",
      verbose: true
    )

    #expect(result.firstFormatLog?.contains("[debug] first mic buffer") == true)
  }

  @Test func secondConsumeWithVerboseDoesNotEmitFormatLog() {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 16_000,
      channels: 1,
      interleaved: false
    )!
    let buffer = makeBuffer(format: format, frameLength: 16)
    var pipeline = AudioConversionPipeline()

    _ = pipeline.consume(
      inputBuffer: buffer, presentationTime: .zero, fallbackDate: Date(),
      source: .system, targetFormat: format, formatDescription: "x", verbose: true)

    let secondResult = pipeline.consume(
      inputBuffer: buffer, presentationTime: .zero, fallbackDate: Date(),
      source: .system, targetFormat: format, formatDescription: "x", verbose: true)
    #expect(secondResult.firstFormatLog == nil)
  }

  @Test func nonVerboseNeverEmitsFormatLog() {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 16_000,
      channels: 1,
      interleaved: false
    )!
    let buffer = makeBuffer(format: format, frameLength: 16)
    var pipeline = AudioConversionPipeline()

    let result = pipeline.consume(
      inputBuffer: buffer, presentationTime: .zero, fallbackDate: Date(),
      source: .mic, targetFormat: format, formatDescription: "x", verbose: false)
    #expect(result.firstFormatLog == nil)
  }

  @Test func finishWithoutConsumerYieldsNothing() {
    var pipeline = AudioConversionPipeline()
    let result = pipeline.finish(source: .mic)
    #expect(result.warning == nil)
    #expect(result.chunk == nil)
  }
}
