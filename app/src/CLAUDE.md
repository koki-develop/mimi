# src

React frontend for the Tauri shell. See `../CLAUDE.md` for the high-level data flow.

## TypeScript

- `tsconfig.json` is `strict` + `noUnusedLocals` + `noUnusedParameters` — unused imports/params are hard errors, not warnings.
- `bun run build` (= `tsc && vite build`) typechecks without spinning up Tauri.

## Event handling (`App.tsx`)

- `TranscribeEvent` — discriminated union mirroring the Swift-side JSONL schema.
- `TimelineEvent` — discriminated union emitted by the Rust summarizer (`generating` / `entry` / `error`).
- Both `switch` statements end with `const _exhaustive: never = event` — adding a new variant without handling it deliberately fails `tsc`. Keep that pattern.
