import Foundation
import MimiKit
import Synchronization
import Testing

private struct TestError: Error {}

private final class FakeStorage: SummaryModelStorage {
    private struct State {
        var completeModels: Set<SummaryModel>
        var downloadError: (any Error)?
        var holdsDownloads = false
        var pendingDownloads: [(model: SummaryModel, continuation: CheckedContinuation<Void, Never>)] = []
        var removedModels: [SummaryModel] = []
        var removeError: (any Error)?
        var keptModels: [SummaryModel]?
        var temporaryFileRemovalCount = 0
    }

    private let state: Mutex<State>

    init(completeModels: Set<SummaryModel> = []) {
        state = Mutex(State(completeModels: completeModels))
    }

    var downloadError: (any Error)? {
        get { state.withLock { $0.downloadError } }
        set { state.withLock { $0.downloadError = newValue } }
    }

    /// When set, downloads wait for ``finishPendingDownloads()``.
    var holdsDownloads: Bool {
        get { state.withLock { $0.holdsDownloads } }
        set { state.withLock { $0.holdsDownloads = newValue } }
    }

    var hasPendingDownload: Bool {
        state.withLock { !$0.pendingDownloads.isEmpty }
    }

    func hasPendingDownload(of model: SummaryModel) -> Bool {
        state.withLock { $0.pendingDownloads.contains { $0.model == model } }
    }

    var removeError: (any Error)? {
        get { state.withLock { $0.removeError } }
        set { state.withLock { $0.removeError = newValue } }
    }

    var removedModels: [SummaryModel] {
        state.withLock { $0.removedModels }
    }

    var keptModels: [SummaryModel]? {
        state.withLock { $0.keptModels }
    }

    var temporaryFileRemovalCount: Int {
        state.withLock { $0.temporaryFileRemovalCount }
    }

    func finishPendingDownloads() {
        let pending = state.withLock { state in
            defer { state.pendingDownloads = [] }
            return state.pendingDownloads
        }
        pending.forEach { $0.continuation.resume() }
    }

    func finishPendingDownload(of model: SummaryModel) {
        let pending = state.withLock { state in
            defer { state.pendingDownloads.removeAll { $0.model == model } }
            return state.pendingDownloads.filter { $0.model == model }
        }
        pending.forEach { $0.continuation.resume() }
    }

    func directory(of model: SummaryModel) -> URL? {
        state.withLock { $0.completeModels.contains(model) } ? URL(filePath: "/models/\(model.id)", directoryHint: .isDirectory) : nil
    }

    func size(of model: SummaryModel) -> Int64 {
        directory(of: model) == nil ? 0 : 1_000
    }

    func download(
        _ model: SummaryModel,
        progressHandler: @MainActor @Sendable @escaping (ModelDownloadProgress) -> Void
    ) async throws {
        await progressHandler(ModelDownloadProgress(completedBytes: 250, totalBytes: 1_000))
        if holdsDownloads {
            await withCheckedContinuation { continuation in
                state.withLock { $0.pendingDownloads.append((model, continuation)) }
            }
        }
        try Task.checkCancellation()
        if let downloadError { throw downloadError }
        state.withLock { _ = $0.completeModels.insert(model) }
    }

    func removeFiles(of model: SummaryModel) throws {
        try state.withLock { state in
            if let removeError = state.removeError { throw removeError }
            state.completeModels.remove(model)
            state.removedModels.append(model)
        }
    }

    func removeUnusedFiles(keeping models: [SummaryModel]) {
        state.withLock { $0.keptModels = models }
    }

    func removeTemporaryFiles() {
        state.withLock { $0.temporaryFileRemovalCount += 1 }
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for condition")
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
private func makeDefaults() -> UserDefaults {
    let name = "SummaryModelStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private extension SummaryModelStore.Status {
    var isNotDownloaded: Bool {
        if case .notDownloaded = self { true } else { false }
    }

    var isDownloading: Bool {
        if case .downloading = self { true } else { false }
    }

    var isFailed: Bool {
        if case .failed = self { true } else { false }
    }
}

@MainActor
struct SummaryModelStoreTests {
    @Test func loadsDownloadedModelsAndRemovesUnusedFiles() {
        let storage = FakeStorage(completeModels: [.qwen3_5_9B])
        let store = SummaryModelStore(storage: storage, defaults: makeDefaults())

        #expect(storage.keptModels == SummaryModel.all)
        #expect(storage.temporaryFileRemovalCount == 1)
        #expect(store.status(of: .qwen3_5_9B).isDownloaded)
        #expect(store.status(of: .qwen3_5_4B).isNotDownloaded)
        #expect(store.selectedModel == nil)
    }

    @Test func restoresSelectionOfDownloadedModel() {
        let defaults = makeDefaults()
        let storage = FakeStorage(completeModels: [.qwen3_5_9B])
        SummaryModelStore(storage: storage, defaults: defaults).select(.qwen3_5_9B)

        let store = SummaryModelStore(storage: storage, defaults: defaults)
        #expect(store.selectedModel == .qwen3_5_9B)
    }

    @Test func dropsSelectionOfModelNoLongerDownloaded() {
        let defaults = makeDefaults()
        SummaryModelStore(storage: FakeStorage(completeModels: [.qwen3_5_9B]), defaults: defaults).select(.qwen3_5_9B)

        let store = SummaryModelStore(storage: FakeStorage(), defaults: defaults)
        #expect(store.selectedModel == nil)

        // The dropped selection does not come back once the model is downloaded again.
        let laterStore = SummaryModelStore(storage: FakeStorage(completeModels: [.qwen3_5_9B]), defaults: defaults)
        #expect(laterStore.selectedModel == nil)
    }

    @Test func cannotSelectModelThatIsNotDownloaded() {
        let store = SummaryModelStore(storage: FakeStorage(), defaults: makeDefaults())
        store.select(.qwen3_5_4B)
        #expect(store.selectedModel == nil)
    }

    @Test func firstDownloadIsSelected() async throws {
        let store = SummaryModelStore(storage: FakeStorage(), defaults: makeDefaults())
        store.download(.qwen3_5_4B)
        try await waitUntil { store.status(of: .qwen3_5_4B).isDownloaded }
        #expect(store.selectedModel == .qwen3_5_4B)

        store.download(.gemma4_12B)
        try await waitUntil { store.status(of: .gemma4_12B).isDownloaded }
        #expect(store.selectedModel == .qwen3_5_4B)
    }

    @Test func reportsDownloadProgress() async throws {
        let storage = FakeStorage()
        storage.holdsDownloads = true
        let store = SummaryModelStore(storage: storage, defaults: makeDefaults())
        store.download(.qwen3_5_4B)
        #expect(store.status(of: .qwen3_5_4B).isDownloading)

        try await waitUntil { storage.hasPendingDownload }
        guard case let .downloading(progress) = store.status(of: .qwen3_5_4B) else {
            Issue.record("Unexpected status: \(store.status(of: .qwen3_5_4B))")
            return
        }
        #expect(progress == ModelDownloadProgress(completedBytes: 250, totalBytes: 1_000))

        storage.finishPendingDownloads()
        try await waitUntil { store.status(of: .qwen3_5_4B).isDownloaded }
    }

    @Test func failedDownloadCanBeRetried() async throws {
        let storage = FakeStorage()
        storage.downloadError = TestError()
        let store = SummaryModelStore(storage: storage, defaults: makeDefaults())
        store.download(.qwen3_5_4B)
        try await waitUntil { store.status(of: .qwen3_5_4B).isFailed }
        #expect(store.selectedModel == nil)

        storage.downloadError = nil
        store.download(.qwen3_5_4B)
        try await waitUntil { store.status(of: .qwen3_5_4B).isDownloaded }
        #expect(store.selectedModel == .qwen3_5_4B)
    }

    @Test func cancelledDownloadIsDiscarded() async throws {
        let storage = FakeStorage()
        storage.holdsDownloads = true
        let store = SummaryModelStore(storage: storage, defaults: makeDefaults())
        store.download(.qwen3_5_4B)
        try await waitUntil { storage.hasPendingDownload }

        store.cancelDownload(.qwen3_5_4B)
        storage.finishPendingDownloads()
        try await waitUntil { store.status(of: .qwen3_5_4B).isNotDownloaded }
        #expect(storage.removedModels == [.qwen3_5_4B])
        #expect(store.selectedModel == nil)
    }

    @Test func temporaryFilesAreRemovedOnceNoDownloadRuns() async throws {
        let storage = FakeStorage()
        storage.holdsDownloads = true
        let store = SummaryModelStore(storage: storage, defaults: makeDefaults())
        store.download(.qwen3_5_4B)
        store.download(.qwen3_5_9B)
        try await waitUntil { storage.hasPendingDownload(of: .qwen3_5_4B) && storage.hasPendingDownload(of: .qwen3_5_9B) }

        // The first download stops while the second still runs.
        store.cancelDownload(.qwen3_5_4B)
        storage.finishPendingDownload(of: .qwen3_5_4B)
        try await waitUntil { store.status(of: .qwen3_5_4B).isNotDownloaded }
        #expect(storage.temporaryFileRemovalCount == 1)

        storage.finishPendingDownload(of: .qwen3_5_9B)
        try await waitUntil { store.status(of: .qwen3_5_9B).isDownloaded }
        #expect(storage.temporaryFileRemovalCount == 2)
    }

    @Test func deletingSelectedModelClearsSelection() async throws {
        let defaults = makeDefaults()
        let storage = FakeStorage(completeModels: [.qwen3_5_4B])
        let store = SummaryModelStore(storage: storage, defaults: defaults)
        store.select(.qwen3_5_4B)

        try store.delete(.qwen3_5_4B)
        #expect(store.status(of: .qwen3_5_4B).isNotDownloaded)
        #expect(store.selectedModel == nil)
        #expect(storage.removedModels == [.qwen3_5_4B])
        #expect(SummaryModelStore(storage: storage, defaults: defaults).selectedModel == nil)
    }

    @Test func modelInUseCannotBeDeleted() throws {
        let storage = FakeStorage(completeModels: [.qwen3_5_4B])
        let store = SummaryModelStore(storage: storage, defaults: makeDefaults())
        _ = try store.beginUsing(.qwen3_5_4B)
        _ = try store.beginUsing(.qwen3_5_4B)
        #expect(store.isInUse(.qwen3_5_4B))

        #expect(throws: SummaryModelStore.StoreError.inUse) { try store.delete(.qwen3_5_4B) }
        store.endUsing(.qwen3_5_4B)
        #expect(throws: SummaryModelStore.StoreError.inUse) { try store.delete(.qwen3_5_4B) }
        store.endUsing(.qwen3_5_4B)
        #expect(!store.isInUse(.qwen3_5_4B))

        try store.delete(.qwen3_5_4B)
        #expect(storage.removedModels == [.qwen3_5_4B])
    }

    @Test func modelBeingDownloadedCannotBeDeleted() async throws {
        let storage = FakeStorage()
        storage.holdsDownloads = true
        let store = SummaryModelStore(storage: storage, defaults: makeDefaults())
        store.download(.qwen3_5_4B)

        #expect(throws: SummaryModelStore.StoreError.downloading) { try store.delete(.qwen3_5_4B) }
        try await waitUntil { storage.hasPendingDownload }
        storage.finishPendingDownloads()
        try await waitUntil { store.status(of: .qwen3_5_4B).isDownloaded }
    }

    @Test func failedDeletionKeepsDownloadedModel() {
        let storage = FakeStorage(completeModels: [.qwen3_5_4B])
        storage.removeError = TestError()
        let store = SummaryModelStore(storage: storage, defaults: makeDefaults())
        store.select(.qwen3_5_4B)

        #expect(throws: TestError.self) { try store.delete(.qwen3_5_4B) }
        #expect(store.status(of: .qwen3_5_4B).isDownloaded)
        #expect(store.selectedModel == .qwen3_5_4B)
    }

    @Test func modelThatIsNotDownloadedCannotBeUsed() {
        let store = SummaryModelStore(storage: FakeStorage(), defaults: makeDefaults())
        #expect(throws: SummaryModelStore.StoreError.notDownloaded) { try store.beginUsing(.qwen3_5_4B) }
        #expect(!store.isInUse(.qwen3_5_4B))
    }
}
