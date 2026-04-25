import Foundation
import Testing

@testable import TranscribeCore

@Suite("CommandSource")
struct CommandSourceTests {
  @Test("yields parsed commands in order")
  func yieldsCommandsInOrder() async throws {
    let pipe = Pipe()
    let source = CommandSource(handle: pipe.fileHandleForReading)

    pipe.fileHandleForWriting.write(#"{"type":"start"}"#.data(using: .utf8)!)
    pipe.fileHandleForWriting.write(Data([0x0A]))
    pipe.fileHandleForWriting.write(#"{"type":"stop"}"#.data(using: .utf8)!)
    pipe.fileHandleForWriting.write(Data([0x0A]))
    try pipe.fileHandleForWriting.close()

    var collected: [CommandSourceItem] = []
    for await item in source.stream() {
      collected.append(item)
    }
    #expect(collected == [.command(.start), .command(.stop)])
  }

  @Test("yields parseError for malformed lines and continues")
  func yieldsParseErrorAndContinues() async throws {
    let pipe = Pipe()
    let source = CommandSource(handle: pipe.fileHandleForReading)

    pipe.fileHandleForWriting.write("not-json\n".data(using: .utf8)!)
    pipe.fileHandleForWriting.write(#"{"type":"start"}"#.data(using: .utf8)!)
    pipe.fileHandleForWriting.write(Data([0x0A]))
    try pipe.fileHandleForWriting.close()

    var collected: [CommandSourceItem] = []
    for await item in source.stream() {
      collected.append(item)
    }
    #expect(collected.count == 2)
    if case .parseError(let raw) = collected[0] {
      #expect(raw == "not-json")
    } else {
      Issue.record("expected parseError, got \(collected[0])")
    }
    #expect(collected[1] == .command(.start))
  }

  @Test("ends stream on EOF")
  func endsOnEOF() async throws {
    let pipe = Pipe()
    let source = CommandSource(handle: pipe.fileHandleForReading)
    try pipe.fileHandleForWriting.close()

    var count = 0
    for await _ in source.stream() {
      count += 1
    }
    #expect(count == 0)
  }
}
