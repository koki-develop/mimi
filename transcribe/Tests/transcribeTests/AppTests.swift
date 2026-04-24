import Foundation
import Testing
@testable import transcribe

@Suite struct AppTests {
    @Test func streamErrorOverridesSigintReason() {
        // 予期せぬ stream エラーが記録されていた場合、SIGINT より優先して `.error` になる
        #expect(App.resolvedStopReason(streamErrorPresent: true, trackerReason: .sigint) == .error)
    }

    @Test func streamErrorWhenAlreadyErrorStaysError() {
        #expect(App.resolvedStopReason(streamErrorPresent: true, trackerReason: .error) == .error)
    }

    @Test func sigintReasonPreservedWhenNoStreamError() {
        #expect(App.resolvedStopReason(streamErrorPresent: false, trackerReason: .sigint) == .sigint)
    }

    @Test func errorReasonPreservedWhenNoStreamError() {
        #expect(App.resolvedStopReason(streamErrorPresent: false, trackerReason: .error) == .error)
    }
}
