import Darwin
import Dispatch
import Foundation

public enum SignalHandler {
  /// SIGINT が届くまで待機する。Task がキャンセルされた場合も直ちに復帰する。
  public static func waitForSIGINT() async {
    // Default SIGINT 挙動（プロセス即終了）を抑止して DispatchSource に渡す。
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())

    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        // DispatchSource の event handler が 1 回だけ resume するよう protect
        let resumer = OneShotResumer(continuation: continuation)
        source.setEventHandler {
          resumer.resume()
        }
        source.setCancelHandler {
          resumer.resume()
        }
        source.resume()
      }
    } onCancel: {
      source.cancel()
    }
  }

  private final class OneShotResumer: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private let continuation: CheckedContinuation<Void, Never>

    init(continuation: CheckedContinuation<Void, Never>) {
      self.continuation = continuation
    }

    func resume() {
      lock.lock()
      let shouldResume = !resumed
      resumed = true
      lock.unlock()
      if shouldResume {
        continuation.resume()
      }
    }
  }
}
