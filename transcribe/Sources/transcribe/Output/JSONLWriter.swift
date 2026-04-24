import Darwin
import Foundation

public enum JSONLWriterError: Error, Equatable {
    case outputAlreadyExists
    case writeFailed(String)
}

public actor JSONLWriter {
    private let url: URL
    private var handle: FileHandle?

    public init(output: URL) throws {
        self.url = output

        // 既存ファイルを上書きしないことを保証するため、O_EXCL で排他作成する。
        // FileManager.createFile は既存ファイルを黙って上書きするため TOCTOU race に対して安全でない。
        let fd = output.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        }
        if fd < 0 {
            if errno == EEXIST {
                throw JSONLWriterError.outputAlreadyExists
            }
            let msg = String(cString: strerror(errno))
            throw JSONLWriterError.writeFailed("could not create file at \(output.path): \(msg)")
        }
        self.handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    public func write(_ event: Event) throws {
        guard let handle else {
            throw JSONLWriterError.writeFailed("writer is closed")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let data = try encoder.encode(event) + Data([0x0A])
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    public func close() throws {
        guard let handle else { return }
        // synchronize() が throw してもハンドルは必ず解放する。
        // self.handle は無条件で nil 化して close の再呼び出しが no-op になることを保証する。
        // synchronize と handle.close の両方で起きうるエラーを拾い、最初のエラーを throw する。
        defer { self.handle = nil }
        var firstError: Error?
        do { try handle.synchronize() } catch { firstError = error }
        do { try handle.close() } catch { if firstError == nil { firstError = error } }
        if let firstError { throw firstError }
    }
}
