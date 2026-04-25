import Foundation

/// `EventSink` の production 実装。`FileHandle.standardOutput` に
/// 1 イベント = 1 行 JSON で書き込む。Daemon の wire protocol
/// (docs/superpowers/specs/2026-04-25-transcribe-daemon-design.md §3.2)
/// の出力側の唯一の経路。
///
/// `close()` は内部の handle 参照を nil 化するだけで、`FileHandle.standardOutput` 自体は
/// クローズしない (アプリ全体のライフサイクルが管理する)。
public actor StdoutEventWriter: EventSink {
  private var handle: FileHandle?

  public init(handle: FileHandle = .standardOutput) {
    self.handle = handle
  }

  public func write(_ event: Event) async throws {
    guard let handle else {
      throw StdoutEventWriterError.closed
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
    let data = try encoder.encode(event) + Data([0x0A])
    try handle.write(contentsOf: data)
    // 注: ここで `handle.synchronize()` を呼ばないのは、stdout / pipe / terminal の
    // ような non-seekable file descriptor では fsync が EINVAL を返すため。
    // `FileHandle.write(contentsOf:)` 自体が write(2) を直接呼ぶので、すでに
    // OS レベルの行バッファに乗っており、daemon の stream 出力としては十分。
  }

  public func close() async throws {
    // standardOutput を実際に close する責任は持たない (アプリ全体のライフサイクルが管理)。
    // handle 参照を nil 化して以降の write を `closed` にするだけ。
    self.handle = nil
  }
}

public enum StdoutEventWriterError: Error, Equatable {
  case closed
}
