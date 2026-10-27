import AppKit
import MimiKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let summaryModels: SummaryModelStore
    let session: MeetingSession

    override init() {
        summaryModels = .live()
        session = .live(summaryModels: summaryModels)
        super.init()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard session.state != .idle else { return .terminateNow }
        Task {
            await session.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
