import Foundation
@testable import MimiKit
import Testing

private let revision = String(repeating: "a", count: 40)

/// A storage in a temporary directory, with snapshots laid out the way the Hub client writes them.
private struct Fixture {
    let directory = FileManager.default.temporaryDirectory.appending(path: "HubSummaryModelStorageTests-\(UUID().uuidString)")
    var legacyDirectory: URL { directory.appending(path: "legacy") }

    var temporaryDirectory: URL { directory.appending(path: "tmp") }

    var storage: HubSummaryModelStorage {
        HubSummaryModelStorage(
            directory: directory.appending(path: "storage"),
            legacyDirectories: [legacyDirectory],
            temporaryDirectory: temporaryDirectory
        )
    }

    func repoDirectory(of model: SummaryModel) -> URL {
        try! storage.repoDirectory(of: model)
    }

    /// Writes a blob and links it from the snapshot, as the Hub client does.
    /// Returns the blob.
    @discardableResult
    func writeSnapshotFile(_ path: String, of model: SummaryModel, revision: String = revision, bytes: Int = 16) throws -> URL {
        let repoDirectory = repoDirectory(of: model)
        let blob = repoDirectory.appending(path: "blobs/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: blob.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: blob)
        let link = repoDirectory.appending(path: "snapshots/\(revision)/\(path)")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: blob)
        return blob
    }

    /// Writes the metadata and lock directories the Hub client keeps beside the files.
    func writeHubBookkeeping(of model: SummaryModel) throws {
        for directory in try storage.directories(of: model).dropFirst() {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func writeCompleteDownload(of model: SummaryModel) throws {
        try writeHubBookkeeping(of: model)
        try writeSnapshotFile("config.json", of: model)
        try writeSnapshotFile("model.safetensors", of: model, bytes: 64 * 1024)
        try storage.markDownloadComplete(of: model, revision: revision, files: ["config.json", "model.safetensors"])
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

struct HubSummaryModelStorageTests {
    @Test func downloadIsIncompleteUntilMarkedComplete() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.writeSnapshotFile("config.json", of: .qwen3_5_4B)
        #expect(fixture.storage.directory(of: .qwen3_5_4B) == nil)

        try fixture.storage.markDownloadComplete(of: .qwen3_5_4B, revision: revision, files: ["config.json"])
        let directory = try #require(fixture.storage.directory(of: .qwen3_5_4B))
        #expect(directory.lastPathComponent == revision)
        #expect(fixture.storage.directory(of: .qwen3_5_9B) == nil)
    }

    @Test func completingDownloadRemovesFilesOfEarlierAttempts() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        // A failed download of an earlier revision.
        let earlierRevision = String(repeating: "b", count: 40)
        let earlierBlob = try fixture.writeSnapshotFile("model.safetensors", of: .qwen3_5_4B, revision: earlierRevision)
        let configBlob = try fixture.writeSnapshotFile("config.json", of: .qwen3_5_4B)
        let modelBlob = try fixture.writeSnapshotFile("model.safetensors", of: .qwen3_5_4B)

        try fixture.storage.markDownloadComplete(of: .qwen3_5_4B, revision: revision, files: ["config.json", "model.safetensors"])

        #expect(fixture.storage.directory(of: .qwen3_5_4B) != nil)
        #expect(fixture.exists(configBlob))
        #expect(fixture.exists(modelBlob))
        #expect(!fixture.exists(earlierBlob))
        #expect(!fixture.exists(fixture.repoDirectory(of: .qwen3_5_4B).appending(path: "snapshots/\(earlierRevision)")))
    }

    @Test func partialSnapshotCannotBeMarkedComplete() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.writeSnapshotFile("config.json", of: .qwen3_5_4B)

        #expect(throws: (any Error).self) {
            try fixture.storage.markDownloadComplete(of: .qwen3_5_4B, revision: revision, files: ["config.json", "model.safetensors"])
        }
        #expect(fixture.storage.directory(of: .qwen3_5_4B) == nil)
    }

    @Test func downloadWithMissingFileIsIncomplete() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.writeCompleteDownload(of: .qwen3_5_4B)
        let directory = try #require(fixture.storage.directory(of: .qwen3_5_4B))

        try FileManager.default.removeItem(at: directory.appending(path: "model.safetensors"))
        #expect(fixture.storage.directory(of: .qwen3_5_4B) == nil)
    }

    @Test func sizeCountsLinkedBlobs() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        #expect(fixture.storage.size(of: .qwen3_5_4B) == 0)

        try fixture.writeCompleteDownload(of: .qwen3_5_4B)
        #expect(fixture.storage.size(of: .qwen3_5_4B) >= 64 * 1024)
    }

    @Test func removeFilesRemovesModel() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.writeCompleteDownload(of: .qwen3_5_4B)
        try fixture.writeCompleteDownload(of: .qwen3_5_9B)

        try fixture.storage.removeFiles(of: .qwen3_5_4B)
        #expect(fixture.storage.directory(of: .qwen3_5_4B) == nil)
        for directory in try fixture.storage.directories(of: .qwen3_5_4B) {
            #expect(!fixture.exists(directory))
        }
        #expect(fixture.storage.directory(of: .qwen3_5_9B) != nil)
        for directory in try fixture.storage.directories(of: .qwen3_5_9B) {
            #expect(fixture.exists(directory))
        }

        // Removing a model without files succeeds.
        try fixture.storage.removeFiles(of: .qwen3_5_4B)
    }

    @Test func removeUnusedFilesKeepsOnlyCompleteDownloadsOfKeptModels() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.writeCompleteDownload(of: .qwen3_5_4B)
        try fixture.writeCompleteDownload(of: .qwen3_5_9B)
        try fixture.writeHubBookkeeping(of: .gemma4_12B)
        try fixture.writeSnapshotFile("config.json", of: .gemma4_12B)
        try FileManager.default.createDirectory(at: fixture.legacyDirectory, withIntermediateDirectories: true)

        fixture.storage.removeUnusedFiles(keeping: [.qwen3_5_4B, .gemma4_12B])

        #expect(fixture.storage.directory(of: .qwen3_5_4B) != nil)
        for directory in try fixture.storage.directories(of: .qwen3_5_4B) {
            #expect(fixture.exists(directory))
        }
        #expect(fixture.storage.directory(of: .qwen3_5_9B) == nil)
        for directory in try fixture.storage.directories(of: .qwen3_5_9B) + fixture.storage.directories(of: .gemma4_12B) {
            #expect(!fixture.exists(directory))
        }
        #expect(!fixture.exists(fixture.legacyDirectory))
    }

    @Test func removeTemporaryFilesRemovesOnlyDownloadLeftovers() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.temporaryDirectory, withIntermediateDirectories: true)
        let names = ["CFNetworkDownload_Ab12Cd.tmp", "hf-download-\(UUID().uuidString).tmp", "unrelated.tmp"]
        for name in names {
            try Data(count: 8).write(to: fixture.temporaryDirectory.appending(path: name))
        }

        fixture.storage.removeTemporaryFiles()
        let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.temporaryDirectory.path(percentEncoded: false))
        #expect(remaining == ["unrelated.tmp"])
    }

    @Test func removeTemporaryFilesLeavesSharedDirectoryAlone() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.temporaryDirectory, withIntermediateDirectories: true)
        let file = fixture.temporaryDirectory.appending(path: "CFNetworkDownload_Ab12Cd.tmp")
        try Data(count: 8).write(to: file)

        HubSummaryModelStorage(directory: fixture.directory.appending(path: "storage")).removeTemporaryFiles()
        #expect(fixture.exists(file))
    }

    @Test func progressCountsFilesStillDownloading() {
        // Laid out as the Hub client tracks a snapshot: one child per file, weighted by its size.
        let progress = Progress(totalUnitCount: 3_000)
        let config = Progress(totalUnitCount: 100, parent: progress, pendingUnitCount: 100)
        let weights = Progress(totalUnitCount: 2_900, parent: progress, pendingUnitCount: 2_900)
        config.completedUnitCount = 100
        weights.completedUnitCount = 1_450

        #expect(progress.completedUnitCount == 100)
        #expect(ModelDownloadProgress(progress) == ModelDownloadProgress(completedBytes: 1_550, totalBytes: 3_000))

        weights.completedUnitCount = 2_900
        #expect(ModelDownloadProgress(progress) == ModelDownloadProgress(completedBytes: 3_000, totalBytes: 3_000))
    }
}
