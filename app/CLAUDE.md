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

## Sidecar bundling

`tauri.conf.json` declares `"externalBin": ["binaries/transcribe"]`. Tauri resolves this at build time to `binaries/transcribe-<target-triple>`, which is why the Makefile copies to that exact filename. The `binaries/` directory is git-ignored and regenerated on every `make sidecar`.

The sidecar process is launched via `tauri-plugin-shell`'s `sidecar("transcribe")` — this requires `tauri-plugin-shell` to be registered in `lib.rs` AND a capability allowing it (currently via `core:default`; sidecar spawn works without an explicit shell capability in Tauri 2 when declared as `externalBin`).

## Permissions (macOS)

The Swift sidecar requires **both** microphone and system audio capture permissions — these are linker-injected into the sidecar's `Info.plist` (see `../transcribe/CLAUDE.md`). The Tauri host app itself does not request these; permission prompts come from the sidecar on first run.
