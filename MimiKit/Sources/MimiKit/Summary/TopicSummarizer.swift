import Foundation

/// Summarizes the topic currently being discussed from the most recent lines, including those still in progress.
public actor TopicSummarizer {
    private let generator: any TextGenerator
    private let recentCharacterLimit: Int
    /// The prompt of the last summary, which needs no update while the prompt stays the same.
    private var lastPrompt: String?

    /// `recentCharacterLimit` bounds the text of the lines the summary reads. Must be positive.
    public init(generator: any TextGenerator, recentCharacterLimit: Int = 1500) {
        precondition(recentCharacterLimit > 0, "The recent character limit must be positive")
        self.generator = generator
        self.recentCharacterLimit = recentCharacterLimit
    }

    /// Returns `nil` when there are no lines, or when the recent lines read the same as for the last summary.
    public func update(with lines: [Transcript.Line]) async throws -> String? {
        let excerpt = TranscriptExcerpt(of: lines, characterLimit: recentCharacterLimit)
        guard !excerpt.lines.isEmpty else { return nil }
        let prompt = TopicSummaryPrompt.prompt(for: excerpt)
        guard prompt != lastPrompt else { return nil }

        let summary = try await generator.generate(instructions: TopicSummaryPrompt.instructions, prompt: prompt)
        lastPrompt = prompt
        return summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
