import Foundation

public struct CapturedAudioChunk: Sendable, Equatable {
  public let source: AudioSource
  public let samples: [Float]
  public let captureTime: Date

  public init(source: AudioSource, samples: [Float], captureTime: Date) {
    self.source = source
    self.samples = samples
    self.captureTime = captureTime
  }
}
