# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

Use the Makefile, not raw `swift` — `make test` injects framework search paths / rpaths so `Testing.framework` resolves on Command Line Tools-only machines (plain `swift test` only works with full Xcode installed).

- `make build` / `make test` / `make clean`
- `make run ARGS="..."` — `ARGS` is forwarded to `swift run transcribe`. **NOTE:** the `test` target does NOT forward `ARGS`. To run a single test, use raw `swift test --filter <Suite>.<Test>` (with the same `-Xswiftc -F …` flags the Makefile injects when CLT-only).
- `make fmt` / `make lint` — `swift format` (Swift 6 toolchain built-in) against `Sources` + `Tests`. `lint` runs with `--strict` (warnings fail). No `.swift-format` config file; defaults are used.

Tests use **swift-testing** (`@Suite` / `@Test` / `#expect`), not XCTest.

## Platform

macOS 15+, Swift 6.3 with `swiftLanguageModes: [.v6]` (strict concurrency). Dependencies (`WhisperKit`, `swift-argument-parser`) are imported with `@preconcurrency` where their types aren't `Sendable`-clean — follow that pattern in any new file that touches WhisperKit.

## Targets

`Package.swift` defines three product targets:

- **`TranscribeCore`** (library) — domain logic. Depends on WhisperKit.
- **`TranscribeCLI`** (library) — `TranscribeCommand: AsyncParsableCommand`. Depends on `TranscribeCore` + `ArgumentParser`. Lives in `Sources/TranscribeCLI/`.
- **`transcribe`** (executable) — thin `Sources/transcribe/Entry.swift` `@main` wrapper that calls `TranscribeCommand.main()`. Depends only on `TranscribeCLI`.

Two test targets:

- **`TranscribeCoreTests`** — covers `TranscribeCore`. Uses `@testable import TranscribeCore` for internal types.
- **`TranscribeCLITests`** — covers `TranscribeCLI`. Uses `@testable import TranscribeCLI`.

## Build quirks

**`Info.plist` is linker-injected**, not bundled. `Package.swift` uses `unsafeFlags` with `-sectcreate __TEXT __info_plist` because the executable is a plain SwiftPM target, not an `.app`. The plist is `exclude`d from resources. `NSAudioCaptureUsageDescription` + `NSMicrophoneUsageDescription` are both required or the first permission prompt crashes (covered by `InfoPlistTests`).

## Daemon shape

`TranscribeCommand` → `TranscribeDaemon.run()` performs:

1. `signal(SIGPIPE, SIG_IGN)` (`Sources/TranscribeCore/Daemon/TranscribeDaemon.swift`).
2. emit `state_changed { loading_model }`.
3. `dependencies.transcriberFactory.loadModels(modelName:logger:)` — boot-time WhisperKit load × 2 (mic ANE / system GPU). On failure: emit `state_changed { fatal }` + `error`, throw `DaemonError.modelLoadFailed`, exit non-zero.
4. emit `state_changed { ready }`.
5. command loop: `for await item in dependencies.commandSource()` (multiplexed with internal session-completion signals via `DaemonLoopEvent`). For each `start`: permission check (per-call) → fresh `AudioCapture` (per-session) → fresh `Transcriber` × 2 from the shared `LoadedModels` → emit `session_started` then `state_changed { capturing }` → spawn the consumer task group. For each `stop`: emit `state_changed { stopping }` → record stop reason in `ShutdownCoordinator` → `capture.stop()` → consumer group drains → emit `session_stopped { reason: stop }` + `state_changed { ready }`.
6. stdin EOF (Tauri host closing pipes during shutdown): clean exit, no `state_changed` events emitted on EOF.

`ShutdownCoordinator` (still per-session) tracks segment count + first stop reason; mid-session capture errors emit `session_stopped { reason: error }` and the daemon stays alive (returns to `ready`).

## Wire protocol

Stdin/stdout, line-delimited JSON. See `docs/superpowers/specs/2026-04-25-transcribe-daemon-design.md` for the schema. The Swift `Event` discriminated union (`Sources/TranscribeCore/Output/Event.swift`) is the wire format on the daemon → host direction; `DaemonCommand` (`Sources/TranscribeCore/Daemon/DaemonCommand.swift`) is the host → daemon side.
