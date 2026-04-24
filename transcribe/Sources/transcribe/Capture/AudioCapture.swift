import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

public enum AudioCaptureError: Error, Equatable {
    case noDisplayAvailable
    case streamSetupFailed(String)
}

public actor AudioCapture {
    public nonisolated let micStream: AsyncStream<CapturedAudioChunk>
    public nonisolated let systemStream: AsyncStream<CapturedAudioChunk>

    private let micContinuation: AsyncStream<CapturedAudioChunk>.Continuation
    private let systemContinuation: AsyncStream<CapturedAudioChunk>.Continuation
    private let reporter: EventLogger
    private let verbose: Bool
    private let sessionStart = SessionStartTracker()
    private let streamErrorBox = StreamErrorBox()

    private var stream: SCStream?
    private var micOutput: OutputHandler?
    private var systemOutput: OutputHandler?
    private var delegate: Delegate?

    /// Delegate が `SCStreamDelegate.stream(_:didStopWithError:)` を受けた際に記録した
    /// エラーを取り出す(取り出し時にクリア)。consume が drain した後に App 側で
    /// `error` イベントとして emit するために使う。
    public nonisolated func takeStreamError() -> Error? {
        streamErrorBox.take()
    }

    public init(reporter: EventLogger, verbose: Bool = false) {
        var micContinuation: AsyncStream<CapturedAudioChunk>.Continuation!
        var systemContinuation: AsyncStream<CapturedAudioChunk>.Continuation!
        self.micStream = AsyncStream(bufferingPolicy: .unbounded) { micContinuation = $0 }
        self.systemStream = AsyncStream(bufferingPolicy: .unbounded) { systemContinuation = $0 }
        self.micContinuation = micContinuation
        self.systemContinuation = systemContinuation
        self.reporter = reporter
        self.verbose = verbose
    }

    public func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw AudioCaptureError.streamSetupFailed("failed to query shareable content: \(error)")
        }

        guard let display = content.displays.first else {
            throw AudioCaptureError.noDisplayAvailable
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        // The stream is configured to Whisper's native 16kHz mono target so
        // ScreenCaptureKit can downsample system audio for us. Microphone
        // capture still arrives in the device's native format; each output
        // handler performs its own streaming sample-rate conversion.
        config.sampleRate = 16_000
        config.channelCount = 1
        config.captureMicrophone = true
        if let micID = AVCaptureDevice.default(for: .audio)?.uniqueID {
            config.microphoneCaptureDeviceID = micID
        }
        // SCStream requires a minimal video configuration even when we only
        // consume audio. A 2x2 @ 1fps stream is sufficient and no video output
        // is registered, so the frames are discarded internally.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let micOutput = OutputHandler(
            source: .mic,
            continuation: micContinuation,
            reporter: reporter,
            verbose: verbose,
            sessionStart: sessionStart
        )
        let systemOutput = OutputHandler(
            source: .system,
            continuation: systemContinuation,
            reporter: reporter,
            verbose: verbose,
            sessionStart: sessionStart
        )
        let delegate = Delegate(
            streamErrorBox: streamErrorBox,
            micOutput: micOutput,
            systemOutput: systemOutput,
            micContinuation: micContinuation,
            systemContinuation: systemContinuation
        )

        let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
        do {
            try stream.addStreamOutput(
                systemOutput,
                type: .audio,
                sampleHandlerQueue: systemOutput.queue
            )
            try stream.addStreamOutput(
                micOutput,
                type: .microphone,
                sampleHandlerQueue: micOutput.queue
            )
        } catch {
            delegate.finish()
            throw AudioCaptureError.streamSetupFailed("failed to add stream outputs: \(error)")
        }

        self.micOutput = micOutput
        self.systemOutput = systemOutput
        self.delegate = delegate
        self.stream = stream

        do {
            sessionStart.markRequested(at: Date())
            try await stream.startCapture()
        } catch {
            delegate.finish()
            self.stream = nil
            self.micOutput = nil
            self.systemOutput = nil
            self.delegate = nil
            throw AudioCaptureError.streamSetupFailed("failed to start capture: \(error)")
        }
    }

    public func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }

        micOutput?.finish()
        systemOutput?.finish()

        stream = nil
        micOutput = nil
        systemOutput = nil
        delegate = nil
        micContinuation.finish()
        systemContinuation.finish()
    }

    public func startedAt() -> Date {
        sessionStart.startedAt ?? Date()
    }

    /// `SCStreamDelegate.stream(_:didStopWithError:)` で捕捉した最初のエラーを
    /// 同期的に保存するためのロック付きストレージ。Delegate のコールバックは
    /// actor 外の dispatch キューから呼ばれるため、actor hop を介さずに記録できる
    /// 必要がある。
    final class StreamErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var error: Error?

        func trySet(_ err: Error) {
            lock.lock(); defer { lock.unlock() }
            if error == nil { error = err }
        }

        func take() -> Error? {
            lock.lock(); defer { lock.unlock() }
            let taken = error
            error = nil
            return taken
        }
    }

    final class Delegate: NSObject, SCStreamDelegate, @unchecked Sendable {
        private let micOutput: OutputHandler
        private let systemOutput: OutputHandler
        private let micContinuation: AsyncStream<CapturedAudioChunk>.Continuation
        private let systemContinuation: AsyncStream<CapturedAudioChunk>.Continuation
        private let streamErrorBox: StreamErrorBox

        private let finishLock = NSLock()
        private var hasFinished = false

        init(
            streamErrorBox: StreamErrorBox,
            micOutput: OutputHandler,
            systemOutput: OutputHandler,
            micContinuation: AsyncStream<CapturedAudioChunk>.Continuation,
            systemContinuation: AsyncStream<CapturedAudioChunk>.Continuation
        ) {
            self.streamErrorBox = streamErrorBox
            self.micOutput = micOutput
            self.systemOutput = systemOutput
            self.micContinuation = micContinuation
            self.systemContinuation = systemContinuation
        }

        func stream(_ stream: SCStream, didStopWithError error: any Error) {
            // エラーを同期的に box に保管し、App.run が group drain 後に取り出して
            // `error` イベントを本流で emit する。fire-and-forget Task だと
            // writer close との race で JSONL から event が消える可能性があるため。
            streamErrorBox.trySet(error)
            finish()
        }

        func finish() {
            finishLock.lock()
            let shouldFinish = !hasFinished
            hasFinished = true
            finishLock.unlock()

            guard shouldFinish else { return }

            micOutput.finish()
            systemOutput.finish()
            micContinuation.finish()
            systemContinuation.finish()
        }
    }

    final class OutputHandler: NSObject, SCStreamOutput, @unchecked Sendable {
        let queue: DispatchQueue

        private let source: AudioSource
        private let continuation: AsyncStream<CapturedAudioChunk>.Continuation
        private let reporter: EventLogger
        private let verbose: Bool
        private let targetFormat: AVAudioFormat
        private let sessionStart: SessionStartTracker

        private let stateLock = NSLock()
        private var state = OutputState()

        init(
            source: AudioSource,
            continuation: AsyncStream<CapturedAudioChunk>.Continuation,
            reporter: EventLogger,
            verbose: Bool,
            sessionStart: SessionStartTracker
        ) {
            self.queue = DispatchQueue(
                label: "me.koki.transcribe.capture.\(source.rawValue)",
                qos: .userInitiated
            )
            self.source = source
            self.continuation = continuation
            self.reporter = reporter
            self.verbose = verbose
            self.sessionStart = sessionStart
            self.targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )!
        }

        func finish() {
            let result = withLockedState { state in
                state.finish(source: source)
            }

            if let warning = result.warning {
                Task { [reporter] in
                    await reporter.warning(warning)
                }
            }
            if let trailingChunk = result.chunk {
                continuation.yield(trailingChunk)
            }
        }

        func stream(
            _ stream: SCStream,
            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
            of type: SCStreamOutputType
        ) {
            guard sampleBuffer.isValid, Self.matches(source: source, outputType: type) else {
                return
            }
            guard let inputBuffer = Self.makePCMBuffer(from: sampleBuffer) else { return }

            let now = Date()
            let formatDescription = Self.describe(format: inputBuffer.format)
            let presentationTime = Self.capturePresentationTime(from: sampleBuffer)

            let result = withLockedState { state in
                state.consume(
                    inputBuffer: inputBuffer,
                    presentationTime: presentationTime,
                    fallbackDate: now,
                    source: source,
                    targetFormat: targetFormat,
                    formatDescription: formatDescription,
                    verbose: verbose
                )
            }

            if let firstFormatLog = result.firstFormatLog {
                Task { [reporter] in
                    await reporter.statusMessage(firstFormatLog)
                }
            }
            if let warning = result.warning {
                Task { [reporter] in
                    await reporter.warning(warning)
                }
            }
            if let drainedChunk = result.drainedChunk {
                sessionStart.recordCaptureTime(drainedChunk.captureTime)
                continuation.yield(drainedChunk)
            }
            if let convertedChunk = result.convertedChunk {
                sessionStart.recordCaptureTime(convertedChunk.captureTime)
                continuation.yield(convertedChunk)
            }
        }

        private func withLockedState<T>(_ body: (inout OutputState) -> T) -> T {
            stateLock.lock()
            defer { stateLock.unlock() }
            return body(&state)
        }

        static func matches(source: AudioSource, outputType: SCStreamOutputType) -> Bool {
            switch (source, outputType) {
            case (.system, .audio), (.mic, .microphone):
                return true
            default:
                return false
            }
        }

        static func capturePresentationTime(from sampleBuffer: CMSampleBuffer) -> CMTime {
            let outputTime = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
            if outputTime.isValid, !outputTime.isIndefinite {
                return outputTime
            }

            return CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        }

        static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
            guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
                return nil
            }
            let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)

            let sampleCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
            guard sampleCount > 0 else { return nil }
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: sampleCount) else {
                return nil
            }

            pcmBuffer.frameLength = sampleCount

            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer,
                at: 0,
                frameCount: Int32(sampleCount),
                into: pcmBuffer.mutableAudioBufferList
            )
            guard status == noErr else { return nil }

            return pcmBuffer
        }

        static func describe(format: AVAudioFormat) -> String {
            "\(Int(format.sampleRate))Hz, \(format.channelCount)ch, format=\(format.commonFormat.rawValue)"
        }
    }

    struct OutputState {
        var converter: AudioSampleConverter?
        var converterInputFormat: AVAudioFormat?
        var timingMapper = SampleBufferClockMapper()
        var didLogFormat = false
        var nextCaptureTime: Date?

        mutating func consume(
            inputBuffer: AVAudioPCMBuffer,
            presentationTime: CMTime,
            fallbackDate: Date,
            source: AudioSource,
            targetFormat: AVAudioFormat,
            formatDescription: String,
            verbose: Bool
        ) -> OutputConsumeResult {
            let firstFormatLog: String?
            if verbose, !didLogFormat {
                didLogFormat = true
                let label = source == .mic ? "mic" : "sys"
                firstFormatLog = "[debug] first \(label) buffer: \(formatDescription)"
            } else {
                firstFormatLog = nil
            }

            do {
                var drainedChunk: CapturedAudioChunk?
                if converter == nil || !Self.isCompatible(inputBuffer.format, with: converterInputFormat) {
                    drainedChunk = try drain(source: source)
                    nextCaptureTime = nil
                    converterInputFormat = inputBuffer.format
                    guard let newConverter = AudioSampleConverter(
                        inputFormat: inputBuffer.format,
                        outputFormat: targetFormat
                    ) else {
                        throw AudioSampleConverterError.conversionFailed("failed to create converter")
                    }
                    converter = newConverter
                }

                let captureTime = timingMapper.captureTime(
                    for: presentationTime,
                    fallbackDate: fallbackDate
                )
                if nextCaptureTime == nil {
                    nextCaptureTime = captureTime
                }
                let convertedSamples = try converter?.convertStreaming(inputBuffer) ?? []
                let convertedChunk = convertedSamples.isEmpty
                    ? nil
                    : makeChunk(
                        source: source,
                        samples: convertedSamples,
                        captureTime: nextCaptureTime ?? captureTime
                    )

                return OutputConsumeResult(
                    firstFormatLog: firstFormatLog,
                    warning: nil,
                    drainedChunk: drainedChunk,
                    convertedChunk: convertedChunk
                )
            } catch {
                return OutputConsumeResult(
                    firstFormatLog: firstFormatLog,
                    warning: "audio conversion failed for \(source.rawValue): \(error)",
                    drainedChunk: nil,
                    convertedChunk: nil
                )
            }
        }

        mutating func finish(source: AudioSource) -> OutputFinishResult {
            do {
                let chunk = try drain(source: source)
                return OutputFinishResult(
                    warning: nil,
                    chunk: chunk
                )
            } catch {
                return OutputFinishResult(
                    warning: "audio converter drain failed for \(source.rawValue): \(error)",
                    chunk: nil
                )
            }
        }

        private mutating func drain(source: AudioSource) throws -> CapturedAudioChunk? {
            guard let converter else { return nil }

            defer {
                self.converter = nil
                self.converterInputFormat = nil
            }

            let drainedSamples = try converter.finish()
            guard let nextCaptureTime, !drainedSamples.isEmpty else { return nil }

            return makeChunk(source: source, samples: drainedSamples, captureTime: nextCaptureTime)
        }

        private mutating func makeChunk(
            source: AudioSource,
            samples: [Float],
            captureTime: Date
        ) -> CapturedAudioChunk {
            nextCaptureTime = captureTime.addingTimeInterval(Double(samples.count) / 16_000)
            return CapturedAudioChunk(
                source: source,
                samples: samples,
                captureTime: captureTime
            )
        }

        private static func isCompatible(_ lhs: AVAudioFormat, with rhs: AVAudioFormat?) -> Bool {
            guard let rhs else { return false }

            return lhs.commonFormat == rhs.commonFormat
                && lhs.sampleRate == rhs.sampleRate
                && lhs.channelCount == rhs.channelCount
                && lhs.isInterleaved == rhs.isInterleaved
        }
    }

    struct OutputConsumeResult {
        let firstFormatLog: String?
        let warning: String?
        let drainedChunk: CapturedAudioChunk?
        let convertedChunk: CapturedAudioChunk?
    }

    struct OutputFinishResult {
        let warning: String?
        let chunk: CapturedAudioChunk?
    }

    final class SessionStartTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var requestedAt: Date?
        private var firstCaptureTime: Date?

        var startedAt: Date? {
            lock.lock()
            defer { lock.unlock() }
            return firstCaptureTime ?? requestedAt
        }

        func markRequested(at date: Date) {
            lock.lock()
            defer { lock.unlock() }

            requestedAt = date
        }

        func recordCaptureTime(_ date: Date) {
            lock.lock()
            defer { lock.unlock() }

            if let firstCaptureTime {
                if date < firstCaptureTime {
                    self.firstCaptureTime = date
                }
            } else {
                firstCaptureTime = date
            }
        }
    }
}
