import Foundation
import Testing
@testable import transcribe

@Suite struct AudioCaptureTests {
    @Test func outputHandlerQueueLabelUsesExpectedBundleIdentifierPrefix() {
        let reporter = ConsoleReporter(stream: StringStream())
        let tracker = AudioCapture.SessionStartTracker()
        let continuation = AsyncStream<CapturedAudioChunk>.makeStream().continuation

        let micOutput = AudioCapture.OutputHandler(
            source: .mic,
            continuation: continuation,
            reporter: reporter,
            verbose: false,
            sessionStart: tracker
        )

        #expect(micOutput.queue.label == "me.koki.transcribe.capture.mic")
    }
}

private struct StringStream: TextOutputStream, Sendable {
    mutating func write(_ string: String) {}
}
