import SwiftUI

@main
struct MimiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Mimi", id: "main") {
            ContentView(session: appDelegate.session)
        }
        .defaultSize(width: 380, height: 560)

        Settings {
            SettingsView()
        }
    }
}
