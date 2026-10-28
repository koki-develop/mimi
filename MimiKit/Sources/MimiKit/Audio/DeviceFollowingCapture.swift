import Dispatch
import OSLog

/// Capture set up against the devices the system provided at the time.
protocol CaptureBinding: AnyObject {
    /// Properties whose change can leave the binding outdated, such as its device going away.
    var observedProperties: [AudioProperty] { get }
    /// Whether the binding still captures what the system currently provides.
    func isCurrent() -> Bool
    /// Stops capture and releases what the binding set up. No audio is delivered once this returns.
    func stop()
}

/// Keeps capture bound to the devices the system currently provides: whenever a watched property changes and the
/// binding is outdated, it is replaced. While no binding can be made, the capture is unavailable until the next change.
///
/// Bindings are made and replaced on a private queue, since setting up a device can block for a while, for example
/// while the system asks for permission to record.
final class DeviceFollowingCapture: @unchecked Sendable {
    typealias Bind = @Sendable (_ onBuffer: @escaping AudioBufferHandler) throws -> any CaptureBinding

    @MainActor
    private final class Token: Sendable {
        var isActive = true
    }

    private struct Run {
        let onBuffer: AudioBufferHandler
        let report: @Sendable (AudioSourceAvailability) -> Void
        var systemListeners: [any AudioPropertyListener] = []
        var binding: (any CaptureBinding)?
        var bindingListeners: [any AudioPropertyListener] = []
        var isAvailable = true
    }

    private let logger: Logger
    private let systemProperties: [AudioProperty]
    private let listening: any AudioPropertyListening
    private let bind: Bind
    /// Owns all of the state below.
    private let queue: DispatchQueue
    /// Where listeners are called, apart from `queue` so that listeners can be removed on `queue`.
    private let listenerQueue: DispatchQueue
    @MainActor private var token: Token?
    private var run: Run?

    /// `systemProperties` are watched for as long as the capture runs, so that it resumes when they change while no
    /// binding can be made.
    init(
        label: String,
        systemProperties: [AudioProperty],
        listening: any AudioPropertyListening = CoreAudioPropertyListening(),
        bind: @escaping Bind
    ) {
        logger = Logger(subsystem: "MimiKit", category: label)
        self.systemProperties = systemProperties
        self.listening = listening
        self.bind = bind
        queue = DispatchQueue(label: label, qos: .userInitiated)
        listenerQueue = DispatchQueue(label: "\(label).listener", qos: .userInitiated)
    }

    /// `onAvailabilityChange` is not called once ``stop()`` is called.
    @MainActor
    func start(onBuffer: @escaping AudioBufferHandler, onAvailabilityChange: @escaping @MainActor (AudioSourceAvailability) -> Void) {
        token?.isActive = false
        let token = Token()
        self.token = token
        let report: @Sendable (AudioSourceAvailability) -> Void = { availability in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard token.isActive else { return }
                    onAvailabilityChange(availability)
                }
            }
        }
        queue.async { [self] in
            tearDown()
            run = Run(onBuffer: onBuffer, report: report)
            do {
                for property in systemProperties {
                    run?.systemListeners.append(try listen(to: property))
                }
            } catch {
                logger.error("Cannot follow the devices: \(error.localizedDescription, privacy: .public)")
                setAvailability(.unavailable(error))
                return
            }
            reconcile()
        }
    }

    @MainActor
    func stop() async {
        token?.isActive = false
        token = nil
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                tearDown()
                continuation.resume()
            }
        }
    }

    /// Stops capture before the instance goes away, without waiting for it.
    @MainActor
    func stopInBackground() {
        token?.isActive = false
        token = nil
        queue.async { [self] in tearDown() }
    }

    private func listen(to property: AudioProperty) throws(AudioCaptureError) -> any AudioPropertyListener {
        try listening.listen(to: property, on: listenerQueue) { [weak self] in
            guard let self else { return }
            queue.async { self.reconcile() }
        }
    }

    /// Replaces the binding if it is missing or outdated.
    private func reconcile() {
        guard let run else { return }
        if let binding = run.binding, binding.isCurrent() { return }
        unbind()
        let binding: any CaptureBinding
        do {
            binding = try bind(run.onBuffer)
        } catch {
            logger.error("Cannot capture: \(error.localizedDescription, privacy: .public)")
            setAvailability(.unavailable(error))
            return
        }
        self.run?.binding = binding
        do {
            for property in binding.observedProperties {
                self.run?.bindingListeners.append(try listen(to: property))
            }
        } catch {
            logger.error("Cannot follow the device: \(error.localizedDescription, privacy: .public)")
            unbind()
            setAvailability(.unavailable(error))
            return
        }
        // A change before the listeners were added has not been reported to them.
        guard binding.isCurrent() else {
            logger.info("The devices changed while capture was being set up")
            queue.async { self.reconcile() }
            return
        }
        logger.info("Capturing")
        setAvailability(.available)
    }

    private func unbind() {
        run?.bindingListeners.forEach { $0.remove() }
        run?.bindingListeners = []
        run?.binding?.stop()
        run?.binding = nil
    }

    private func tearDown() {
        unbind()
        run?.systemListeners.forEach { $0.remove() }
        run = nil
    }

    /// Reports every failure, since its reason may differ from the previous one, but only the first success after one.
    private func setAvailability(_ availability: AudioSourceAvailability) {
        guard let run else { return }
        switch availability {
        case .available:
            guard !run.isAvailable else { return }
            self.run?.isAvailable = true
        case .unavailable:
            self.run?.isAvailable = false
        }
        run.report(availability)
    }
}
