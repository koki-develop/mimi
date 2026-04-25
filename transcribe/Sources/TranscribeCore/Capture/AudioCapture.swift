import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

public enum AudioCaptureError: Error, Equatable {
  case noDisplayAvailable
  case streamSetupFailed(String)
}

public actor AudioCapture {
  public nonisolated let micStream: AsyncStream<CapturedAudioChunk>
  public nonisolated let systemStream: AsyncStream<CapturedAudioChunk>
  public nonisolated let diagnosticStream: AsyncStream<CaptureDiagnostic>

  private let micContinuation: AsyncStream<CapturedAudioChunk>.Continuation
  private let systemContinuation: AsyncStream<CapturedAudioChunk>.Continuation
  private let diagnosticContinuation: AsyncStream<CaptureDiagnostic>.Continuation
  private let verbose: Bool
  private let sessionStart = SessionStartTracker()
  private let streamErrorBox = StreamErrorBox()

  private var stream: SCStream?
  private var micOutput: AudioOutputTap?
  private var systemOutput: AudioOutputTap?
  private var delegate: SCStreamCoordinator?

  /// Delegate が `SCStreamDelegate.stream(_:didStopWithError:)` を受けた際に記録した
  /// エラーを取り出す(取り出し時にクリア)。consume が drain した後に App 側で
  /// `error` イベントとして emit するために使う。
  public nonisolated func takeStreamError() -> Error? {
    streamErrorBox.take()
  }

  public init(verbose: Bool = false) {
    var micContinuation: AsyncStream<CapturedAudioChunk>.Continuation!
    var systemContinuation: AsyncStream<CapturedAudioChunk>.Continuation!
    var diagnosticContinuation: AsyncStream<CaptureDiagnostic>.Continuation!
    self.micStream = AsyncStream(bufferingPolicy: .unbounded) { micContinuation = $0 }
    self.systemStream = AsyncStream(bufferingPolicy: .unbounded) { systemContinuation = $0 }
    self.diagnosticStream = AsyncStream(bufferingPolicy: .unbounded) {
      diagnosticContinuation = $0
    }
    self.micContinuation = micContinuation
    self.systemContinuation = systemContinuation
    self.diagnosticContinuation = diagnosticContinuation
    self.verbose = verbose
  }

  public func start() async throws {
    let content: SCShareableContent
    do {
      content = try await SCShareableContent.current
    } catch {
      throw AudioCaptureError.streamSetupFailed("failed to query shareable content: \(error)")
    }

    guard let display = content.displays.first else {
      throw AudioCaptureError.noDisplayAvailable
    }

    let filter = SCContentFilter(
      display: display,
      excludingApplications: [],
      exceptingWindows: []
    )

    let config = SCStreamConfiguration()
    config.capturesAudio = true
    // The stream is configured to Whisper's native 16kHz mono target so
    // ScreenCaptureKit can downsample system audio for us. Microphone
    // capture still arrives in the device's native format; each output
    // handler performs its own streaming sample-rate conversion.
    config.sampleRate = 16_000
    config.channelCount = 1
    config.captureMicrophone = true
    if let micID = AVCaptureDevice.default(for: .audio)?.uniqueID {
      config.microphoneCaptureDeviceID = micID
    }
    // SCStream requires a minimal video configuration even when we only
    // consume audio. A 2x2 @ 1fps stream is sufficient and no video output
    // is registered, so the frames are discarded internally.
    config.width = 2
    config.height = 2
    config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

    let micOutput = AudioOutputTap(
      source: .mic,
      continuation: micContinuation,
      diagnosticContinuation: diagnosticContinuation,
      verbose: verbose,
      sessionStart: sessionStart
    )
    let systemOutput = AudioOutputTap(
      source: .system,
      continuation: systemContinuation,
      diagnosticContinuation: diagnosticContinuation,
      verbose: verbose,
      sessionStart: sessionStart
    )
    let delegate = SCStreamCoordinator(
      streamErrorBox: streamErrorBox,
      micOutput: micOutput,
      systemOutput: systemOutput,
      micContinuation: micContinuation,
      systemContinuation: systemContinuation,
      diagnosticContinuation: diagnosticContinuation
    )

    let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
    do {
      try stream.addStreamOutput(
        systemOutput,
        type: .audio,
        sampleHandlerQueue: systemOutput.queue
      )
      try stream.addStreamOutput(
        micOutput,
        type: .microphone,
        sampleHandlerQueue: micOutput.queue
      )
    } catch {
      delegate.finish()
      throw AudioCaptureError.streamSetupFailed("failed to add stream outputs: \(error)")
    }

    self.micOutput = micOutput
    self.systemOutput = systemOutput
    self.delegate = delegate
    self.stream = stream

    do {
      sessionStart.markRequested(at: Date())
      try await stream.startCapture()
    } catch {
      delegate.finish()
      self.stream = nil
      self.micOutput = nil
      self.systemOutput = nil
      self.delegate = nil
      throw AudioCaptureError.streamSetupFailed("failed to start capture: \(error)")
    }
  }

  public func stop() async {
    if let stream {
      try? await stream.stopCapture()
    }

    micOutput?.finish()
    systemOutput?.finish()

    stream = nil
    micOutput = nil
    systemOutput = nil
    delegate = nil
    micContinuation.finish()
    systemContinuation.finish()
    diagnosticContinuation.finish()
  }

  public func startedAt() -> Date {
    sessionStart.startedAt ?? Date()
  }

}
