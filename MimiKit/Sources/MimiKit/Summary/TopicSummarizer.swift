import Foundation

/// Summarizes the topic currently being discussed from the most recent final lines.
public actor TopicSummarizer {
    static let instructions = """
        あなたは会議の内容を整理するアシスタントです。
        入力は音声認識による文字起こしで、「\(Speaker.me.displayName)」はこのアプリの利用者、「\(Speaker.others.displayName)」はそれ以外の参加者の発言です。
        文字起こしには誤認識が含まれることがあるため、文脈から意図を補って解釈してください。
        出力は日本語の要約本文のみとし、前置きや見出しは書かないでください。
        """

    private let generator: any TextGenerator
    private let recentCharacterLimit: Int
    private var summarizedLineIDs: Set<UUID> = []

    public init(generator: any TextGenerator, recentCharacterLimit: Int = 1500) {
        self.generator = generator
        self.recentCharacterLimit = recentCharacterLimit
    }

    /// Returns `nil` when no final lines have been added since the last summary.
    public func update(with finalLines: [Transcript.Line]) async throws -> String? {
        let newLineIDs = Set(finalLines.map(\.id)).subtracting(summarizedLineIDs)
        guard !newLineIDs.isEmpty else { return nil }

        let summary = try await generator.generate(
            instructions: Self.instructions,
            prompt: """
                直近の発言:
                \(Self.format(recentLines(of: finalLines)))

                今話されている話題を2〜3文で要約してください。
                """
        )
        summarizedLineIDs.formUnion(newLineIDs)
        return summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func recentLines(of lines: [Transcript.Line]) -> [Transcript.Line] {
        var characterCount = 0
        let recent = lines.reversed().prefix { line in
            characterCount += line.text.count
            return characterCount <= recentCharacterLimit
        }
        return recent.isEmpty ? Array(lines.suffix(1)) : recent.reversed()
    }

    static func format(_ lines: [Transcript.Line]) -> String {
        lines.map { "\($0.speaker.displayName): \($0.text)" }.joined(separator: "\n")
    }
}
