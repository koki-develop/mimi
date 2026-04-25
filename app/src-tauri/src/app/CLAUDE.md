# src-tauri/src/app

Sidecar lifecycle, tail ingestion, and the `#[tauri::command]` handlers.

## Modules

- `state.rs` — `AppState` (managed by Tauri via `.manage(...)`), `Recording` (the per-session bundle of pid, cancel flags, spawned tasks, tmp path).
- `commands.rs` — the two Tauri commands `start_recording` / `stop_recording`, the decomposed spawn helpers (`make_output_path`, `spawn_sidecar`, `spawn_event_monitor`, `spawn_summarizer_task`), and the shared `shutdown_recording` cleanup helper. The tail task is spawned inline via `tokio::spawn(tail::tail_file(...))`.
- `tail.rs` — `tail_file` plus pure helpers `drain_complete_lines` (byte-level UTF-8 line splitter) and `parse_jsonl_segment` (JSON → `Segment`). Owns `EVENT_TRANSCRIBE`.

## Invariants

- **Sidecar self-termination race.** `stop_recording` and the `CommandEvent::Terminated` handler both race to `.take()` the `Recording` under `state.recording`'s mutex. The winner calls `shutdown_recording(...)`; the loser no-ops. **Do not collapse this race into a single path.** The 7-step cleanup body is shared via `shutdown_recording`, but the race structure remains — that's what prevents double-cleanup.
- **`shutdown_recording(recording, state, send_sigint)` — 7-step ordering.** Step order is fixed (design §4.2): (1) `summarizer_cancel` + `session_id=0` → (2-3) SIGINT + wait for Terminated ≤10s → (4) 200ms sleep to let tail's EOF polling drain → (5) `tail_cancel` + await → (6) summarizer join → (7) `remove_file`. `send_sigint=false` from the Terminated path skips steps 2-3 (the sidecar already exited).
- **Tail polls before open.** `wait_for_file` spins on `path.exists()` because the Swift `JSONLWriter` creates the file lazily on the first write.
- **Byte-level UTF-8 buffering.** `drain_complete_lines` accumulates raw bytes and only yields lines once `\n` terminates them. Eager `String::from_utf8` decode would split multibyte Japanese codepoints across reads.
- **Tmp JSONL is transport-only.** Path is `std::env::temp_dir()/mimi-<unix-ms>.jsonl`, removed on stop. Never a user-visible artifact.
- **Event name constants.** `EVENT_TRANSCRIBE` (here, in `tail.rs`) and `EVENT_TIMELINE` (in `summarizer/events.rs`). Keep the source of truth next to the single emitter.

## Session id

- `session_id = SystemTime::UNIX_EPOCH-derived millis as u64`. Stored in `state.current_session_id` only *after* sidecar spawn succeeds (so a spawn failure doesn't leave a stale id behind). Cleared to 0 at the very start of `shutdown_recording` to fence off in-flight summarizer child tasks.
