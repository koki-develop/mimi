# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`mimi` is a two-component repo with no root-level build system:

- `app/` — Tauri 2 desktop shell. React frontend + Rust backend that spawns the Swift CLI as a sidecar.
- `transcribe/` — standalone Swift 6.3 / SwiftPM CLI. Owns all audio capture + WhisperKit transcription logic.

The Rust side never imports Swift code; the only contract is the line-delimited JSON the sidecar reads on stdin (commands) and writes on stdout (events). End-to-end flow and command details live in each component's own `CLAUDE.md` (auto-loaded when you touch its subtree). Start there.

## Working across components

- **Always build through `app/`'s Makefile** (`make dev` / `make build`). It rebuilds the Swift CLI in `../transcribe` and copies it into `src-tauri/binaries/transcribe-<rustc-host-triple>`. Raw `bun run tauri …` skips that step and runs against a stale sidecar.
- `lefthook.yml` (gitleaks, pre-commit + pre-push) and `.wtp.yml` (worktree config) are the only root-level files that matter. Run `lefthook install` once per clone; `wtp` worktrees handle it automatically.
