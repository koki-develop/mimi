# src

React frontend for the Tauri shell. See `../CLAUDE.md` for the high-level data flow.

## TypeScript

- `tsconfig.json` is `strict` + `noUnusedLocals` + `noUnusedParameters` — unused imports/params are hard errors, not warnings.
- `bun run build` (= `tsc && vite build`) typechecks without spinning up Tauri.

## Event handling (`App.tsx`)

- `TranscribeEvent` — discriminated union mirroring the Swift-side JSONL schema. `data.reason` on `session_stopped` is `"stop" | "error"` (the wire-format `"sigint"` was renamed to `"stop"` when the CLI became a daemon).
- `TimelineEvent` — discriminated union emitted by the Rust summarizer (`generating` / `entry` / `error`).
- Both `switch` statements end with `const _exhaustive: never = event` — adding a new variant without handling it deliberately fails `tsc`. Keep that pattern.
- The `state_changed` event's `data.state` is itself a discriminated union (`"loading_model" | "ready" | "capturing" | "stopping" | "fatal"`). The inner switch in App.tsx ends with the same `const _exhaustive: never` pattern so adding a new state without handling fails `tsc`.
- The record button is gated on `daemonReady && !daemonFatal && !busy`. The daemon emits `state_changed { ready }` once WhisperKit finishes loading (during app boot, asynchronously after `tauri::Builder::setup`).
