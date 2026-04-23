import Foundation

public struct FileHandleTextStream: TextOutputStream, Sendable {
    let handle: FileHandle
    public init(_ handle: FileHandle) { self.handle = handle }
    public func write(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }
}

public actor ConsoleReporter {
    private var stream: any TextOutputStream
    private let formatter: DateFormatter

    public init(stream: any TextOutputStream = FileHandleTextStream(.standardError)) {
        self.stream = stream

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.S"
        formatter.timeZone = .current
        self.formatter = formatter
    }

    public func report(_ segment: Segment) {
        let prefix = segment.source == .mic ? "[mic]" : "[sys]"
        let timestamp = formatter.string(from: segment.timestamp)
        stream.write("\(prefix) \(timestamp)  \(segment.text)\n")
    }

    public func reportStatus(_ message: String) {
        stream.write("\(message)\n")
    }

    public func reportWarning(_ message: String) {
        stream.write("Warning: \(message)\n")
    }

    public func reportError(_ message: String) {
        stream.write("Error: \(message)\n")
    }
}
