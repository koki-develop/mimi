import Foundation
import Observation

/// Lends downloaded summary models, keeping each one from being deleted while it is in use.
@MainActor
public protocol SummaryModelLibrary: AnyObject {
    /// Marks `model` as in use and returns the directory holding its files.
    /// Throws when the model is not downloaded. Every successful call must be balanced by ``endUsing(_:)``.
    func beginUsing(_ model: SummaryModel) throws -> URL
    func endUsing(_ model: SummaryModel)
}

/// Downloads and deletes summary models, and keeps the one selected for summarizing.
///
/// Only a downloaded model can be selected, and the selection is cleared when that model is deleted.
@MainActor
@Observable
public final class SummaryModelStore: SummaryModelLibrary {
    public enum Status {
        case notDownloaded
        /// `progress` is `nil` until the size of the download is known.
        case downloading(progress: ModelDownloadProgress?)
        case downloaded(size: Int64)
        case failed(any Error)

        public var isDownloaded: Bool {
            if case .downloaded = self { true } else { false }
        }
    }

    public enum StoreError: Error {
        case notDownloaded
        case inUse
        case downloading
    }

    public private(set) var selectedModel: SummaryModel?
    private var statuses: [SummaryModel.ID: Status] = [:]
    private var useCounts: [SummaryModel.ID: Int] = [:]

    @ObservationIgnored private let storage: any SummaryModelStorage
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var downloads: [SummaryModel.ID: Task<Void, Never>] = [:]

    private static let selectedModelIDKey = "summaryModelID"

    public init(storage: any SummaryModelStorage, defaults: UserDefaults) {
        self.storage = storage
        self.defaults = defaults

        storage.removeUnusedFiles(keeping: SummaryModel.all)
        storage.removeTemporaryFiles()
        for model in SummaryModel.all {
            statuses[model.id] = storage.directory(of: model) == nil
                ? .notDownloaded
                : .downloaded(size: storage.size(of: model))
        }
        let selectedID = defaults.string(forKey: Self.selectedModelIDKey)
        selectedModel = SummaryModel.all.first { $0.id == selectedID && status(of: $0).isDownloaded }
        if selectedModel == nil {
            defaults.removeObject(forKey: Self.selectedModelIDKey)
        }
    }

    public func status(of model: SummaryModel) -> Status {
        statuses[model.id] ?? .notDownloaded
    }

    /// Whether a meeting is using `model`, which keeps it from being deleted.
    public func isInUse(_ model: SummaryModel) -> Bool {
        useCounts[model.id, default: 0] > 0
    }

    /// Selects a downloaded model. Does nothing for a model that is not downloaded.
    public func select(_ model: SummaryModel) {
        guard status(of: model).isDownloaded else { return }
        selectedModel = model
        defaults.set(model.id, forKey: Self.selectedModelIDKey)
    }

    /// Starts downloading `model`. Does nothing unless the model is not downloaded or its last download failed.
    /// When no model is selected, the model is selected once downloaded.
    public func download(_ model: SummaryModel) {
        switch status(of: model) {
        case .notDownloaded, .failed:
            break
        case .downloading, .downloaded:
            return
        }
        statuses[model.id] = .downloading(progress: nil)
        downloads[model.id] = Task { [storage] in
            do {
                try await storage.download(model) { [weak self] progress in
                    guard let self, case .downloading = status(of: model) else { return }
                    statuses[model.id] = .downloading(progress: progress)
                }
                setStatus(storage.directory(of: model) == nil
                    ? .failed(StoreError.notDownloaded)
                    : .downloaded(size: storage.size(of: model)), of: model)
                if selectedModel == nil {
                    select(model)
                }
            } catch {
                if Task.isCancelled {
                    // A cancelled download is discarded rather than kept for resuming. Files left by a removal
                    // that fails are removed as unused the next time the store is created.
                    try? storage.removeFiles(of: model)
                    setStatus(.notDownloaded, of: model)
                } else {
                    setStatus(.failed(error), of: model)
                }
            }
            downloads[model.id] = nil
            // Temporary files cannot be told apart by download, so they are removed once no download runs.
            if downloads.isEmpty {
                storage.removeTemporaryFiles()
            }
        }
    }

    /// Cancels the download of `model`. The model becomes not downloaded once the download stops.
    public func cancelDownload(_ model: SummaryModel) {
        downloads[model.id]?.cancel()
    }

    /// Deletes the files of a downloaded model or of a failed download, deselecting the model if selected.
    public func delete(_ model: SummaryModel) throws {
        guard !isInUse(model) else { throw StoreError.inUse }
        guard downloads[model.id] == nil else { throw StoreError.downloading }
        do {
            try storage.removeFiles(of: model)
        } catch {
            // Removing the files may have failed after some of them were removed.
            setStatus(storage.directory(of: model) == nil ? .notDownloaded : .downloaded(size: storage.size(of: model)), of: model)
            throw error
        }
        setStatus(.notDownloaded, of: model)
    }

    public func beginUsing(_ model: SummaryModel) throws -> URL {
        guard status(of: model).isDownloaded, let directory = storage.directory(of: model) else {
            throw StoreError.notDownloaded
        }
        useCounts[model.id, default: 0] += 1
        return directory
    }

    public func endUsing(_ model: SummaryModel) {
        let count = useCounts[model.id, default: 0] - 1
        useCounts[model.id] = count > 0 ? count : nil
    }

    /// Keeps the selection on a downloaded model.
    private func setStatus(_ status: Status, of model: SummaryModel) {
        statuses[model.id] = status
        if selectedModel == model, !status.isDownloaded {
            selectedModel = nil
            defaults.removeObject(forKey: Self.selectedModelIDKey)
        }
    }
}

extension SummaryModelStore {
    public static func live() -> SummaryModelStore {
        SummaryModelStore(storage: HubSummaryModelStorage.live(), defaults: .standard)
    }
}
