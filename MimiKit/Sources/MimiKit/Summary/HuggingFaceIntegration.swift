import Foundation
import HuggingFace
import MLXLMCommon
import Tokenizers

struct HubDownloader: MLXLMCommon.Downloader {
    enum DownloaderError: LocalizedError {
        case invalidRepositoryID(String)

        var errorDescription: String? {
            switch self {
            case let .invalidRepositoryID(id):
                "Invalid Hugging Face repository ID: \(id)"
            }
        }
    }

    private let cache = HubCache.default
    private let client: HubClient

    init() {
        client = HubClient(cache: cache)
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repoID = Repo.ID(rawValue: id) else {
            throw DownloaderError.invalidRepositoryID(id)
        }
        var revision = revision ?? "main"
        // `HubClient` serves a verified, complete snapshot from the cache without a network
        // request only when given a commit hash, so a cached ref is resolved first.
        if !useLatest, let commit = cache.resolveRevision(repo: repoID, kind: .model, ref: revision) {
            revision = commit
        }
        return try await client.downloadSnapshot(
            of: repoID,
            revision: revision,
            matching: patterns,
            progressHandler: { @MainActor progress in progressHandler(progress) }
        )
    }
}

struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TransformersTokenizer(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}

private struct TransformersTokenizer: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
