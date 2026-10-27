import Foundation

/// How much of a model download has completed, in bytes.
public struct ModelDownloadProgress: Sendable, Equatable {
    public var completedBytes: Int64
    public var totalBytes: Int64

    public init(completedBytes: Int64, totalBytes: Int64) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }

    /// From 0 to 1.
    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(completedBytes) / Double(totalBytes), 0), 1)
    }
}

/// Keeps the files of summary models on disk.
public protocol SummaryModelStorage: Sendable {
    /// The directory holding the files of `model`, or `nil` unless a download of it has completed and its files are
    /// all still present.
    func directory(of model: SummaryModel) -> URL?

    /// The disk space used by the files of a downloaded model, in bytes.
    func size(of model: SummaryModel) -> Int64

    /// Downloads the latest revision of `model`. Throws `CancellationError` or another error when cancelled.
    /// The files of a download that does not complete stay until ``removeFiles(of:)``, so a later download resumes them.
    func download(
        _ model: SummaryModel,
        progressHandler: @MainActor @Sendable @escaping (ModelDownloadProgress) -> Void
    ) async throws

    /// Removes every file of `model`, whether its download completed or not.
    func removeFiles(of model: SummaryModel) throws

    /// Removes the files of every download that did not complete, and of every model not in `models`.
    /// Must not be called while a download is in progress.
    func removeUnusedFiles(keeping models: [SummaryModel])

    /// Removes the temporary files that downloads leave behind outside the storage, such as those of a cancelled
    /// download. Must not be called while a download is in progress.
    func removeTemporaryFiles()
}
