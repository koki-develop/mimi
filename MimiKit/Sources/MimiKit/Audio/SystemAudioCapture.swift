import AVFAudio
import CoreAudio
import Darwin
import Foundation
import OSLog

/// Captures the mixed-down audio output of every process on the system via a Core Audio process tap.
/// The tap runs on an aggregate device clocked by the default system output device, so the tap is
/// rebuilt whenever that device changes.
public final class SystemAudioCapture: AudioSource {
    private static let logger = Logger(subsystem: "MimiKit", category: "SystemAudioCapture")

    private struct Run {
        let onBuffer: AudioBufferHandler
        let onFailure: (any Error) -> Void
        let defaultDeviceObserver: AudioPropertyObserver
    }

    private var run: Run?
    private var tapID = AudioObjectID.unknown
    private var aggregateDeviceID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "SystemAudioCapture", qos: .userInitiated)

    public init() {}

    isolated deinit {
        stop()
    }

    /// Core Audio has no API to request or check the system audio recording permission.
    /// The system prompts on first capture; when denied, the tap delivers silence.
    public func requestAccess() async -> Bool {
        true
    }

    public func start(onBuffer: @escaping AudioBufferHandler, onFailure: @escaping (any Error) -> Void) throws {
        stop()
        let defaultDeviceObserver = AudioPropertyObserver(selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
        run = Run(onBuffer: onBuffer, onFailure: onFailure, defaultDeviceObserver: defaultDeviceObserver)
        do {
            try defaultDeviceObserver.start { [weak self] in self?.restart() }
            try startTap()
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        stopTap()
        run?.defaultDeviceObserver.stop()
        run = nil
    }

    private func restart() {
        guard let run else { return }
        stopTap()
        do {
            try startTap()
        } catch {
            stop()
            run.onFailure(error)
        }
    }

    private func startTap() throws(AudioCaptureError) {
        guard let onBuffer = run?.onBuffer else { return }
        do {
            try createTap(onBuffer: onBuffer)
        } catch {
            stopTap()
            throw error
        }
    }

    private func createTap(onBuffer: @escaping AudioBufferHandler) throws(AudioCaptureError) {
        let tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        tapDescription.uuid = UUID()
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(tapDescription, &tapID), "AudioHardwareCreateProcessTap")

        var streamDescription = try tapID.readTapFormat()
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw .unsupportedFormat
        }

        let outputUID = try AudioObjectID.readDefaultSystemOutputDevice().readDeviceUID()
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mimi System Audio Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID],
            ],
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

        // `@Sendable` keeps the block from inheriting main actor isolation; it runs on `queue`.
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, queue) { @Sendable _, inputData, inputTime, _, _ in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil) else {
                    return
                }
                let timestamp = inputTime.pointee
                onBuffer(buffer, timestamp.mFlags.contains(.hostTimeValid) ? timestamp.mHostTime : mach_absolute_time())
            },
            "AudioDeviceCreateIOProcIDWithBlock"
        )
        try check(AudioDeviceStart(aggregateDeviceID, ioProcID), "AudioDeviceStart")
    }

    private func stopTap() {
        if aggregateDeviceID.isValid {
            log(AudioDeviceStop(aggregateDeviceID, ioProcID), "AudioDeviceStop")
            if let ioProcID {
                log(AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID), "AudioDeviceDestroyIOProcID")
                self.ioProcID = nil
            }
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
