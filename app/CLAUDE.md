# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

For the Swift sidecar that this app wraps, see `@../transcribe/CLAUDE.md`.

## Commands

Package manager is **bun**, not npm/yarn. Use the Makefile for anything that touches Tauri — raw `bun run tauri dev/build` **skips the sidecar rebuild** and will run against a stale `src-tauri/binaries/transcribe-<triple>`.

- `make dev` — builds the Swift sidecar (`cd ../transcribe && swift build -c release`), copies it into `src-tauri/binaries/transcribe-$(rustc -vV | sed -n 's/host: //p')`, then `bun run tauri dev`.
- `make build` — same sidecar step, then `bun run tauri build`.
- `make sidecar` / `make clean-sidecar` — just the sidecar copy step, in isolation.
- `bun run build` — frontend-only typecheck + vite build (`tsc && vite build`). Use this to check TypeScript without spinning up Tauri.

TypeScript is `strict` + `noUnusedLocals` + `noUnusedParameters` — unused imports/params are hard errors, not warnings.

For cargo commands against the Tauri crate, pass `--manifest-path src-tauri/Cargo.toml` (e.g. `cargo check --manifest-path src-tauri/Cargo.toml`, `cargo test --manifest-path src-tauri/Cargo.toml`) instead of `cd src-tauri && cargo ...`. The compound form breaks Claude Code's per-subcommand permission matching and triggers an approval prompt every time.

## Architecture

The app is a thin Tauri shell around the Swift `transcribe` CLI. There is **no in-process transcription logic** — Rust spawns the sidecar as a child process and streams its output to the frontend.

Data flow:

```
React (src/App.tsx)
  ├── invoke("start_recording") ─▶ Rust: spawn sidecar `transcribe -o <tmpfile>.jsonl`
  │                                       └── tokio task tails the JSONL file
  │                                             └── app.emit("transcribe://event", <parsed JSON>)
  ├── listen("transcribe://event") ◀─────────────────┘
  └── invoke("stop_recording")  ─▶ Rust: SIGINT → wait(≤10s) → drain tail → rm tmpfile
```

Key invariants in `src-tauri/src/lib.rs`:

- **The sidecar can terminate itself** (crash, permission denied, etc.). Both `stop_recording` and the `CommandEvent::Terminated` handler race to `take()` the `Recording` state under a mutex — whichever wins does the cleanup, the loser no-ops. Don't "simplify" this into a single path.
- **Tail polls because spawn and tail start in parallel.** `JSONLWriter` on the Swift side creates the file lazily, so the tail loop waits for `path.exists()` before opening.
- **UTF-8 chunk boundaries are handled by buffering bytes until `\n`**, then decoding. Don't switch to line-based readers that decode eagerly — multibyte codepoints (Japanese text) will split across reads.
- The tmp JSONL lives in `std::env::temp_dir()/mimi-<ms>.jsonl` and is deleted on stop. It's a transport mechanism, not a user-visible artifact.

Frontend event handling (`src/App.tsx`):

- `TranscribeEvent` is a discriminated union matching the Swift-side JSONL schema. The `switch` ends with `const _exhaustive: never = event` — when Swift adds a new event type, this deliberately fails `tsc` so the frontend can't silently drop events. Keep that pattern.

## Timeline summarizer

While recording, `timeline_loop` in `src-tauri/src/summarizer.rs` produces a timeline of short-interval summary entries. Every 30 s (configurable via env var `MIMI_SUMMARY_INTERVAL_SECONDS`, clamped to ≥10 s) it sends the segments since the last successful entry, plus the last N completed entries as context, to Ollama `/api/chat` and appends a new `TimelineEntry` on success.

- Model: env var `MIMI_OLLAMA_MODEL` (default `qwen3:4b-instruct` — the thinking-free `Qwen3-4B-Instruct-2507`). Host: `MIMI_OLLAMA_HOST` (default `http://localhost:11434`).
- Context window: env var `MIMI_CONTEXT_WINDOW_ENTRIES` (default 10, clamped to ≥1). Only the last N entries are passed in the LLM prompt's `<previous_entries>` block.
- `start_recording` health-checks Ollama via `/api/tags` **before** the sidecar spawns. If Ollama is unreachable or the model isn't pulled, recording fails outright (no sidecar started).
- Concurrency is **serial** via `TimelineState.in_flight: AtomicBool`. Only one generation is ever in flight. If a tick fires while the previous is still running, the tick is skipped and its segments accumulate into the next generation (same mechanism as error carry-over). `InFlightGuard` is a RAII wrapper that releases `in_flight` on Drop — this guarantees release even if the spawned task panics (e.g., on poisoned mutex).
- Carry-over on error: `last_committed_end_index` advances **only** on successful push. On LLM failure the pointer stays put so the failed interval's segments are included in the next successful generation.
- `session_id` guard in the spawned task prevents late-completing generations from a stopped session leaking into a new recording.
- The `TimelineEvent` payload uses a discriminated union tagged by `type`: `generating` (before LLM call), `entry` (with nested `entry: TimelineEntry`), `error` (with `message`). The `switch` in `App.tsx` ends with `const _exhaustive: never = event` to enforce exhaustiveness.
- Full design: `docs/superpowers/specs/2026-04-24-timeline-summarizer-design.md` (historical: `2026-04-24-recording-summarizer-design.md` documented the single rolling-summary predecessor).

## Sidecar bundling

`tauri.conf.json` declares `"externalBin": ["binaries/transcribe"]`. Tauri resolves this at build time to `binaries/transcribe-<target-triple>`, which is why the Makefile copies to that exact filename. The `binaries/` directory is git-ignored and regenerated on every `make sidecar`.

The sidecar process is launched via `tauri-plugin-shell`'s `sidecar("transcribe")` — this requires `tauri-plugin-shell` to be registered in `lib.rs` AND a capability allowing it (currently via `core:default`; sidecar spawn works without an explicit shell capability in Tauri 2 when declared as `externalBin`).

## Permissions (macOS)

The Swift sidecar requires **both** microphone and system audio capture permissions — these are linker-injected into the sidecar's `Info.plist` (see `../transcribe/CLAUDE.md`). The Tauri host app itself does not request these; permission prompts come from the sidecar on first run.
