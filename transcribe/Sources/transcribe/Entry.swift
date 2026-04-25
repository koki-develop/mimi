import TranscribeCLI

/// Executable target の entry point。`AsyncParsableCommand` の async main を呼ぶための薄い wrapper。
/// `TranscribeCommand` 自体は `TranscribeCLI` library に住んでいるため unit test 可能。
@main
enum Entry {
  static func main() async {
    await TranscribeCommand.main()
  }
}
