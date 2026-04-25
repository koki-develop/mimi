# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

Use the Makefile, not raw `swift` — `make test` injects framework search paths / rpaths so `Testing.framework` resolves on Command Line Tools-only machines (plain `swift test` only works with full Xcode installed).

- `make build` / `make test` / `make clean`
- `make run ARGS="-o out.jsonl"` — `ARGS` is forwarded to `swift run transcribe`.
- `make fmt` / `make lint` — `swift format` (Swift 6 toolchain built-in) against `Sources` + `Tests`. `lint` runs with `--strict` (warnings fail). No `.swift-format` config file; defaults are used.
- Single test: `swift test --filter <Suite>.<Test>` (add the same `-Xswiftc -F …` flags the Makefile uses if CLT-only).

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

## Pipeline shape

`TranscribeCommand` → `Pipeline.run` wires:

`AudioCapture` (`SCStream` covering mic + system) → per-source `AudioOutputTap` (delegates to `AudioConversionPipeline` for streaming `AVAudioConverter` to 16 kHz mono Float32; `SampleBufferClockMapper` anchors PTS to wall-clock `Date`) → `AsyncStream<CapturedAudioChunk>` → `TimedSampleAccumulator` (pads gaps / trims overlaps) → `windowSeconds` 秒のウィンドウ → `EnergyVAD` gate → `WhisperKit.transcribe` (via `Transcriber` actor) → dedup consecutive identical text → `JSONLWriter` (one event per line, ISO8601 w/ fractional seconds, local TZ) + `ConsoleReporter` (stderr).

`Pipeline.run` runs four parallel tasks under `withTaskGroup`: mic transcriber consumer, system transcriber consumer, `CaptureDiagnostic` drain (warning + verbose status routed to `EventLogger`), and `signalWaiter` (= `SignalHandler.waitForSIGINT` 経由で SIGINT を `SIG_IGN` + `DispatchSource` で trap、Ctrl-C で stream を clean に閉じる)。`ShutdownCoordinator` actor が segment counter と stop reason を集約し、`Outcome` (sum 型) を返して Pipeline が `error`/`sessionStopped` イベントを順序通り発行する。

Pipeline の終端では以下を順に判定して non-zero exit code を返す:
1. capture が予期せず停止 (stream error) → `PipelineError.captureFailed`
2. JSONL write 失敗 (`EventLogger.flushedWithErrors`) → `PipelineError.ioFailed`
3. JSONL close 失敗 → `PipelineError.ioFailed`
