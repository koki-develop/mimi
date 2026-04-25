import AVFoundation
import Foundation
import Testing

@testable import TranscribeCore

@Suite struct AudioSampleConverterTests {
  @Test func resamplesStreamingPCMInputIntoTargetFormat() throws {
    let sourceFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 48_000,
      channels: 1,
      interleaved: false
    )!
    let targetFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 16_000,
      channels: 1,
      interleaved: false
    )!
    let input = try #require(
      makeInputBuffer(
        format: sourceFormat,
        frameLength: 4_800
      ))
    let converter = try #require(
      AudioSampleConverter(
        inputFormat: sourceFormat,
        outputFormat: targetFormat
      ))

    let streamingOutput = try converter.convertStreaming(input)
    let drainedOutput = try converter.finish()

    #expect(!streamingOutput.isEmpty)
    #expect(streamingOutput.count + drainedOutput.count == 1_600)
  }

  @Test func drainingFirstOutputStillProducesChunkWithCaptureTime() throws {
    let sourceFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 48_000,
      channels: 1,
      interleaved: false
    )!
    let targetFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 16_000,
      channels: 1,
      interleaved: false
    )!
    let input = try #require(
      makeInputBuffer(
        format: sourceFormat,
        frameLength: 2
      ))

    var state = AudioConversionPipeline(
      converter: AudioSampleConverter(
        inputFormat: sourceFormat,
        outputFormat: targetFormat
      )!,
      inputFormat: sourceFormat
    )
    let start = Date(timeIntervalSince1970: 1_700_000_300)

    let consumeResult = state.consume(
      inputBuffer: input,
      presentationTime: .zero,
      fallbackDate: start,
      source: .mic,
      targetFormat: targetFormat,
      formatDescription: "test",
      verbose: false
    )
    #expect(consumeResult.convertedChunk == nil)

    let finishResult = state.finish(source: .mic)

    #expect(finishResult.warning == nil)
    #expect(finishResult.chunk != nil)
    #expect(finishResult.chunk?.captureTime == start)
    #expect(finishResult.chunk?.samples.count == 1)
  }

  @Test func firstVisibleOutputKeepsEarliestBufferedCaptureTime() throws {
    let sourceFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 48_000,
      channels: 1,
      interleaved: false
    )!
    let targetFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 16_000,
      channels: 1,
      interleaved: false
    )!
    let first = try #require(makeInputBuffer(format: sourceFormat, frameLength: 2))
    let second = try #require(makeInputBuffer(format: sourceFormat, frameLength: 18))

    var state = AudioConversionPipeline(
      converter: AudioSampleConverter(
        inputFormat: sourceFormat,
        outputFormat: targetFormat
      )!,
      inputFormat: sourceFormat
    )
    let start = Date(timeIntervalSince1970: 1_700_000_400)
    let later = start.addingTimeInterval(0.01)

    let firstResult = state.consume(
      inputBuffer: first,
      presentationTime: .zero,
      fallbackDate: start,
      source: .mic,
      targetFormat: targetFormat,
      formatDescription: "test",
      verbose: false
    )
    #expect(firstResult.convertedChunk == nil)

    let secondResult = state.consume(
      inputBuffer: second,
      presentationTime: CMTime(seconds: 0.01, preferredTimescale: 600),
      fallbackDate: later,
      source: .mic,
      targetFormat: targetFormat,
      formatDescription: "test",
      verbose: false
    )

    #expect(secondResult.warning == nil)
    #expect(secondResult.convertedChunk != nil)
    #expect(secondResult.convertedChunk?.captureTime == start)
  }

  private func makeInputBuffer(
    format: AVAudioFormat,
    frameLength: AVAudioFrameCount
  ) -> AVAudioPCMBuffer? {
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength),
      let channelData = buffer.floatChannelData
    else {
      return nil
    }
    buffer.frameLength = frameLength
    for index in 0..<Int(frameLength) {
      channelData[0][index] = sin(Float(index) / 32)
    }
    return buffer
  }
}
