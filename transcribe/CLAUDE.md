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

macOS 15+, Swift 6.3 with `swiftLanguageModes: [.v6]` (strict concurrency). Dependencies (`WhisperKit`, `swift-argument-parser`) are imported with `@preconcurrency` where their types aren't `Sendable`-clean — follow that pattern.

## Non-obvious things

- **`Info.plist` is linker-injected**, not bundled. `Package.swift` uses `unsafeFlags` with `-sectcreate __TEXT __info_plist` because this is a plain SwiftPM executable, not an `.app`. The plist is `exclude`d from resources. `NSAudioCaptureUsageDescription` + `NSMicrophoneUsageDescription` are both required or the first permission prompt crashes.
- **Two WhisperKit instances are loaded for the same model** in `App.run` — mic on `.cpuAndNeuralEngine`, system on `.cpuAndGPU`. This is intentional to avoid ANE contention when both streams decode concurrently; don't "dedupe" it.
- **A single `SCStream` carries both mic and system audio.** It needs a dummy 2×2 @ 1fps video config even though no video output is registered — `SCStream` refuses audio-only setups.
- **Transcription language is hard-coded to `"ja"`** in `Transcriber.swift` (`DecodingOptions.language`). Any multilingual support requires plumbing through `TranscribeCommand`.
- **`JSONLWriter` refuses to overwrite existing files**; `App.run` also pre-checks. Preserve this — it's the user's crash-safety net.

## Pipeline shape

`TranscribeCommand` → `App.run` wires:

`SCStream` (mic + system) → per-source `OutputHandler` (streaming `AVAudioConverter` to 16 kHz mono Float32, `SampleBufferClockMapper` anchors PTS to wall-clock `Date`) → `AsyncStream<CapturedAudioChunk>` → `TimedSampleAccumulator` (pads gaps / trims overlaps) → 5 s windows → `EnergyVAD` gate → `WhisperKit.transcribe` → dedup consecutive identical text → `JSONLWriter` (header line + segment lines, ISO8601 w/ fractional seconds, local TZ) + `ConsoleReporter` (stderr).

A `withThrowingTaskGroup` runs mic consumer, system consumer, and `SignalHandler.waitForSIGINT` in parallel; SIGINT is trapped via `SIG_IGN` + `DispatchSource` so Ctrl-C stops capture cleanly instead of killing mid-write.
