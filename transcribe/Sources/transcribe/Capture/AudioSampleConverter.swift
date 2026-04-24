import AVFoundation
import Foundation

enum AudioSampleConverterError: Error {
  case incompatibleInputFormat
  case bufferAllocationFailed
  case conversionFailed(String)
}

final class AudioSampleConverter: @unchecked Sendable {
  let inputFormat: AVAudioFormat
  let outputFormat: AVAudioFormat

  private let converter: AVAudioConverter

  init?(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) {
    guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
      return nil
    }

    self.inputFormat = inputFormat
    self.outputFormat = outputFormat
    self.converter = converter
  }

  func convertStreaming(_ input: AVAudioPCMBuffer) throws -> [Float] {
    guard Self.isCompatible(input.format, with: inputFormat) else {
      throw AudioSampleConverterError.incompatibleInputFormat
    }

    let pendingInput = PendingInputBox(input)
    var collected: [Float] = []

    while true {
      let outputBuffer = try makeOutputBuffer(
        frameCapacity: Self.outputCapacity(
          inputFrameCount: Int(input.frameLength),
          inputSampleRate: inputFormat.sampleRate,
          outputSampleRate: outputFormat.sampleRate
        )
      )
      var error: NSError?

      let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
        if let currentInput = pendingInput.take() {
          outStatus.pointee = .haveData
          return currentInput
        }

        outStatus.pointee = .noDataNow
        return nil
      }

      if let error {
        throw AudioSampleConverterError.conversionFailed(error.localizedDescription)
      }

      collected.append(contentsOf: Self.floatSamples(from: outputBuffer))

      switch status {
      case .haveData:
        continue
      case .inputRanDry, .endOfStream:
        return collected
      case .error:
        throw AudioSampleConverterError.conversionFailed("converter returned error status")
      @unknown default:
        throw AudioSampleConverterError.conversionFailed("converter returned unknown status")
      }
    }
  }

  func finish() throws -> [Float] {
    var collected: [Float] = []

    while true {
      let outputBuffer = try makeOutputBuffer(frameCapacity: 4_096)
      var error: NSError?

      let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
        outStatus.pointee = .endOfStream
        return nil
      }

      if let error {
        throw AudioSampleConverterError.conversionFailed(error.localizedDescription)
      }

      collected.append(contentsOf: Self.floatSamples(from: outputBuffer))

      switch status {
      case .haveData:
        continue
      case .inputRanDry, .endOfStream:
        return collected
      case .error:
        throw AudioSampleConverterError.conversionFailed(
          "converter returned error status while draining")
      @unknown default:
        throw AudioSampleConverterError.conversionFailed(
          "converter returned unknown status while draining")
      }
    }
  }

  private func makeOutputBuffer(frameCapacity: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
    guard
      let outputBuffer = AVAudioPCMBuffer(
        pcmFormat: outputFormat,
        frameCapacity: frameCapacity
      )
    else {
      throw AudioSampleConverterError.bufferAllocationFailed
    }

    return outputBuffer
  }

  private static func outputCapacity(
    inputFrameCount: Int,
    inputSampleRate: Double,
    outputSampleRate: Double
  ) -> AVAudioFrameCount {
    let ratio = outputSampleRate / inputSampleRate
    let scaled = ceil(Double(inputFrameCount) * ratio)
    return AVAudioFrameCount(max(scaled + 256, 1))
  }

  private static func isCompatible(_ lhs: AVAudioFormat, with rhs: AVAudioFormat) -> Bool {
    lhs.commonFormat == rhs.commonFormat
      && lhs.sampleRate == rhs.sampleRate
      && lhs.channelCount == rhs.channelCount
      && lhs.isInterleaved == rhs.isInterleaved
  }

  private static func floatSamples(from pcmBuffer: AVAudioPCMBuffer) -> [Float] {
    guard let channelData = pcmBuffer.floatChannelData else { return [] }
    let frameLength = Int(pcmBuffer.frameLength)
    return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
  }
}

private final class PendingInputBox: @unchecked Sendable {
  private let lock = NSLock()
  private var buffer: AVAudioPCMBuffer?

  init(_ buffer: AVAudioPCMBuffer?) {
    self.buffer = buffer
  }

  func take() -> AVAudioPCMBuffer? {
    lock.lock()
    defer { lock.unlock() }

    let currentBuffer = buffer
    buffer = nil
    return currentBuffer
  }
}
