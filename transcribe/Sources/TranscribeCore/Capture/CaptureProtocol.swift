import Foundation

/// `AudioCapture` の test 用抽象境界。
/// production では `AudioCapture` actor が conform、テストでは `FakeCapture` 等を差し替える。
public protocol CaptureProtocol: AnyObject, Sendable {
  var micStream: AsyncStream<CapturedAudioChunk> { get }
  var systemStream: AsyncStream<CapturedAudioChunk> { get }
  var diagnosticStream: AsyncStream<CaptureDiagnostic> { get }
  func start() async throws
  func stop() async
  func takeStreamError() -> Error?
}

extension AudioCapture: CaptureProtocol {}
