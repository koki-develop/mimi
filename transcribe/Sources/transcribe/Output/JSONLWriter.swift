import Foundation

public struct Header: Sendable, Codable, Equatable {
    public let type: String
    public let startedAt: Date
    public let model: String

    public init(startedAt: Date, model: String) {
        self.type = "header"
        self.startedAt = startedAt
        self.model = model
    }

    enum CodingKeys: String, CodingKey {
        case type
        case startedAt = "started_at"
        case model
    }
}

public enum JSONLWriterError: Error, Equatable {
    case outputAlreadyExists
    case writeFailed(String)
}

public actor JSONLWriter {
    private let url: URL
    private var handle: FileHandle?

    public init(output: URL, header: Header) throws {
        self.url = output

        if FileManager.default.fileExists(atPath: output.path) {
            throw JSONLWriterError.outputAlreadyExists
        }

        guard FileManager.default.createFile(atPath: output.path, contents: nil) else {
            throw JSONLWriterError.writeFailed("could not create file at \(output.path)")
        }

        let handle = try FileHandle(forWritingTo: output)
        self.handle = handle

        let line = try JSONLSerializer.encode(header) + Data([0x0A])
        try handle.write(contentsOf: line)
        try handle.synchronize()
    }

    public func write(_ segment: Segment) throws {
        guard let handle else {
            throw JSONLWriterError.writeFailed("writer is closed")
        }
        let line = try JSONLSerializer.encode(segment) + Data([0x0A])
        try handle.write(contentsOf: line)
        try handle.synchronize()
    }

    public func close() throws {
        guard let handle else { return }
        try handle.synchronize()
        try handle.close()
        self.handle = nil
    }
}
