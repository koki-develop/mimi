import Foundation
import MLX
import MLXLLM
import MLXLMCommon

final class MLXTextGenerator: TextGenerator {
    private let container: ModelContainer

    private init(container: ModelContainer) {
        self.container = container
    }

    static func load(
        modelID: String,
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws -> MLXTextGenerator {
        let container = try await LLMModelFactory.shared.loadContainer(
            from: HubDownloader(),
            using: TransformersTokenizerLoader(),
            configuration: ModelConfiguration(id: modelID),
            progressHandler: { progress in progressHandler(progress.fractionCompleted) }
        )
        return MLXTextGenerator(container: container)
    }

    func generate(instructions: String, prompt: String) async throws -> String {
        let session = ChatSession(
            container,
            instructions: instructions,
            generateParameters: GenerateParameters(maxTokens: 1024, temperature: 0.3),
            // Models with a thinking mode (e.g. Qwen) read this flag from their chat template.
            additionalContext: ["enable_thinking": false]
        )
        return try await session.respond(to: prompt)
    }
}

/// Keeps at most one model in memory, releasing it before loading a different one.
public actor MLXTextGeneratorProvider: TextGeneratorProvider {
    private var loaded: (modelID: String, generator: MLXTextGenerator)?

    public init() {
        // Bounds the buffer cache MLX keeps between evaluations, as recommended for LLM inference.
        Memory.cacheLimit = 20 * 1024 * 1024
    }

    /// Calls must not overlap.
    public func generator(
        for modelID: String,
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws -> any TextGenerator {
        if let loaded, loaded.modelID == modelID {
            return loaded.generator
        }
        loaded = nil
        Memory.clearCache()

        let generator = try await MLXTextGenerator.load(modelID: modelID, progressHandler: progressHandler)
        loaded = (modelID, generator)
        return generator
    }
}
