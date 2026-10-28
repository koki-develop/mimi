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
        var converter: AudioStreamConverter?

        mutating func append(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) throws(EngineError) {
            let captureTime = AVAudioTime.seconds(forHostTime: hostTime)
            let isDiscontinuous = timeline.registerCapture(
                at: captureTime,
                duration: Double(buffer.frameLength) / buffer.format.sampleRate
            )
            var runStart: TimeInterval?
            if isDiscontinuous || converter?.inputFormat != buffer.format {
                try flushConverter()
                converter = try Self.converting(AudioStreamConverter(from: buffer.format, to: analyzerFormat))
                runStart = timeline.startTime(forRunCapturedAt: captureTime)
            }
            guard let converter, let converted = try Self.converting(converter.convert(buffer)) else { return }
            yield(converted, start: runStart)
        }

        mutating func flushConverter() throws(EngineError) {
            if let converter, let remaining = try Self.converting(converter.drain()) {
                yield(remaining, start: nil)
            }
            converter = nil
        }

        private static func converting<T>(_ body: @autoclosure () throws(AudioConversionError) -> T) throws(EngineError) -> T {
            do {
                return try body()
            } catch {
                throw .audioConversionFailed(error.errorDescription ?? "Unknown error")
            }
        }

        private mutating func yield(_ buffer: AVAudioPCMBuffer, start: TimeInterval?) {
            let bufferStartTime = start.map { CMTime(seconds: $0, preferredTimescale: CMTimeScale(analyzerFormat.sampleRate)) }
            inputs.yield(AnalyzerInput(buffer: buffer, bufferStartTime: bufferStartTime))
            timeline.registerAnalyzerInput(start: start, duration: Double(buffer.frameLength) / analyzerFormat.sampleRate)
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

    public func finalizePending() async {
        let pending = session.withLock { session -> (SpeechAnalyzer, CMTime, AsyncThrowingStream<TranscriptionResult, any Error>.Continuation)? in
            guard var current = session else { return nil }
            defer { session = current }
            do {
                try current.flushConverter()
            } catch {
                current.results.finish(throwing: error)
                return nil
            }
            // Finalizes through the last sample supplied. With `nil`, the analyzer would only finalize
            // the audio it has consumed, which may not include all of the audio supplied.
            let sampleRate = current.analyzerFormat.sampleRate
            let sampleCount = CMTimeValue((current.timeline.end * sampleRate).rounded())
            guard sampleCount > 0 else { return nil }
            return (current.analyzer, CMTime(value: sampleCount - 1, timescale: CMTimeScale(sampleRate)), current.results)
        }
        guard let (analyzer, lastSampleTime, results) = pending else { return }
        do {
            try await analyzer.finalize(through: lastSampleTime)
        } catch {
            // Finishing the engine meanwhile ends the analysis early, which is not a failure.
            if session.withLock({ $0 != nil }) {
                results.finish(throwing: error)
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
