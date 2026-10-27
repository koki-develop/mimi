import AppKit
import SwiftUI

/// Applies AppKit-only window settings to the window hosting this view.
struct WindowConfigurator: NSViewRepresentable {
    let isAlwaysOnTop: Bool
    let hidesFromScreenCapture: Bool
    /// The height of the content below the toolbar while the transcript is collapsed, or `nil` while it is expanded.
    /// While collapsed, the window fits this height and cannot be resized vertically.
    let collapsedContentHeight: CGFloat?
    let onClose: () -> Void

    func makeNSView(context: Context) -> ConfiguringView {
        ConfiguringView()
    }

    func updateNSView(_ view: ConfiguringView, context: Context) {
        view.onClose = onClose
        view.update(isAlwaysOnTop: isAlwaysOnTop, hidesFromScreenCapture: hidesFromScreenCapture, collapsedContentHeight: collapsedContentHeight)
    }

    final class ConfiguringView: NSView {
        var onClose: () -> Void = {}
        private var isAlwaysOnTop = false
        private var hidesFromScreenCapture = false
        private var collapsedContentHeight: CGFloat?
        /// Whether the window currently has the collapsed layout. `nil` until a layout has been applied.
        private var isCollapsedLayoutApplied: Bool?
        private var closeObserver: (any NSObjectProtocol)?

        func update(isAlwaysOnTop: Bool, hidesFromScreenCapture: Bool, collapsedContentHeight: CGFloat?) {
            self.isAlwaysOnTop = isAlwaysOnTop
            self.hidesFromScreenCapture = hidesFromScreenCapture
            self.collapsedContentHeight = collapsedContentHeight
            apply()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let closeObserver {
                NotificationCenter.default.removeObserver(closeObserver)
                self.closeObserver = nil
            }
            isCollapsedLayoutApplied = nil
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
            // Apple documents `.none` as a legacy value that is not a way to keep content from being captured,
            // and only some capture methods honor it. No supported API hides ordinary window content.
            window.sharingType = hidesFromScreenCapture ? .none : .readOnly
            window.level = isAlwaysOnTop ? .floating : .normal
            applyHeight(to: window)
        }

        private func applyHeight(to window: NSWindow) {
            let defaults = UserDefaults.standard
            if let collapsedContentHeight {
                // Waits for the collapsed content to be measured.
                guard collapsedContentHeight > 0 else { return }
                if isCollapsedLayoutApplied == false {
                    defaults.set(Double(window.frame.height), forKey: SettingsKey.expandedWindowHeight)
                }
                let toolbarHeight = window.frame.height - window.contentLayoutRect.height
                let height = collapsedContentHeight + toolbarHeight
                window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: height)
                setHeight(height, of: window, animated: isCollapsedLayoutApplied != nil)
                isCollapsedLayoutApplied = true
            } else {
                window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                if isCollapsedLayoutApplied == true {
                    let storedHeight = defaults.double(forKey: SettingsKey.expandedWindowHeight)
                    let height = storedHeight > 0 ? CGFloat(storedHeight) : MainWindow.defaultSize.height
                    setHeight(max(height, window.minSize.height), of: window, animated: true)
                }
                isCollapsedLayoutApplied = false
            }
        }

        /// Resizes the window vertically, keeping its top edge in place.
        private func setHeight(_ height: CGFloat, of window: NSWindow, animated: Bool) {
            var frame = window.frame
            guard abs(frame.height - height) >= 0.5 else { return }
            frame.origin.y = frame.maxY - height
            frame.size.height = height
            // While the user resizes the window, the height follows each step directly rather than animating
            // against the drag.
            if animated, !window.inLiveResize {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    window.animator().setFrame(frame, display: true)
                }
            } else {
                window.setFrame(frame, display: true)
            }
        }
    }
}
