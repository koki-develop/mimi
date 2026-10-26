import AppKit
import SwiftUI

/// Applies AppKit-only window settings to the window hosting this view.
struct WindowConfigurator: NSViewRepresentable {
    let isAlwaysOnTop: Bool
    let onClose: () -> Void

    func makeNSView(context: Context) -> ConfiguringView {
        ConfiguringView()
    }

    func updateNSView(_ view: ConfiguringView, context: Context) {
        view.isAlwaysOnTop = isAlwaysOnTop
        view.onClose = onClose
    }

    final class ConfiguringView: NSView {
        var isAlwaysOnTop = false {
            didSet { apply() }
        }
        var onClose: () -> Void = {}
        private var closeObserver: (any NSObjectProtocol)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let closeObserver {
                NotificationCenter.default.removeObserver(closeObserver)
                self.closeObserver = nil
            }
            if let window {
                closeObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onClose() }
                }
            }
            apply()
        }

        private func apply() {
            guard let window else { return }
            // Not honored by every capture method; macOS gives no guarantee here.
            window.sharingType = .none
            window.level = isAlwaysOnTop ? .floating : .normal
        }
    }
}
