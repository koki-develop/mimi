import SwiftUI

@main
struct MimiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Mimi", id: "main") {
            ContentView(session: appDelegate.session, summaryModels: appDelegate.summaryModels)
        }
        .defaultSize(MainWindow.defaultSize)
        .windowResizability(.contentMinSize)
        .commands {
            MeetingCommands(session: appDelegate.session, summaryModels: appDelegate.summaryModels)
        }

        Settings {
            SettingsView(summaryModels: appDelegate.summaryModels)
        }
    }
}

enum MainWindow {
    static let defaultSize = CGSize(width: 380, height: 560)
}
