# Sources/TranscribeCore/Output

**`JSONLWriter` refuses to overwrite existing files** via `O_EXCL`; `Pipeline.run` also pre-checks. Preserve this — it's the user's crash-safety net.

**`EventLogger.flushedWithErrors()`** lets `Pipeline.run` surface a session's JSONL write failures as `PipelineError.ioFailed` (non-zero CLI exit). The 1-shot stderr notification on first write failure is intentional (avoids flood); the boolean is what reaches the CLI exit code.
