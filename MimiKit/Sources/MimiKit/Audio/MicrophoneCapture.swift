import AVFAudio
import CoreAudio

/// Captures audio from the default input device, following changes of the device while running.
///
/// Reads the device that is the default input when capture is set up, directly through an IOProc, so that capture set
/// up right after the default input changes is on that device, and stays on it until it is replaced.
public final class MicrophoneCapture: AudioSource {
    private let capture = DeviceFollowingCapture(
        label: "MicrophoneCapture",
        systemProperties: [
            AudioProperty(object: .system, selector: kAudioHardwarePropertyDefaultInputDevice),
            AudioProperty(object: .system, selector: kAudioHardwarePropertyDevices),
        ]
    ) { onBuffer in
        try MicrophoneBinding(onBuffer: onBuffer)
    }

    public init() {}

    isolated deinit {
        capture.stopInBackground()
    }

    public func requestAccess() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    public func start(onBuffer: @escaping AudioBufferHandler, onAvailabilityChange: @escaping @MainActor (AudioSourceAvailability) -> Void) {
        capture.start(onBuffer: onBuffer, onAvailabilityChange: onAvailabilityChange)
    }

    public func stop() async {
        await capture.stop()
    }
}

/// Capture from the device that was the default input when it was set up.
private final class MicrophoneBinding: CaptureBinding {
    private let input: AudioDeviceInput

    init(onBuffer: @escaping AudioBufferHandler) throws(AudioCaptureError) {
        let device = try AudioObjectID.readDefaultInputDevice()
        // The system has no default input for a moment while a device is removed.
        guard device.isValid else { throw .inputDeviceUnavailable }
        input = try AudioDeviceInput(device: device, label: "MicrophoneCapture.input")
        do {
            try input.start(onBuffer: onBuffer)
        } catch {
            input.stop()
            throw error
        }
    }

    var observedProperties: [AudioProperty] {
        input.observedProperties
    }

    func isCurrent() -> Bool {
        (try? AudioObjectID.readDefaultInputDevice()) == input.device && input.isCurrent()
    }

    func stop() {
        input.stop()
    }
}
