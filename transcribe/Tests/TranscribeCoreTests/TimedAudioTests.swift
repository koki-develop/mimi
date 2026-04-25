import CoreMedia
import Foundation
import Testing

@testable import TranscribeCore

@Suite struct TimedAudioTests {
  @Test func sampleBufferClockMapsRelativePTSIntoWallClockDates() {
    var mapper = SampleBufferClockMapper()
    let anchorNow = Date(timeIntervalSince1970: 1_700_000_000)

    let first = mapper.captureTime(
      for: CMTime(seconds: 120, preferredTimescale: 600),
      fallbackDate: anchorNow
    )
    let second = mapper.captureTime(
      for: CMTime(seconds: 121.5, preferredTimescale: 600),
      fallbackDate: anchorNow.addingTimeInterval(10)
    )

    #expect(first == anchorNow)
    #expect(abs(second.timeIntervalSince(anchorNow.addingTimeInterval(1.5))) < 0.000_1)
  }

  @Test func sampleAccumulatorUsesChunkCaptureTimeForWindowStart() {
    var accumulator = TimedSampleAccumulator(sampleRate: 16_000)
    let chunkStart = Date(timeIntervalSince1970: 1_700_000_010)

    accumulator.append(
      CapturedAudioChunk(
        source: .mic,
        samples: Array(repeating: 0.25, count: 80_000),
        captureTime: chunkStart
      ))

    let window = accumulator.popWindow(sampleCount: 80_000)

    #expect(window != nil)
    #expect(window?.samples.count == 80_000)
    #expect(window?.startTime == chunkStart)
  }

  @Test func sampleAccumulatorInsertsSilenceAcrossTimingGaps() {
    var accumulator = TimedSampleAccumulator(sampleRate: 16_000)
    let start = Date(timeIntervalSince1970: 1_700_000_100)

    accumulator.append(
      CapturedAudioChunk(
        source: .system,
        samples: Array(repeating: 1, count: 1_600),
        captureTime: start
      ))
    accumulator.append(
      CapturedAudioChunk(
        source: .system,
        samples: Array(repeating: 2, count: 1_600),
        captureTime: start.addingTimeInterval(0.2)
      ))

    let window = accumulator.finish()

    #expect(window != nil)
    #expect(window?.startTime == start)
    #expect(window?.samples.count == 4_800)
    #expect(window?.samples[1_600] == 0)
    #expect(window?.samples[1_601] == 0)
    #expect(window?.samples[1_599] == 1)
    #expect(window?.samples[4_799] == 2)
  }

  @Test func sampleAccumulatorTrimsOverlappingAudio() {
    var accumulator = TimedSampleAccumulator(sampleRate: 16_000)
    let start = Date(timeIntervalSince1970: 1_700_000_200)

    accumulator.append(
      CapturedAudioChunk(
        source: .mic,
        samples: Array(repeating: 1, count: 1_600),
        captureTime: start
      ))
    accumulator.append(
      CapturedAudioChunk(
        source: .mic,
        samples: Array(repeating: 2, count: 1_600),
        captureTime: start.addingTimeInterval(0.05)
      ))

    let window = accumulator.finish()

    #expect(window != nil)
    #expect(window?.samples.count == 2_400)
    #expect(window?.samples[1_599] == 1)
    #expect(window?.samples[1_600] == 2)
  }
}
