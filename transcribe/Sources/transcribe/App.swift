import Foundation
@preconcurrency import WhisperKit

public enum AppError: Error, Equatable {
    case outputExists(String)
    case permission(String)
    case model(String)
    case capture(String)
    case io(String)
}

public struct App {
    public static func run(output: URL, modelName: String, verbose: Bool = false) async throws {
        let reporter = ConsoleReporter()
        let capture = AudioCapture(reporter: reporter, verbose: verbose)

        if FileManager.default.fileExists(atPath: output.path) {
            await reporter.reportError("Output file already exists: \(output.path)")
            throw AppError.outputExists(output.path)
        }

        do {
            try await PermissionChecker.ensureAll()
        } catch PermissionError.screenRecordingDenied {
            await reporter.reportError("Screen Recording permission required.")
            throw AppError.permission("screen")
        } catch PermissionError.microphoneDenied {
            await reporter.reportError("Microphone permission required.")
            throw AppError.permission("mic")
        }

        let loader = ModelLoader()
        let micModel: LoadedModel
        let systemModel: LoadedModel
        do {
            micModel = try await loader.load(
                name: modelName,
                computeOptions: ModelComputeOptions(
                    melCompute: .cpuAndNeuralEngine,
                    audioEncoderCompute: .cpuAndNeuralEngine,
                    textDecoderCompute: .cpuAndNeuralEngine,
                    prefillCompute: .cpuOnly
                ),
                reporter: reporter
            )
            systemModel = try await loader.load(
                name: modelName,
                computeOptions: ModelComputeOptions(
                    melCompute: .cpuAndGPU,
                    audioEncoderCompute: .cpuAndGPU,
                    textDecoderCompute: .cpuAndGPU,
                    prefillCompute: .cpuOnly
                ),
                reporter: reporter
            )
        } catch {
            await reporter.reportError("Failed to load model '\(modelName)': \(error)")
            throw AppError.model(String(describing: error))
        }

        do {
            try await capture.start()
        } catch {
            await reporter.reportError("Capture failed: \(error)")
            throw AppError.capture(String(describing: error))
        }

        let startedAt = await capture.startedAt()
        let header = Header(startedAt: startedAt, model: modelName)
        let writer: JSONLWriter
        do {
            writer = try JSONLWriter(output: output, header: header)
        } catch JSONLWriterError.outputAlreadyExists {
            await capture.stop()
            await reporter.reportError("Output file already exists: \(output.path)")
            throw AppError.outputExists(output.path)
        } catch {
            await capture.stop()
            await reporter.reportError("I/O error: \(error)")
            throw AppError.io(String(describing: error))
        }

        let micTranscriber = Transcriber(
            source: .mic,
            model: micModel,
            reporter: reporter,
            verbose: verbose
        )
        let systemTranscriber = Transcriber(
            source: .system,
            model: systemModel,
            reporter: reporter,
            verbose: verbose
        )

        await reporter.reportStatus("Recording started. Press Ctrl+C to stop.")

        let counter = Counter()

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await segment in micTranscriber.consume(capture.micStream) {
                        try await writer.write(segment)
                        await reporter.report(segment)
                        await counter.increment()
                    }
                }
                group.addTask {
                    for await segment in systemTranscriber.consume(capture.systemStream) {
                        try await writer.write(segment)
                        await reporter.report(segment)
                        await counter.increment()
                    }
                }
                group.addTask {
                    await SignalHandler.waitForSIGINT()
                    await capture.stop()
                }
                try await group.waitForAll()
            }
        } catch {
            await reporter.reportError("I/O error: \(error)")
            await capture.stop()
            try? await writer.close()
            throw AppError.io(String(describing: error))
        }

        try await writer.close()
        let total = await counter.value
        await reporter.reportStatus("Stopped. Wrote \(total) segments to \(output.path).")
    }

    actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }
}
