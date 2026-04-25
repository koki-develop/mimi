# Sources/TranscribeCore/Output

**`StdoutEventWriter`** is the production `EventSink` — writes one JSON line per `Event` to `FileHandle.standardOutput`. EPIPE on write surfaces as a `StdoutEventWriterError.closed`-equivalent and propagates up to `TranscribeDaemon.run`. Do not add another sink without extending the `EventSink` protocol.

**`EventLogger.flushedWithErrors()`** is no longer wired into a daemon-level exit-code path (the daemon doesn't have a single end-of-run point that can report it). The 1-shot stderr notification on first write failure is still intentional (avoids flood); consumers needing per-session reliability should treat the daemon's `error` event stream as the source of truth.
