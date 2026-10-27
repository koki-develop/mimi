import Foundation

public protocol TextGenerator: Sendable {
    func generate(instructions: String, prompt: String) async throws -> String
}

public protocol TextGeneratorProvider: Sendable {
    /// Returns a generator running the model whose files are in `directory`, loading the model if needed.
    func generator(forModelAt directory: URL) async throws -> any TextGenerator
}
