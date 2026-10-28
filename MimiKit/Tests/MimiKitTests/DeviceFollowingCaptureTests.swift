import AVFAudio
import CoreAudio
@testable import MimiKit
import Synchronization
import Testing

private struct TestError: Error {}

private let defaultInputDevice = AudioProperty(object: .system, selector: kAudioHardwarePropertyDefaultInputDevice)
private let deviceIsAlive = AudioProperty(object: 42, selector: kAudioDevicePropertyDeviceIsAlive)

/// Listeners that tests call by hand, as Core Audio would on a property change.
private final class FakeListening: AudioPropertyListening {
    private final class Listener: AudioPropertyListener, @unchecked Sendable {
        let selector: AudioObjectPropertySelector
        let handler: @Sendable () -> Void
        private let isRemoved = Mutex(false)

        init(selector: AudioObjectPropertySelector, handler: @escaping @Sendable () -> Void) {
            self.selector = selector
            self.handler = handler
        }

        var isActive: Bool {
            !isRemoved.withLock { $0 }
        }

        func remove() {
            isRemoved.withLock { $0 = true }
        }
    }

    private let listeners = Mutex<[Listener]>([])
    private let failingSelectors = Mutex<Set<AudioObjectPropertySelector>>([])

    func failListening(to selector: AudioObjectPropertySelector) {
        failingSelectors.withLock { _ = $0.insert(selector) }
    }

    /// The selectors listened to and not removed.
    var activeSelectors: [AudioObjectPropertySelector] {
        listeners.withLock { $0.filter(\.isActive).map(\.selector) }
    }

    func change(_ property: AudioProperty) {
        let handlers = listeners.withLock { $0.filter { $0.isActive && $0.selector == property.selector }.map(\.handler) }
        handlers.forEach { $0() }
    }

    func listen(
        to property: AudioProperty,
        on queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) throws(AudioCaptureError) -> any AudioPropertyListener {
        if failingSelectors.withLock({ $0.contains(property.selector) }) {
            throw .coreAudio(operation: "listen", status: -1)
        }
        let listener = Listener(selector: property.selector, handler: { queue.async(execute: handler) })
        listeners.withLock { $0.append(listener) }
        return listener
    }
}

/// Devices that bindings capture from. A binding is current until the device generation changes.
private final class FakeDevices: Sendable {
    private struct State {
        var generation = 0
        var bindError: (any Error)?
        /// Changes the device generation while the next binding is being made.
        var changesWhileBinding = false
        var bound: [Int] = []
        var stopped: [Int] = []
        var onBuffer: AudioBufferHandler?
    }

    private let state = Mutex(State())

    var bindError: (any Error)? {
        get { state.withLock { $0.bindError } }
        set { state.withLock { $0.bindError = newValue } }
    }

    var changesWhileBinding: Bool {
        get { state.withLock { $0.changesWhileBinding } }
        set { state.withLock { $0.changesWhileBinding = newValue } }
    }

    /// The device generations bindings were made for, in order.
    var bound: [Int] {
        state.withLock { $0.bound }
    }

    var stopped: [Int] {
        state.withLock { $0.stopped }
    }

    func changeDevice() {
        state.withLock { $0.generation += 1 }
    }

    func isCurrent(_ generation: Int) -> Bool {
        state.withLock { $0.generation == generation }
    }

    func bind(onBuffer: @escaping AudioBufferHandler) throws -> any CaptureBinding {
        let generation = try state.withLock { state in
            if let error = state.bindError { throw error }
            state.bound.append(state.generation)
            state.onBuffer = onBuffer
            defer {
                if state.changesWhileBinding {
                    state.changesWhileBinding = false
                    state.generation += 1
                }
            }
            return state.generation
        }
        return FakeBinding(devices: self, generation: generation)
    }

    func stop(_ generation: Int) {
        state.withLock { $0.stopped.append(generation) }
    }

    /// Delivers audio to the latest binding.
    func capture(_ buffer: AVAudioPCMBuffer) {
        state.withLock { $0.onBuffer }?(buffer, 0)
    }
}

private final class FakeBinding: CaptureBinding {
    let devices: FakeDevices
    let generation: Int

    init(devices: FakeDevices, generation: Int) {
        self.devices = devices
        self.generation = generation
    }

    var observedProperties: [AudioProperty] {
        [deviceIsAlive]
    }

    func isCurrent() -> Bool {
        devices.isCurrent(generation)
    }

    func stop() {
        devices.stop(generation)
    }
}

/// Availability reported to the main actor, in order.
@MainActor
private final class Reports {
    private(set) var values: [String] = []

    func record(_ availability: AudioSourceAvailability) {
        switch availability {
        case .available: values.append("available")
        case .unavailable: values.append("unavailable")
        }
    }
}

private final class FrameCounter: Sendable {
    private let count = Mutex(0)

    var value: Int {
        count.withLock { $0 }
    }

    func add(_ frames: AVAudioFrameCount) {
        count.withLock { $0 += Int(frames) }
    }
}

@MainActor
private final class Harness {
    let listening = FakeListening()
    let devices = FakeDevices()
    let reports = Reports()
    let receivedFrames = FrameCounter()
    let capture: DeviceFollowingCapture

    init() {
        capture = DeviceFollowingCapture(label: "Test", systemProperties: [defaultInputDevice], listening: listening) { [devices] onBuffer in
            try devices.bind(onBuffer: onBuffer)
        }
    }

    func start() {
        capture.start(
            onBuffer: { [receivedFrames] buffer, _ in receivedFrames.add(buffer.frameLength) },
            onAvailabilityChange: { [reports] in reports.record($0) }
        )
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for condition")
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// Lets reports already sent to the main actor arrive.
@MainActor
private func settle() async throws {
    try await Task.sleep(for: .milliseconds(50))
}

@MainActor
struct DeviceFollowingCaptureTests {
    @Test func bindsOnStartAndDeliversAudio() async throws {
        let harness = Harness()
        harness.start()
        try await waitUntil { harness.devices.bound == [0] }

        harness.devices.capture(makeBuffer([Float](repeating: 0, count: 160)))
        #expect(harness.receivedFrames.value == 160)
        #expect(Set(harness.listening.activeSelectors) == [kAudioHardwarePropertyDefaultInputDevice, kAudioDevicePropertyDeviceIsAlive])

        await harness.capture.stop()
        #expect(harness.devices.stopped == [0])
        #expect(harness.listening.activeSelectors.isEmpty)
        try await settle()
        #expect(harness.reports.values.isEmpty)
    }

    @Test func replacesOutdatedBindingWhenAWatchedPropertyChanges() async throws {
        let harness = Harness()
        harness.start()
        try await waitUntil { harness.devices.bound == [0] }

        harness.devices.changeDevice()
        harness.listening.change(deviceIsAlive)
        try await waitUntil { harness.devices.bound == [0, 1] }
        #expect(harness.devices.stopped == [0])
        // The outdated binding's listeners are replaced by the new binding's.
        #expect(harness.listening.activeSelectors.filter { $0 == kAudioDevicePropertyDeviceIsAlive }.count == 1)

        await harness.capture.stop()
        try await settle()
        #expect(harness.reports.values.isEmpty)
    }

    @Test func keepsBindingThatIsStillCurrent() async throws {
        let harness = Harness()
        harness.start()
        try await waitUntil { harness.devices.bound == [0] }

        harness.listening.change(defaultInputDevice)
        harness.listening.change(deviceIsAlive)
        // Stopping runs after the changes are handled.
        await harness.capture.stop()
        #expect(harness.devices.bound == [0])
        #expect(harness.devices.stopped == [0])
    }

    @Test func isUnavailableUntilABindingCanBeMade() async throws {
        let harness = Harness()
        harness.devices.bindError = TestError()
        harness.start()
        try await waitUntil { harness.reports.values == ["unavailable"] }
        #expect(harness.devices.bound.isEmpty)

        // Every failure is reported, since its reason may differ.
        harness.listening.change(defaultInputDevice)
        try await waitUntil { harness.reports.values == ["unavailable", "unavailable"] }

        harness.devices.bindError = nil
        harness.listening.change(defaultInputDevice)
        try await waitUntil { harness.reports.values == ["unavailable", "unavailable", "available"] }
        #expect(harness.devices.bound == [0])

        // Only the first success after a failure is reported.
        harness.devices.changeDevice()
        harness.listening.change(deviceIsAlive)
        try await waitUntil { harness.devices.bound == [0, 1] }
        await harness.capture.stop()
        try await settle()
        #expect(harness.reports.values == ["unavailable", "unavailable", "available"])
    }

    @Test func outdatedBindingIsStoppedWhenNoNewOneCanBeMade() async throws {
        let harness = Harness()
        harness.start()
        try await waitUntil { harness.devices.bound == [0] }

        harness.devices.bindError = TestError()
        harness.devices.changeDevice()
        harness.listening.change(deviceIsAlive)
        try await waitUntil { harness.reports.values == ["unavailable"] }
        #expect(harness.devices.stopped == [0])
        #expect(harness.listening.activeSelectors == [kAudioHardwarePropertyDefaultInputDevice])
        await harness.capture.stop()
    }

    @Test func rebindsWhenTheDevicesChangeWhileBinding() async throws {
        let harness = Harness()
        harness.devices.changesWhileBinding = true
        harness.start()

        try await waitUntil { harness.devices.bound == [0, 1] }
        #expect(harness.devices.stopped == [0])
        await harness.capture.stop()
        try await settle()
        #expect(harness.reports.values.isEmpty)
    }

    @Test func bindingThatCannotBeFollowedIsUnavailable() async throws {
        let harness = Harness()
        harness.listening.failListening(to: kAudioDevicePropertyDeviceIsAlive)
        harness.start()

        try await waitUntil { harness.reports.values == ["unavailable"] }
        #expect(harness.devices.bound == [0])
        #expect(harness.devices.stopped == [0])
        await harness.capture.stop()
    }

    @Test func doesNotReportAfterStop() async throws {
        let harness = Harness()
        harness.devices.bindError = TestError()
        harness.start()
        await harness.capture.stop()

        try await settle()
        #expect(harness.reports.values.isEmpty)
        #expect(harness.listening.activeSelectors.isEmpty)
    }

    @Test func restartReplacesThePreviousRun() async throws {
        let harness = Harness()
        harness.start()
        try await waitUntil { harness.devices.bound == [0] }

        harness.start()
        try await waitUntil { harness.devices.bound == [0, 0] }
        #expect(harness.devices.stopped == [0])
        #expect(harness.listening.activeSelectors.count == 2)
        await harness.capture.stop()
        #expect(harness.listening.activeSelectors.isEmpty)
    }
}
