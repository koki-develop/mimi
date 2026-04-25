import Foundation

/// 1 source 分の `CapturedAudioChunk` の入力ストリームを `Segment` の出力ストリームに変換する。
/// production では `Transcriber` actor が conform、テストでは fake を差し替える。
public protocol TranscriberProtocol: Sendable {
  func consume(_ input: AsyncStream<CapturedAudioChunk>) -> AsyncStream<Segment>
}
