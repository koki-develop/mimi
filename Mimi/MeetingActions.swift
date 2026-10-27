import MimiKit
import SwiftUI

/// The meeting actions offered both in the toolbar and in the menu bar.
extension MeetingSession {
    /// Starts the session when idle, and stops it when running. Does nothing while starting or stopping, so a
    /// repeated request that arrives before the controls are disabled cannot stop a session that is just starting.
    func toggleRunning(summaryModelID: String) async {
        guard canToggleRunning else { return }
        if state == .idle {
            await start(summaryModelID: summaryModelID)
        } else {
            await stop()
        }
    }

    /// Whether ``toggleRunning(summaryModelID:)`` can be performed now, i.e. the session is not starting or stopping.
    var canToggleRunning: Bool {
        state == .idle || state == .running
    }

    /// The name of the action ``toggleRunning(summaryModelID:)`` performs.
    var toggleRunningTitle: String {
        switch state {
        case .idle, .starting: "開始"
        case .running, .stopping: "停止"
        }
    }

    var microphoneMutedBinding: Binding<Bool> {
        Binding(
            get: { self.isMicrophoneMuted },
            set: { self.setMicrophoneMuted($0) }
        )
    }

    static let muteTitle = "\(Speaker.me.displayName)の音声をミュート"
}

struct MeetingCommands: Commands {
    let session: MeetingSession

    var body: some Commands {
        CommandMenu("会議") {
            MeetingMenu(session: session)
        }
    }
}

/// A view, so that the menu follows the session through observation.
private struct MeetingMenu: View {
    let session: MeetingSession
    @AppStorage(SettingsKey.summaryModelID) private var summaryModelID = SettingsDefault.summaryModelID

    var body: some View {
        Button(session.toggleRunningTitle) {
            Task { await session.toggleRunning(summaryModelID: summaryModelID) }
        }
        .keyboardShortcut("r")
        .disabled(!session.canToggleRunning)

        Toggle(MeetingSession.muteTitle, isOn: session.microphoneMutedBinding)
            .keyboardShortcut("d")
    }
}
