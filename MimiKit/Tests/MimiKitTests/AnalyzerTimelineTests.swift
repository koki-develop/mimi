@testable import MimiKit
import Testing

struct AnalyzerTimelineTests {
    @Test func firstCaptureIsDiscontinuous() {
        var timeline = AnalyzerTimeline(origin: 100)
        let isDiscontinuous = timeline.registerCapture(at: 100.5, duration: 0.1)
        #expect(isDiscontinuous)
        #expect(timeline.startTime(forRunCapturedAt: 100.5) == 0.5)
    }

    @Test func consecutiveCapturesAreContinuous() {
        var timeline = AnalyzerTimeline(origin: 0)
        _ = timeline.registerCapture(at: 1, duration: 0.1)
        let exact = timeline.registerCapture(at: 1.1, duration: 0.1)
        let withinTolerance = timeline.registerCapture(at: 1.2 + AnalyzerTimeline.continuityTolerance / 2, duration: 0.1)
        #expect(!exact)
        #expect(!withinTolerance)
    }

    @Test func gapBeyondToleranceIsDiscontinuous() {
        var timeline = AnalyzerTimeline(origin: 0)
        _ = timeline.registerCapture(at: 1, duration: 0.1)
        let isDiscontinuous = timeline.registerCapture(at: 1.1 + AnalyzerTimeline.continuityTolerance * 2, duration: 0.1)
        #expect(isDiscontinuous)
    }

    @Test func runStartNeverPrecedesSuppliedAudio() {
        var timeline = AnalyzerTimeline(origin: 0)
        timeline.registerAnalyzerInput(start: 1, duration: 2)
        #expect(timeline.end == 3)
        #expect(timeline.startTime(forRunCapturedAt: 2.5) == 3)
        #expect(timeline.startTime(forRunCapturedAt: 4) == 4)
    }

    @Test func contiguousInputExtendsEnd() {
        var timeline = AnalyzerTimeline(origin: 0)
        timeline.registerAnalyzerInput(start: 0.5, duration: 1)
        timeline.registerAnalyzerInput(start: nil, duration: 0.25)
        #expect(timeline.end == 1.75)
    }
}
