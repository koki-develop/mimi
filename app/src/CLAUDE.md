# src

React frontend for the Tauri shell. See `../CLAUDE.md` for the high-level data flow.

## TypeScript

- `tsconfig.json` is `strict` + `noUnusedLocals` + `noUnusedParameters` — unused imports/params are hard errors, not warnings.
- `bun run build` (= `tsc && vite build`) typechecks without spinning up Tauri.

## Event handling

Types (`TranscribeEvent`, `TimelineEvent`, `Segment`, `TimelineEntry`, `Source`) live in `types.ts`. Listeners are split per channel:

- `TranscribeEvent` — discriminated union mirroring the Swift-side JSONL schema. `data.reason` on `session_stopped` is `"stop" | "error"` (the wire-format `"sigint"` was renamed to `"stop"` when the CLI became a daemon). Listener lives in `hooks/useTranscribeDaemon.ts`, which also owns `recording` / `daemonReady` / `daemonFatal` / `segments` / `errorMsg` / `busy` and exposes `start()` / `stop()`.
- `TimelineEvent` — discriminated union emitted by the Rust summarizer (`generating` / `entry` / `error`). Listener lives in `hooks/useTimeline.ts`, which owns `entries` / `timelineError` / `expandedGen` and exposes `toggleExpanded()` / `reset()` / `clearError()`.
- Both `switch` statements end with `const _exhaustive: never = event` — adding a new variant without handling it deliberately fails `tsc`. Keep that pattern.
- The `state_changed` event's `data.state` is itself a discriminated union (`"loading_model" | "ready" | "capturing" | "stopping" | "fatal"`). The inner switch in `hooks/useTranscribeDaemon.ts` ends with the same `const _exhaustive: never` pattern so adding a new state without handling fails `tsc`.
- The record button (in `components/Header.tsx`) is gated on `daemonReady && !daemonFatal && !busy`. The daemon emits `state_changed { ready }` once WhisperKit finishes loading (during app boot, asynchronously after `tauri::Builder::setup`).
- `App.tsx` is composition-only: it instantiates the hooks, wires `start` / `stop` against `timeline.reset()` / `timeline.clearError()`, and renders `Header` / `LiveTicker` / `TimelineList`.
