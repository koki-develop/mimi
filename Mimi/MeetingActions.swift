import MimiKit
import SwiftUI

/// The meeting actions offered both in the toolbar and in the menu bar.
extension MeetingSession {
    /// Starts the session with `summaryModel` when idle, and stops it when running. Does nothing while starting or
    /// stopping, so a repeated request that arrives before the controls are disabled cannot stop a session that is just
    /// starting.
    func toggleRunning(summaryModel: SummaryModel?) async {
        switch state {
        case .idle:
            guard let summaryModel else { return }
            await start(summaryModel: summaryModel)
        case .running:
            await stop()
        case .starting, .stopping:
            return
        }
    }

    /// Whether ``toggleRunning(summaryModel:)`` can be performed now: the session is running, or it is idle and has a
    /// summary model to start with.
    func canToggleRunning(summaryModel: SummaryModel?) -> Bool {
        switch state {
        case .idle: summaryModel != nil
        case .running: true
        case .starting, .stopping: false
        }
    }

    /// The name of the action ``toggleRunning(summaryModel:)`` performs.
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

extension SummaryModelStore {
    /// Explains why a meeting cannot start while no model is selected.
    static let selectionRequiredMessage = "会議を開始するには要約モデルを選択してください。"
}

struct MeetingCommands: Commands {
    let session: MeetingSession
    let summaryModels: SummaryModelStore

    var body: some Commands {
        CommandMenu("会議") {
            MeetingMenu(session: session, summaryModels: summaryModels)
        }
    }
}

/// A view, so that the menu follows the session and the selected model through observation.
private struct MeetingMenu: View {
    let session: MeetingSession
    let summaryModels: SummaryModelStore

    var body: some View {
        Button(session.toggleRunningTitle) {
            Task { await session.toggleRunning(summaryModel: summaryModels.selectedModel) }
        }
        .keyboardShortcut("r")
        .disabled(!session.canToggleRunning(summaryModel: summaryModels.selectedModel))

        Toggle(MeetingSession.muteTitle, isOn: session.microphoneMutedBinding)
            .keyboardShortcut("d")
    }
}
