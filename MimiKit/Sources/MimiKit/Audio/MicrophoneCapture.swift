import AVFAudio
import CoreAudio
import Darwin
import Foundation

/// Captures audio from the default input device, following changes of the device while running.
public final class MicrophoneCapture: AudioSource {
    private struct Run {
        let onBuffer: AudioBufferHandler
        let onFailure: (any Error) -> Void
        let defaultDeviceObserver: AudioPropertyObserver
        var engine: AVAudioEngine?
        var configurationObserver: (any NSObjectProtocol)?
    }

    private var run: Run?

    public init() {}

    isolated deinit {
        stop()
    }

    public func requestAccess() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    public func start(onBuffer: @escaping AudioBufferHandler, onFailure: @escaping (any Error) -> Void) throws {
        stop()
        let defaultDeviceObserver = AudioPropertyObserver(selector: kAudioHardwarePropertyDefaultInputDevice)
        run = Run(onBuffer: onBuffer, onFailure: onFailure, defaultDeviceObserver: defaultDeviceObserver)
        do {
            try defaultDeviceObserver.start { [weak self] in self?.restart() }
            try startEngine()
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        stopEngine()
        run?.defaultDeviceObserver.stop()
        run = nil
    }

    /// Starts a new engine, since an engine keeps using the input device it was started with.
    private func startEngine() throws {
        guard let onBuffer = run?.onBuffer else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Installing a tap without an available input raises an exception instead of throwing.
        let hardwareFormat = input.inputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw AudioCaptureError.inputDeviceUnavailable
        }

        // `@Sendable` keeps the block from inheriting main actor isolation; it runs on an audio thread.
        input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { @Sendable buffer, time in
            onBuffer(buffer, time.isHostTimeValid ? time.hostTime : mach_absolute_time())
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }

        // The engine stops itself when the hardware format changes.
        let engineID = ObjectIdentifier(engine)
        run?.configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Ignores notifications from an engine already replaced by a restart.
                guard let self, let current = self.run?.engine, ObjectIdentifier(current) == engineID else { return }
                self.restart()
            }
        }
        run?.engine = engine
    }

    private func stopEngine() {
        if let configurationObserver = run?.configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            run?.configurationObserver = nil
        }
        if let engine = run?.engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            run?.engine = nil
        }
    }

    private func restart() {
        guard let run else { return }
        stopEngine()
        do {
            try startEngine()
        } catch {
            stop()
            run.onFailure(error)
        }
    }
}
