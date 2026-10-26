public protocol TextGenerator: Sendable {
    func generate(instructions: String, prompt: String) async throws -> String
}

public protocol TextGeneratorProvider: Sendable {
    /// Returns a generator for `modelID`, downloading and loading the model if needed.
    /// `progressHandler` receives the download progress in 0...1.
    func generator(
        for modelID: String,
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws -> any TextGenerator
}
