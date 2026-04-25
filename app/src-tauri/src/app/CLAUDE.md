# src-tauri/src/app

Daemon lifecycle (long-lived sidecar), wire-protocol IPC, and the
`#[tauri::command]` handlers.

## Modules

- `state.rs` — `AppState` (managed by Tauri via `.manage(...)`). Holds `Daemon`
  + the shared `current_session_id` (the summarizer-guard invariant from
  `summarizer/CLAUDE.md` still applies — `current_session_id` is non-zero iff a
  session is in progress).
- `commands.rs` — the two thin Tauri commands `start_recording` / `stop_recording`.
  They write a single JSON line to the daemon's stdin (`{"type":"start"}\n` or
  `{"type":"stop"}\n`) and return. All state transitions and summarizer cleanup
  happen reactively via the stdout reader task in `daemon.rs`.
- `daemon.rs` — `Daemon` struct (owns `tokio::sync::Mutex<CommandChild>` for stdin
  writes), `DaemonCommand` (wire-protocol enum), `DaemonState` (state-machine
  enum with `Dead` after `Terminated`), the stdout reader task (parses each line,
  forwards verbatim to the frontend, dispatches typed handling for
  `state_changed` / `session_started` / `segment` / `session_stopped`), and the
  per-session `SessionContext` (segments buffer + summarizer task handle).

## Invariants

- **Daemon spawned during `tauri::Builder::setup`.** Model load begins before
  the webview connects. `Daemon::spawn` does NOT block on model load — it
  returns as soon as the child process is created. Model-load completion arrives
  asynchronously as `state_changed { ready }`.
- **`Daemon::send_command` short-circuits on `Dead`/`Fatal`.** Returns
  `"daemon is dead"` without attempting a write.
- **Per-session bookkeeping lives in the reader task, not in `AppState`.**
  `SessionContext` (segment buffer + summarizer task + cancel flag) is created
  on `session_started`, dropped on `session_stopped` / `Terminated` /
  `state_changed { fatal }`. This keeps `start_recording` / `stop_recording`
  Tauri commands trivially small.
- **`current_session_id` semantics preserved.** Reader sets it to a fresh
  millis-since-epoch value on `session_started`, clears to `0` on session end.
  Summarizer child tasks still capture it by value and discard late completions
  whose id no longer matches — see `summarizer/CLAUDE.md` "Session guard".
- **Synthetic `fatal` on `Terminated`.** If `Terminated` arrives without the
  daemon having emitted `state_changed { fatal }` first (e.g. SIGKILL), the
  reader emits a synthetic `fatal` event so the frontend reacts uniformly.
  Suppressed if `state` was already `Fatal`.
- **Daemon lifetime == app lifetime.** The daemon is spawned in
  `tauri::Builder::setup` and lives until the app exits (or until the daemon
  itself dies, in which case it stays `Dead`/`Fatal` until the user restarts the
  app). No recording state survives an app restart — there is no on-disk
  persistence for in-progress sessions.

## Wire protocol summary

Detailed in `docs/superpowers/specs/2026-04-25-transcribe-daemon-design.md`.
- stdin: `{"type":"start"}` / `{"type":"stop"}`, line-delimited.
- stdout: `Event` enum encoded JSONL (mirror of the Swift schema), forwarded
  verbatim to the frontend on `transcribe://event`. `EVENT_TRANSCRIBE` constant
  is the single source of truth, defined in `daemon.rs`.
