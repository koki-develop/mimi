import Foundation

struct TimedAudioWindow: Sendable, Equatable {
  let startTime: Date
  let samples: [Float]
}

struct TimedSampleAccumulator: Sendable {
  private let sampleRate: Double
  private let timingTolerance: TimeInterval

  private var buffer: ArraySlice<Float> = []
  private var bufferStartTime: Date?

  init(sampleRate: Double, timingTolerance: TimeInterval? = nil) {
    self.sampleRate = sampleRate
    self.timingTolerance = timingTolerance ?? (0.5 / sampleRate)
  }

  mutating func append(_ chunk: CapturedAudioChunk) {
    guard !chunk.samples.isEmpty else { return }

    if buffer.isEmpty {
      buffer = ArraySlice(chunk.samples)
      bufferStartTime = chunk.captureTime
      return
    }

    var incomingStartTime = chunk.captureTime
    var incomingSamples = ArraySlice(chunk.samples)

    alignBuffer(
      incomingStartTime: &incomingStartTime,
      incomingSamples: &incomingSamples
    )
    guard !incomingSamples.isEmpty else { return }

    buffer.append(contentsOf: incomingSamples)
    compactStorageIfNeeded()
  }

  mutating func popWindow(sampleCount: Int) -> TimedAudioWindow? {
    guard sampleCount > 0, buffer.count >= sampleCount, let bufferStartTime else {
      return nil
    }

    let samples = Array(buffer.prefix(sampleCount))
    buffer = buffer.dropFirst(sampleCount)

    let nextStart = bufferStartTime.addingTimeInterval(Double(sampleCount) / sampleRate)
    self.bufferStartTime = buffer.isEmpty ? nil : nextStart
    compactStorageIfNeeded()

    return TimedAudioWindow(startTime: bufferStartTime, samples: samples)
  }

  mutating func finish() -> TimedAudioWindow? {
    guard let bufferStartTime, !buffer.isEmpty else { return nil }

    let window = TimedAudioWindow(startTime: bufferStartTime, samples: Array(buffer))
    buffer = []
    self.bufferStartTime = nil
    return window
  }

  private mutating func alignBuffer(
    incomingStartTime: inout Date,
    incomingSamples: inout ArraySlice<Float>
  ) {
    guard let bufferStartTime else {
      self.bufferStartTime = incomingStartTime
      return
    }

    let expectedNextSampleTime = bufferStartTime.addingTimeInterval(
      Double(buffer.count) / sampleRate)
    let delta = incomingStartTime.timeIntervalSince(expectedNextSampleTime)

    if delta > timingTolerance {
      let missingSamples = Int((delta * sampleRate).rounded())
      if missingSamples > 0 {
        buffer.append(contentsOf: repeatElement(Float.zero, count: missingSamples))
      }
      return
    }

    if delta < -timingTolerance {
      let overlappingSamples = Int(((-delta) * sampleRate).rounded())
      if overlappingSamples > 0 {
        if overlappingSamples >= incomingSamples.count {
          incomingSamples = []
          return
        }

        incomingSamples = incomingSamples.dropFirst(overlappingSamples)
        incomingStartTime = incomingStartTime.addingTimeInterval(
          Double(overlappingSamples) / sampleRate
        )
      }
    }
  }

  private mutating func compactStorageIfNeeded() {
    guard buffer.startIndex > 16_384, buffer.startIndex > buffer.count else {
      return
    }

    buffer = ArraySlice(buffer)
  }
}
