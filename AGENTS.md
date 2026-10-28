# AGENTS.md

## Setup

Run `mise bootstrap` once after cloning. It installs the tools in `mise.toml` and then builds `MimiKit/Native/EchoCanceller/build/CEchoCanceller.xcframework`, which is not checked in and without which MimiKit does not build. After changing anything in `MimiKit/Native/EchoCanceller/`, rebuild it with `mise run build:echo-canceller`.

## Build and test

- All package tests: `swift test --package-path MimiKit`
- Some tests: `swift test --package-path MimiKit --filter <regex>`, matched against test IDs, for example `--filter TranscriptTests` or `--filter blankResultsAreIgnored`
- App: `xcodebuild build -project Mimi.xcodeproj -scheme Mimi -destination 'platform=macOS' -derivedDataPath build/DerivedData -skipMacroValidation -skipPackagePluginValidation -quiet`

`swift` and `xcodebuild` fail inside the Claude Code sandbox: SwiftPM cannot apply its own sandbox there, and both write outside the project. Run them outside the sandbox.

## Where code goes

- Behavior lives in MimiKit, with its tests. `Mimi/` holds the SwiftUI views and settings that present it.
- MimiKit types take their dependencies through protocols (`AudioSource`, `TranscriptionEngine`, `EchoCanceller`, `TextGeneratorProvider`, `SummaryModelStorage`, …). Each `live` factory wires the real implementations; tests pass fakes.
- Tests never run MLX. Under `swift test`, MLX cannot load its Metal shaders, and the first MLX call aborts the whole test process.

## Concurrency

The app target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and approachable concurrency. MimiKit uses the Swift 6 defaults, where declarations are nonisolated unless marked. Code moved between the two changes isolation. MimiKit states isolation explicitly: types the UI drives are `@MainActor`, and types used from audio threads are `Sendable`, keeping their state behind a `Mutex` or a private queue.

## Echo canceller

The Swift side calls only the C interface in `MimiKit/Native/EchoCanceller/include/echo_canceller.h`. The build hides every symbol not listed in `exported_symbols.txt`, so a new function is added to both.

## Conventions

- UI text is Japanese, written inline in the views. Code, comments, log messages, error descriptions, and commit messages are English.
- Doc comments state the contract callers rely on: what a call guarantees, which thread a callback runs on, when callbacks stop. Inline comments explain why the code is the way it is.

## Managed files

APM installs `.claude/skills/openspec-*/` from `apm.yml`, pinned in `apm.lock.yaml`. `apm install` overwrites edits to them.
