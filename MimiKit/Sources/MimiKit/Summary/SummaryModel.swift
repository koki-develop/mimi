public struct SummaryModel: Identifiable, Sendable, Hashable {
    public let id: String
    public let displayName: String

    public static let qwen3_5_4B = SummaryModel(id: "mlx-community/Qwen3.5-4B-4bit", displayName: "Qwen3.5 4B")
    public static let qwen3_5_9B = SummaryModel(id: "mlx-community/Qwen3.5-9B-4bit", displayName: "Qwen3.5 9B")
    public static let gemma4_12B = SummaryModel(id: "mlx-community/gemma-4-12B-it-4bit", displayName: "Gemma 4 12B")
    public static let qwen3_6_35B_A3B = SummaryModel(id: "mlx-community/Qwen3.6-35B-A3B-4bit", displayName: "Qwen3.6 35B-A3B")

    public static let all: [SummaryModel] = [qwen3_5_4B, qwen3_5_9B, gemma4_12B, qwen3_6_35B_A3B]
    public static let `default` = qwen3_5_9B
}
