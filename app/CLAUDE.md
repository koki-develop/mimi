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

The app is a thin Tauri shell around the Swift `transcribe` daemon. There is **no in-process transcription logic** — Rust spawns the daemon at app launch as a long-lived sidecar and streams its output to the frontend over stdout.

Data flow:

```
React (src/App.tsx)
  ├── invoke("start_recording") ─▶ Rust: write {"type":"start"}\n to daemon stdin
  ├── invoke("stop_recording")  ─▶ Rust: write {"type":"stop"}\n to daemon stdin
  ├── listen("transcribe://event") ◀─ Rust: stdout-reader task forwards every JSON
  │                                          line emitted by the daemon
  └── (daemon is spawned once during tauri::Builder setup, model loads in background;
        button disabled until state_changed{ready} arrives)
```

## Permissions (macOS)

The Swift sidecar requires **both** microphone and system audio capture permissions — these are linker-injected into the sidecar's `Info.plist` (see `../transcribe/CLAUDE.md`). The Tauri host app itself does not request these; permission prompts come from the sidecar on first record (per-`start` permission check).
