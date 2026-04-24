# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

For the Swift sidecar that this app wraps, see `@../transcribe/CLAUDE.md`. Rust-specific details live in `src-tauri/CLAUDE.md`; frontend in `src/CLAUDE.md` (both auto-loaded on demand).

## Commands

Package manager is **bun**, not npm/yarn. Use the Makefile for anything that touches Tauri — raw `bun run tauri dev/build` **skips the sidecar rebuild** and will run against a stale `src-tauri/binaries/transcribe-<triple>`.

- `make dev` — builds the Swift sidecar (`cd ../transcribe && swift build -c release`), copies it into `src-tauri/binaries/transcribe-$(rustc -vV | sed -n 's/host: //p')`, then `bun run tauri dev`.
- `make build` — same sidecar step, then `bun run tauri build`.
- `make sidecar` / `make clean-sidecar` — just the sidecar copy step, in isolation.
- `bun run build` — frontend-only typecheck + vite build (`tsc && vite build`). Use this to check TypeScript without spinning up Tauri.

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

## Permissions (macOS)

The Swift sidecar requires **both** microphone and system audio capture permissions — these are linker-injected into the sidecar's `Info.plist` (see `../transcribe/CLAUDE.md`). The Tauri host app itself does not request these; permission prompts come from the sidecar on first run.
