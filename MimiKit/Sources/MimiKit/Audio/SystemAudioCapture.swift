import AVFAudio
import CoreAudio
import OSLog

/// Captures the mixed-down audio output of every process on the system via a Core Audio process tap.
///
/// The tap is read through a private aggregate device holding only the tap. The tap covers every output device, so
/// it keeps capturing when the output device changes.
public final class SystemAudioCapture: AudioSource {
    // Capture that could not be set up is retried when the output changes, which is when the tap is reconfigured.
    private let capture = DeviceFollowingCapture(
        label: "SystemAudioCapture",
        systemProperties: [
            AudioProperty(object: .system, selector: kAudioHardwarePropertyDefaultOutputDevice),
            AudioProperty(object: .system, selector: kAudioHardwarePropertyDefaultSystemOutputDevice),
        ]
    ) { onBuffer in
        try SystemAudioBinding(onBuffer: onBuffer)
    }

    public init() {}

    isolated deinit {
        capture.stopInBackground()
    }

    /// Core Audio has no API to request or check the system audio recording permission.
    /// The system prompts on first capture; when denied, the tap delivers silence.
    public func requestAccess() async -> Bool {
        true
    }

    public func start(onBuffer: @escaping AudioBufferHandler, onAvailabilityChange: @escaping @MainActor (AudioSourceAvailability) -> Void) {
        capture.start(onBuffer: onBuffer, onAvailabilityChange: onAvailabilityChange)
    }

    public func stop() async {
        await capture.stop()
    }
}

/// A process tap and the aggregate device it is read through.
private final class SystemAudioBinding: CaptureBinding {
    private static let logger = Logger(subsystem: "MimiKit", category: "SystemAudioCapture")

    private var tapID = AudioObjectID.unknown
    private var tapFormat = AudioStreamBasicDescription()
    private var aggregateDeviceID = AudioObjectID.unknown
    private var input: AudioDeviceInput?

    init(onBuffer: @escaping AudioBufferHandler) throws(AudioCaptureError) {
        do {
            try setUp(onBuffer: onBuffer)
        } catch {
            stop()
            throw error
        }
    }

    private func setUp(onBuffer: @escaping AudioBufferHandler) throws(AudioCaptureError) {
        let tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        tapDescription.uuid = UUID()
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(tapDescription, &tapID), "AudioHardwareCreateProcessTap")
        tapFormat = try tapID.readTapFormat()

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mimi System Audio Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                ],
            ],
        ]
        try check(
            AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateDeviceID),
            "AudioHardwareCreateAggregateDevice"
        )

        let input = try AudioDeviceInput(device: aggregateDeviceID, label: "SystemAudioCapture.input")
        self.input = input
        try input.start(onBuffer: onBuffer)
    }

    var observedProperties: [AudioProperty] {
        [AudioProperty(object: tapID, selector: kAudioTapPropertyFormat)] + (input?.observedProperties ?? [])
    }

    func isCurrent() -> Bool {
        guard let input, input.isCurrent() else { return false }
        return (try? tapID.readTapFormat())?.matches(tapFormat) == true
    }

    func stop() {
        input?.stop()
        input = nil
        if aggregateDeviceID.isValid {
            log(AudioHardwareDestroyAggregateDevice(aggregateDeviceID), "AudioHardwareDestroyAggregateDevice")
            aggregateDeviceID = .unknown
        }
        if tapID.isValid {
            log(AudioHardwareDestroyProcessTap(tapID), "AudioHardwareDestroyProcessTap")
            tapID = .unknown
        }
    }

    private func log(_ status: OSStatus, _ operation: String) {
        if status != noErr {
            Self.logger.error("\(operation, privacy: .public) failed (OSStatus \(status))")
        }
    }
}
