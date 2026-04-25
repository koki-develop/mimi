# src-tauri/src/summarizer

Timeline-summary pipeline: every tick during recording, send new segments + the last N entries to Ollama `/api/chat`, push a `TimelineEntry` on success.

Full behavioral design: `docs/superpowers/specs/2026-04-24-timeline-summarizer-design.md`.

## Modules

- `prompt.rs` — domain types (`Segment`, `Source`, `TimelineEntry`) and prompt assembly (`build_entry_prompt`, `escape_xml`, `iso_to_hms`, `format_segments`, `format_previous_entries`, `SYSTEM_PROMPT_ENTRY`). The domain types live here because they are the prompt's inputs/outputs; other submodules import them via `use crate::summarizer::...` thanks to the facade in `mod.rs`.
- `client.rs` — Ollama HTTP layer. `SummarizerConfig { http, host, model }`, `SummaryError`, `generate_summary`, `health_check`. Ollama request/response types are file-private.
- `events.rs` — `TimelineEmitter` trait, `TauriTimelineEmitter` impl, `TimelineEventPayload` discriminated union, `EVENT_TIMELINE`. Also hosts a `#[cfg(test)] pub(super) mod test_support` exposing `MockTimelineEmitter` for reuse by `timeline.rs` tests.
- `timeline.rs` — `TimelineState` (session-scoped), `InFlightGuard` (RAII), `wait_for_cancel`, `timeline_loop(TimelineLoopParams)`.

## Public API facade

`mod.rs` keeps submodules private (`mod client;` etc.) and re-exports only the items consumed outside this module via `pub(crate) use`. Consumers write `crate::summarizer::TimelineState`, not `crate::summarizer::timeline::TimelineState`. Internal reorganization cannot leak through paths.

## Invariants

- **Ollama health check before sidecar spawn.** `start_recording` hits `/api/tags` *before* spawning the Swift sidecar. Unreachable host or missing model → recording fails outright with a user-facing error string.
- **Serial generation.** `TimelineState.in_flight: AtomicBool` guarantees one generation at a time. Overlapping ticks skip; their new segments accumulate into the next run. `InFlightGuard` (RAII) releases the flag on `Drop`, so a panicking spawned task cannot wedge the loop permanently.
- **Error carry-over.** `last_committed_end_index` advances *only* on successful push. Failed intervals retry implicitly on the next tick because `segments[start_index..end_index]` re-includes them.
- **Session guard.** Each spawned summarizer child task captures `state.session_id` by value and compares to `current_session_id` on completion — late completions from stopped sessions are discarded without emit.
- **`TimelineEvent` payload shape.** Discriminated union tagged by `type`: `generating` (`{session_id, generation, timestamp}`), `entry` (`{session_id, generation, entry: TimelineEntry}`), `error` (`{session_id, generation, timestamp, message}`). The frontend relies on this shape.

## Env vars (read by `crate::config::Config::from_env`)

- `MIMI_OLLAMA_HOST` — default `http://localhost:11434`
- `MIMI_OLLAMA_MODEL` — default `qwen3:4b-instruct` (thinking-free `Qwen3-4B-Instruct-2507`)
- `MIMI_SUMMARY_INTERVAL_SECONDS` — default 30, clamped ≥10
- `MIMI_CONTEXT_WINDOW_ENTRIES` — default 10, clamped ≥1
