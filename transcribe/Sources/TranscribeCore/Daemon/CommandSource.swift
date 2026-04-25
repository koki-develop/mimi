import Darwin
import Foundation

/// `CommandSource.stream()` 1 要素分の dispatch 結果。
public enum CommandSourceItem: Sendable, Equatable {
  case command(DaemonCommand)
  case parseError(rawLine: String)
}

/// stdin (FileHandle) から line-delimited JSON を読み、`DaemonCommand` を yield する。
/// 1 行 = 1 イベント。EOF (handle close) で stream が終了する。
public struct CommandSource: Sendable {
  private let handle: FileHandle

  public init(handle: FileHandle = .standardInput) {
    self.handle = handle
  }

  public func stream() -> AsyncStream<CommandSourceItem> {
    let fd = self.handle.fileDescriptor
    return AsyncStream(bufferingPolicy: .unbounded) { continuation in
      Task.detached {
        // 注: ここで `FileHandle.read(upToCount:)` を使うと、POLLIN が立っている
        // (kernel レベルで pipe にデータが既に届いている) 状況でも read が返らない
        // ケースが Swift 6.0 / macOS 26.x で再現する。Apple DTS engineer も
        // FileHandle の I/O は避けて Dispatch I/O か raw syscall を勧めている
        // (https://developer.apple.com/forums/thread/690382)。
        // 本コードはそのため `Darwin.read(2)` を直接叩く。
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var partial: [UInt8] = []
        while true {
          let n = Darwin.read(fd, buffer, bufferSize)
          if n < 0 {
            let err = errno
            if err == EINTR { continue }
            FileHandle.standardError.write(
              "[CommandSource] stdin read error: errno=\(err) (\(String(cString: strerror(err))))\n"
                .data(using: .utf8) ?? Data())
            continuation.finish()
            return
          }
          if n == 0 {
            // EOF — stdin closed. Discard any incomplete trailing line.
            continuation.finish()
            return
          }
          partial.append(contentsOf: UnsafeBufferPointer(start: buffer, count: n))

          while let nlIdx = partial.firstIndex(of: 0x0A) {
            let lineBytes = Array(partial[..<nlIdx])
            partial.removeSubrange(...nlIdx)
            // CR を末尾から trim
            let trimmed = lineBytes.last == 0x0D ? Array(lineBytes.dropLast()) : lineBytes
            if trimmed.isEmpty { continue }
            let raw = String(decoding: trimmed, as: UTF8.self)
            if let cmd = try? JSONDecoder().decode(DaemonCommand.self, from: Data(trimmed)) {
              continuation.yield(.command(cmd))
            } else {
              continuation.yield(.parseError(rawLine: raw))
            }
          }
        }
      }
    }
  }
}
