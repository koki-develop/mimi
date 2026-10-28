import Foundation

/// What the model reads to summarize the current topic.
enum TopicSummaryPrompt {
    static let inProgressMarker = "（話し中）"
    static let clippedMarker = "…"

    static let instructions = """
        あなたは会議の内容を整理するアシスタントです。
        入力は音声認識による文字起こしで、「\(Speaker.me.displayName)」はこのアプリの利用者、「\(Speaker.others.displayName)」はそれ以外の参加者の発言です。
        文字起こしには誤認識が含まれることがあるため、文脈から意図を補って解釈してください。
        「\(inProgressMarker)」が付いた発言は話している途中のもので、文の途中で途切れていたり、後で認識結果が変わったりします。
        「\(clippedMarker)」で始まる発言は冒頭が省略されています。
        出力は日本語の要約本文のみとし、前置きや見出しは書かないでください。
        """

    static func prompt(for excerpt: TranscriptExcerpt) -> String {
        """
        直近の発言:
        \(excerpt.lines.map(format).joined(separator: "\n"))

        今話されている話題を2〜3文で要約してください。
        """
    }

    static func format(_ line: TranscriptExcerpt.Line) -> String {
        let speaker = line.speaker.displayName + (line.isFinal ? "" : inProgressMarker)
        let text = (line.isClipped ? clippedMarker : "") + line.text
        return "\(speaker): \(text)"
    }
}
