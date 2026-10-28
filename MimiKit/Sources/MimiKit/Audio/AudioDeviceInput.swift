import AVFAudio
import CoreAudio
import Darwin
import Synchronization

/// Delivers the input of a device through an IOProc, in the streams and formats the device had when it was set up.
final class AudioDeviceInput {
    private final class Gate: Sendable {
        let isOpen = Atomic(true)
    }

    let device: AudioDeviceID
    private let streams: [AudioStreamID]
    private let streamFormats: [AudioStreamBasicDescription]
    private let queue: DispatchQueue
    private let gate = Gate()
    private var ioProcID: AudioDeviceIOProcID?

    init(device: AudioDeviceID, label: String) throws(AudioCaptureError) {
        self.device = device
        streams = try device.readStreams(scope: kAudioObjectPropertyScopeInput)
        guard !streams.isEmpty else { throw .inputDeviceUnavailable }
        var streamFormats: [AudioStreamBasicDescription] = []
        for stream in streams {
            streamFormats.append(try stream.readVirtualFormat())
        }
        self.streamFormats = streamFormats
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    /// Properties whose change can make the device deliver something other than what this input was set up for.
    var observedProperties: [AudioProperty] {
        [
            AudioProperty(object: device, selector: kAudioDevicePropertyDeviceIsAlive),
            AudioProperty(object: device, selector: kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput),
            AudioProperty(object: device, selector: kAudioDevicePropertyNominalSampleRate),
        ] + streams.map { AudioProperty(object: $0, selector: kAudioStreamPropertyVirtualFormat) }
    }

    /// Whether the device is still present with the streams and formats this input was set up for.
    func isCurrent() -> Bool {
        guard device.readIsAlive(), (try? device.readStreams(scope: kAudioObjectPropertyScopeInput)) == streams else {
            return false
        }
        return zip(streams, streamFormats).allSatisfy { stream, format in
            (try? stream.readVirtualFormat())?.matches(format) == true
        }
    }

    func start(onBuffer: @escaping AudioBufferHandler) throws(AudioCaptureError) {
        let assembler = try InputStreamAssembler(streamFormats: streamFormats)
        let gate = gate
        // `@Sendable` keeps the block from inheriting the isolation of its context; it runs on `queue`.
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, device, queue) { @Sendable _, inputData, inputTime, _, _ in
                guard gate.isOpen.load(ordering: .acquiring), let buffer = assembler.buffer(from: inputData) else { return }
                let timestamp = inputTime.pointee
                onBuffer(buffer, timestamp.mFlags.contains(.hostTimeValid) ? timestamp.mHostTime : mach_absolute_time())
            },
            "AudioDeviceCreateIOProcIDWithBlock"
        )
        try check(AudioDeviceStart(device, ioProcID), "AudioDeviceStart")
    }

    /// No audio is delivered once this returns.
    func stop() {
        gate.isOpen.store(false, ordering: .releasing)
        if let ioProcID {
            // Both fail once the device is gone, which also ends its IOProcs.
            AudioDeviceStop(device, ioProcID)
            AudioDeviceDestroyIOProcID(device, ioProcID)
            self.ioProcID = nil
        }
        // Waits for a delivery in progress.
        queue.sync {}
    }
}
