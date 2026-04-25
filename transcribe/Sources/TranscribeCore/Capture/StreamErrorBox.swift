import Foundation

/// `SCStreamDelegate.stream(_:didStopWithError:)` で捕捉した最初のエラーを
/// 同期的に保存するためのロック付きストレージ。Delegate のコールバックは
/// actor 外の dispatch キューから呼ばれるため、actor hop を介さずに記録できる
/// 必要がある。
final class StreamErrorBox: @unchecked Sendable {
  private let lock = NSLock()
  private var error: Error?

  func trySet(_ err: Error) {
    lock.lock()
    defer { lock.unlock() }
    if error == nil { error = err }
  }

  func take() -> Error? {
    lock.lock()
    defer { lock.unlock() }
    let taken = error
    error = nil
    return taken
  }
}
