import Foundation
import HuggingFace

/// Keeps summary models downloaded from the Hugging Face Hub in a cache of its own.
///
/// A download is complete once a manifest listing its files is written. The Hub cache keeps the files of a download
/// that is still running or was interrupted without a manifest, so only the manifest tells complete downloads apart.
public struct HubSummaryModelStorage: SummaryModelStorage {
    enum StorageError: LocalizedError {
        case invalidRepositoryID(String)
        case missingRevision(String)
        case missingFiles([String])

        var errorDescription: String? {
            switch self {
            case let .invalidRepositoryID(id):
                "Invalid Hugging Face repository ID: \(id)"
            case let .missingRevision(id):
                "The Hugging Face Hub returned no revision for \(id)"
            case let .missingFiles(files):
                "The download is missing \(files.joined(separator: ", "))"
            }
        }
    }

    private struct Manifest: Codable {
        var revision: String
        /// Paths relative to the snapshot directory.
        var files: [String]
    }

    /// The files MLX loads a language model and its tokenizer from, matching `modelDownloadPatterns` in MLXLMCommon,
    /// which is not public.
    static let downloadPatterns = ["*.safetensors", "*.json", "*.jinja"]

    /// Names of the temporary files a download writes: URLSession's, and the Hub client's copy of each finished one.
    static let temporaryFilePrefixes = ["CFNetworkDownload_", "hf-download-"]

    let cache: HubCache
    private let manifestsDirectory: URL
    /// Caches of earlier versions of the app, removed with the other unused files.
    private let legacyDirectories: [URL]
    /// The directory downloads write their temporary files to, when only this app uses it.
    private let temporaryDirectory: URL?

    /// - Parameter temporaryDirectory: The directory downloads write their temporary files to, whose leftovers
    ///   ``removeTemporaryFiles()`` removes. Pass it only when no other process uses the directory.
    public init(directory: URL, legacyDirectories: [URL] = [], temporaryDirectory: URL? = nil) {
        cache = HubCache(cacheDirectory: directory.appending(path: "hub", directoryHint: .isDirectory))
        manifestsDirectory = directory.appending(path: "manifests", directoryHint: .isDirectory)
        self.legacyDirectories = legacyDirectories
        self.temporaryDirectory = temporaryDirectory
    }

    public func directory(of model: SummaryModel) -> URL? {
        guard let repo = Repo.ID(rawValue: model.id),
            let data = try? Data(contentsOf: manifestURL(of: repo)),
            let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else {
            return nil
        }
        let snapshot = snapshotDirectory(of: repo, revision: manifest.revision)
        let isComplete = manifest.files.allSatisfy { file in
            FileManager.default.fileExists(atPath: snapshot.appending(path: file).path(percentEncoded: false))
        }
        return isComplete ? snapshot : nil
    }

    public func size(of model: SummaryModel) -> Int64 {
        guard let snapshot = directory(of: model),
            let files = FileManager.default.enumerator(at: snapshot, includingPropertiesForKeys: nil)
        else {
            return 0
        }
        // Snapshot entries link to the blobs that hold the data.
        return files.reduce(into: Int64(0)) { total, entry in
            guard let url = entry as? URL,
                let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey]),
                values.isRegularFile == true
            else {
                return
            }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
    }

    public func download(
        _ model: SummaryModel,
        progressHandler: @MainActor @Sendable @escaping (ModelDownloadProgress) -> Void
    ) async throws {
        let repo = try repoID(of: model)
        let client = HubClient(cache: cache)
        // Downloading a commit rather than a branch keeps the snapshot from mixing files of different revisions.
        guard let revision = try await client.getModel(repo).sha else {
            throw StorageError.missingRevision(model.id)
        }
        // Listed here rather than taken from the snapshot, because the Hub client returns a partial snapshot from the
        // cache without an error when it fails to list the files itself.
        let files = try await client.listFiles(in: repo, revision: revision).filter { entry in
            entry.type == .file && Self.downloadPatterns.contains { fnmatch($0, entry.path, 0) == 0 }
        }.map(\.path)
        _ = try await client.downloadSnapshot(
            of: repo,
            revision: revision,
            matching: Self.downloadPatterns,
            progressHandler: { progress in progressHandler(ModelDownloadProgress(progress)) }
        )
        try Task.checkCancellation()
        try markDownloadComplete(of: model, revision: revision, files: files)
    }

    /// Records that the snapshot of `revision` holds `files`, the files of `model`. Throws if any of them is missing.
    func markDownloadComplete(of model: SummaryModel, revision: String, files: [String]) throws {
        let repo = try repoID(of: model)
        let snapshot = snapshotDirectory(of: repo, revision: revision)
        let missingFiles = files.filter { file in
            !FileManager.default.fileExists(atPath: snapshot.appending(path: file).path(percentEncoded: false))
        }
        guard missingFiles.isEmpty else {
            throw StorageError.missingFiles(missingFiles)
        }
        let manifestURL = manifestURL(of: repo)
        try FileManager.default.createDirectory(at: manifestsDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(Manifest(revision: revision, files: files)).write(to: manifestURL, options: .atomic)
        removeFiles(of: model, notIn: snapshot)
    }

    /// Removes what earlier attempts left beside a complete snapshot: snapshots of other revisions, and blobs the
    /// snapshot does not link to, such as those of a failed download of an earlier revision. Best effort, as only disk
    /// space is lost when it fails.
    private func removeFiles(of model: SummaryModel, notIn snapshot: URL) {
        let snapshotsDirectory = snapshot.deletingLastPathComponent()
        for entry in contents(of: snapshotsDirectory) where entry != snapshot.lastPathComponent {
            try? FileManager.default.removeItem(at: snapshotsDirectory.appending(path: entry))
        }
        guard let blobsDirectory = try? repoDirectory(of: model).appending(path: "blobs", directoryHint: .isDirectory),
            let links = FileManager.default.enumerator(at: snapshot, includingPropertiesForKeys: nil)
        else {
            return
        }
        let linkedBlobs = Set(links.compactMap { ($0 as? URL)?.resolvingSymlinksInPath().lastPathComponent })
        for entry in contents(of: blobsDirectory) where !linkedBlobs.contains(entry) {
            try? FileManager.default.removeItem(at: blobsDirectory.appending(path: entry))
        }
    }

    public func removeFiles(of model: SummaryModel) throws {
        let repo = try repoID(of: model)
        // The manifest goes first, so a removal that fails partway never leaves a download that looks complete.
        try removeItemIfPresent(at: manifestURL(of: repo))
        for directory in try directories(of: model) {
            try removeItemIfPresent(at: directory)
        }
    }

    public func removeUnusedFiles(keeping models: [SummaryModel]) {
        let kept = Set(models.compactMap { model -> String? in
            guard directory(of: model) != nil else { return nil }
            return try? repoDirectory(of: model).lastPathComponent
        })
        // The Hub cache names each directory of a repository after it, under a parent shared by every repository.
        let parents = Set(models.flatMap { model in
            ((try? directories(of: model)) ?? []).map { $0.deletingLastPathComponent() }
        })
        // Best effort: whatever cannot be removed now is tried again the next time.
        for parent in parents {
            for entry in contents(of: parent) where !entry.hasPrefix(".") && !kept.contains(entry) {
                try? FileManager.default.removeItem(at: parent.appending(path: entry))
            }
        }
        for entry in contents(of: manifestsDirectory) where !kept.contains((entry as NSString).deletingPathExtension) {
            try? FileManager.default.removeItem(at: manifestsDirectory.appending(path: entry))
        }
        for directory in legacyDirectories {
            try? removeItemIfPresent(at: directory)
        }
    }

    public func removeTemporaryFiles() {
        guard let temporaryDirectory else { return }
        // URLSession keeps the file of a download task that is cancelled, even once its session is invalidated.
        // Best effort, as for the other unused files.
        for entry in contents(of: temporaryDirectory) where Self.temporaryFilePrefixes.contains(where: entry.hasPrefix) {
            try? FileManager.default.removeItem(at: temporaryDirectory.appending(path: entry))
        }
    }

    private func repoID(of model: SummaryModel) throws -> Repo.ID {
        guard let repo = Repo.ID(rawValue: model.id) else {
            throw StorageError.invalidRepositoryID(model.id)
        }
        return repo
    }

    /// The directory holding the downloaded files of `model`, complete or not.
    func repoDirectory(of model: SummaryModel) throws -> URL {
        cache.repoDirectory(repo: try repoID(of: model), kind: .model)
    }

    /// Every directory the Hub cache writes for `model`: its files, and its metadata and locks kept beside them.
    func directories(of model: SummaryModel) throws -> [URL] {
        let repoDirectory = try repoDirectory(of: model)
        return [
            repoDirectory,
            cache.metadataDirectory(repo: try repoID(of: model), kind: .model),
            cache.lockPath(for: repoDirectory),
        ]
    }

    private func snapshotDirectory(of repo: Repo.ID, revision: String) -> URL {
        cache.snapshotsDirectory(repo: repo, kind: .model).appending(path: revision, directoryHint: .isDirectory)
    }

    private func manifestURL(of repo: Repo.ID) -> URL {
        manifestsDirectory.appending(path: cache.repoDirectory(repo: repo, kind: .model).lastPathComponent + ".json")
    }

    private func contents(of directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
    }

    private func removeItemIfPresent(at url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }
}

extension HubSummaryModelStorage {
    /// Storage in the app's Application Support directory. Downloaded models are kept until the user deletes them,
    /// so they do not belong in the Caches directory.
    public static func live() -> HubSummaryModelStorage {
        // Earlier versions used the default Hub cache, which is in the app container's Caches directory only when
        // sandboxed. Outside the sandbox it, like the temporary directory, is shared with other apps and must be left
        // alone.
        let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        return HubSummaryModelStorage(
            directory: URL.applicationSupportDirectory.appending(path: "SummaryModels", directoryHint: .isDirectory),
            legacyDirectories: isSandboxed ? [URL.cachesDirectory.appending(path: "huggingface", directoryHint: .isDirectory)] : [],
            temporaryDirectory: isSandboxed ? FileManager.default.temporaryDirectory : nil
        )
    }
}

extension ModelDownloadProgress {
    /// The progress of a Hub snapshot download, whose units are bytes.
    ///
    /// The Hub client tracks each file in a child of `progress`, and a parent's `completedUnitCount` counts a child
    /// only once it finishes, so the bytes of files still downloading are only in `fractionCompleted`.
    init(_ progress: Progress) {
        let totalBytes = max(progress.totalUnitCount, 0)
        self.init(
            completedBytes: Int64((progress.fractionCompleted * Double(totalBytes)).rounded()),
            totalBytes: totalBytes
        )
    }
}
