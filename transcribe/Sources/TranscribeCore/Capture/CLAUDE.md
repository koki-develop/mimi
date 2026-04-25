# Sources/TranscribeCore/Capture

**A single `SCStream` carries both mic and system audio.** It needs a dummy 2×2 @ 1fps video config even though no video output is registered — `SCStream` refuses audio-only setups. The config lives in `AudioCapture.start()`.

**No fire-and-forget `Task { reporter.* }` in this module.** All non-fatal capture-layer messages flow via `AsyncStream<CaptureDiagnostic>` (synchronous yield from `AudioOutputTap`) to be drained by `TranscribeDaemon.runSession`'s diagnostic task. This prevents shutdown races where actor hops would write to a closed `StdoutEventWriter`.

**`@unchecked Sendable` rationale.** `AudioOutputTap`, `SCStreamCoordinator`, `SessionStartTracker`, `StreamErrorBox` all use `@unchecked Sendable` because they are reached from synchronous `SCStream*` delegate / output callbacks (`stream(_:didStopWithError:)`, `stream(_:didOutputSampleBuffer:of:)`) that cannot `await`. Wrapping those in `Task { await actor.… }` would (a) reorder buffers under load and (b) reintroduce the very fire-and-forget pattern this module forbids. The lock-based reference type is the correct tool here; don't "fix" this to actor.
