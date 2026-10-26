import AVFAudio
import CoreMedia
import Speech
import Synchronization

/// On-device transcription with `SpeechAnalyzer` and `SpeechTranscriber`.
public final class AppleSpeechTranscriptionEngine: TranscriptionEngine {
    public enum EngineError: LocalizedError {
        case unsupportedLocale(Locale)
        case audioFormatUnavailable
        case audioConversionFailed(String)

        public var errorDescription: String? {
            switch self {
            case let .unsupportedLocale(locale):
                "Speech transcription is not supported for \(locale.identifier)"
            case .audioFormatUnavailable:
                "No audio format is available for speech transcription"
            case let .audioConversionFailed(detail):
                "Audio conversion failed: \(detail)"
            }
        }
    }

    private struct Session {
        let analyzer: SpeechAnalyzer
        let analyzerFormat: AVAudioFormat
        let inputs: AsyncStream<AnalyzerInput>.Continuation
        let results: AsyncThrowingStream<TranscriptionResult, any Error>.Continuation
        var timeline: AnalyzerTimeline
        var converter: AVAudioConverter?

        mutating func append(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) throws(EngineError) {
            let captureTime = AVAudioTime.seconds(forHostTime: hostTime)
            let isDiscontinuous = timeline.registerCapture(
                at: captureTime,
                duration: Double(buffer.frameLength) / buffer.format.sampleRate
            )
            var runStart: TimeInterval?
            if isDiscontinuous || converter?.inputFormat != buffer.format {
                try flushConverter()
                guard let converter = AVAudioConverter(from: buffer.format, to: analyzerFormat) else {
                    throw .audioConversionFailed("\(buffer.format) to \(analyzerFormat) is not supported")
                }
                converter.downmix = true
                self.converter = converter
                runStart = timeline.startTime(forRunCapturedAt: captureTime)
            }
            guard let converter, let converted = try convert(buffer, using: converter) else { return }
            yield(converted, start: runStart)
        }

        mutating func flushConverter() throws(EngineError) {
            if let converter, let remaining = try convert(nil, using: converter) {
                yield(remaining, start: nil)
            }
            converter = nil
        }

        private mutating func yield(_ buffer: AVAudioPCMBuffer, start: TimeInterval?) {
            let bufferStartTime = start.map { CMTime(seconds: $0, preferredTimescale: CMTimeScale(analyzerFormat.sampleRate)) }
            inputs.yield(AnalyzerInput(buffer: buffer, bufferStartTime: bufferStartTime))
            timeline.registerAnalyzerInput(start: start, duration: Double(buffer.frameLength) / analyzerFormat.sampleRate)
        }

        /// Converts `buffer`, or drains the samples buffered inside `converter` when `buffer` is `nil`.
        /// Returns `nil` when the converter produced no samples.
        private func convert(_ buffer: AVAudioPCMBuffer?, using converter: AVAudioConverter) throws(EngineError) -> AVAudioPCMBuffer? {
            let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
            let inputFrames = buffer.map { Double($0.frameLength) } ?? 0
            // Leaves room for samples the converter holds back from earlier calls.
            let capacity = AVAudioFrameCount((inputFrames * ratio).rounded(.up)) + 1024
            guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
                throw .audioConversionFailed("Could not allocate an output buffer of \(capacity) frames")
            }

            // The input block is invoked synchronously within `convert(to:error:withInputFrom:)`.
            nonisolated(unsafe) let input = buffer
            nonisolated(unsafe) var consumed = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                guard let input else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if consumed {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                inputStatus.pointee = .haveData
                return input
            }
            if status == .error {
                throw .audioConversionFailed(error?.localizedDescription ?? "Unknown error")
            }
            return output.frameLength > 0 ? output : nil
        }
    }

    private let locale: Locale
    private let session = Mutex<Session?>(nil)

    public init(locale: Locale) {
        self.locale = locale
    }

    public func start(timelineOrigin: UInt64) async throws -> AsyncThrowingStream<TranscriptionResult, any Error> {
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw EngineError.unsupportedLocale(locale)
        }
        let transcriber = SpeechTranscriber(locale: supportedLocale, preset: .timeIndexedProgressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw EngineError.audioFormatUnavailable
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        let (inputSequence, inputs) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: inputSequence)

        let (resultStream, results) = AsyncThrowingStream.makeStream(of: TranscriptionResult.self)
        let transcriberResults = transcriber.results
        let task = Task {
            do {
                for try await result in transcriberResults {
                    results.yield(TranscriptionResult(
                        text: String(result.text.characters),
                        start: result.range.start.seconds,
                        end: result.range.end.seconds,
                        isFinal: result.isFinal
                    ))
                }
                results.finish()
            } catch {
                results.finish(throwing: error)
            }
        }
        results.onTermination = { _ in task.cancel() }

        session.withLock {
            $0 = Session(
                analyzer: analyzer,
                analyzerFormat: analyzerFormat,
                inputs: inputs,
                results: results,
                timeline: AnalyzerTimeline(origin: AVAudioTime.seconds(forHostTime: timelineOrigin))
            )
        }
        return resultStream
    }

    public func append(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        session.withLock { session in
            do {
                try session?.append(buffer, hostTime: hostTime)
            } catch {
                session?.results.finish(throwing: error)
            }
        }
    }

    public func finish() async {
        let analyzer = session.withLock { session in
            defer { session = nil }
            do {
                try session?.flushConverter()
            } catch {
                session?.results.finish(throwing: error)
            }
            session?.inputs.finish()
            return session?.analyzer
        }
        // Throws only `CancellationError`, when analysis has already finished and the results have ended.
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
    }
}
