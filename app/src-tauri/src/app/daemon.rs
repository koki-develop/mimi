use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering};
use std::sync::{Arc, Mutex as StdMutex};

use serde::Serialize;
use serde_json::Value;
use tauri::{AppHandle, Emitter};
use tauri_plugin_shell::process::{CommandChild, CommandEvent};
use tauri_plugin_shell::ShellExt;
use tokio::sync::Mutex as TokioMutex;
use tokio::task::JoinHandle;

use crate::summarizer::{
    self, Segment, Source, SummarizerConfig, TauriTimelineEmitter, TimelineEmitter,
    TimelineLoopParams, TimelineState,
};

pub(crate) const EVENT_TRANSCRIBE: &str = "transcribe://event";

/// Wire-protocol command sent to the daemon over stdin.
/// Mirrors the Swift `DaemonCommand` enum (`{"type":"start"}` / `{"type":"stop"}`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case", tag = "type")]
pub(crate) enum DaemonCommand {
    Start,
    Stop,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub(crate) enum DaemonState {
    LoadingModel = 0,
    Ready = 1,
    Capturing = 2,
    Stopping = 3,
    Fatal = 4,
    Dead = 5,
}

impl DaemonState {
    fn from_u8(v: u8) -> Self {
        match v {
            0 => Self::LoadingModel,
            1 => Self::Ready,
            2 => Self::Capturing,
            3 => Self::Stopping,
            4 => Self::Fatal,
            5 => Self::Dead,
            // Unreachable in practice — only `store(state as u8)` sites mutate the
            // atomic, and they only ever pass a valid `DaemonState` discriminant.
            // Treat any out-of-range value defensively as Dead so callers reject.
            _ => Self::Dead,
        }
    }
}

/// Hooks the stdout reader needs to spin up a per-session summarizer task.
/// Constructed once at `Daemon::spawn` time and reused for every session.
pub(crate) struct SummarizerHooks {
    pub(crate) summarizer: Arc<SummarizerConfig>,
    pub(crate) summary_interval: std::time::Duration,
    pub(crate) context_window: usize,
    pub(crate) current_session_id: Arc<AtomicU64>,
    pub(crate) app: AppHandle,
}

pub(crate) struct DaemonSpawnConfig {
    pub(crate) model: String,
    pub(crate) language: String,
    pub(crate) verbose: bool,
}

pub(crate) struct Daemon {
    // CommandChild owns the stdin pipe writer (its `write(&mut self, &[u8])`
    // method is the IPC channel) AND wraps the OS process handle. Held here
    // (not in the reader task) because send_command needs &mut access to
    // CommandChild::write. tauri-plugin-shell does not expose a separately
    // ownable writer half — CommandChild itself IS the writer.
    child: TokioMutex<CommandChild>,
    /// State stored as a u8-encoded `DaemonState`. AtomicU8 (vs RwLock) keeps
    /// `Daemon::state()` lock-free and contention-free: concurrent
    /// `start_recording` calls never see a transient "LoadingModel" answer just
    /// because the reader task happens to be holding a write lock.
    state: Arc<AtomicU8>,
}

/// Per-session bookkeeping owned by the stdout reader task. Created on
/// `session_started`, dropped on `session_stopped` / `Terminated` / `state_changed{fatal}`.
struct SessionContext {
    summarizer_cancel: Arc<AtomicBool>,
    summarizer_task: JoinHandle<()>,
}

impl Daemon {
    pub(crate) async fn spawn(
        app: &AppHandle,
        hooks: SummarizerHooks,
        config: DaemonSpawnConfig,
    ) -> Result<Self, String> {
        let mut sidecar = app
            .shell()
            .sidecar("transcribe")
            .map_err(|e| format!("sidecar lookup failed: {e}"))?
            .args([
                "--model".to_string(),
                config.model,
                "--language".to_string(),
                config.language,
            ]);
        if config.verbose {
            sidecar = sidecar.args(["--verbose".to_string()]);
        }
        let (rx, child) = sidecar.spawn().map_err(|e| format!("spawn failed: {e}"))?;

        let state = Arc::new(AtomicU8::new(DaemonState::LoadingModel as u8));
        let reader_state = state.clone();
        let reader_app = app.clone();
        // detached: reader runs until `Terminated`; we don't keep the handle.
        tokio::spawn(reader_loop(rx, reader_state, hooks, reader_app));

        Ok(Daemon {
            child: TokioMutex::new(child),
            state,
        })
    }

    /// Writes one line of JSON to the daemon's stdin. Returns Err if the daemon
    /// is in `Dead` or `Fatal` state, or if the underlying write fails.
    pub(crate) async fn send_command(&self, cmd: &DaemonCommand) -> Result<(), String> {
        match self.state() {
            DaemonState::Dead | DaemonState::Fatal => return Err("daemon is dead".into()),
            _ => {}
        }
        let line = serde_json::to_string(cmd).map_err(|e| format!("serialize: {e}"))?;
        let mut bytes = line.into_bytes();
        bytes.push(b'\n');
        let mut child = self.child.lock().await;
        child
            .write(&bytes)
            .map_err(|e| format!("daemon stdin write failed: {e}"))?;
        Ok(())
    }

    pub(crate) fn state(&self) -> DaemonState {
        DaemonState::from_u8(self.state.load(Ordering::Acquire))
    }
}

/// Extract a `Segment` from a parsed JSONL event. Returns `None` if the value
/// is not of type `"segment"` or if any required field is missing/invalid.
/// Same semantics as the deleted `tail::parse_jsonl_segment`.
fn parse_segment(value: &Value) -> Option<Segment> {
    if value.get("type").and_then(|t| t.as_str()) != Some("segment") {
        return None;
    }
    let data = value.get("data")?;
    let source = match data.get("source").and_then(|s| s.as_str())? {
        "mic" => Source::Mic,
        "system" => Source::System,
        _ => return None,
    };
    let text = data.get("text").and_then(|t| t.as_str())?.to_string();
    let timestamp = value.get("timestamp").and_then(|t| t.as_str())?.to_string();
    Some(Segment {
        timestamp,
        source,
        text,
    })
}

/// Extract the daemon state from a `state_changed` event. Returns `None` for
/// non-`state_changed` events or for unknown state strings.
fn parse_daemon_state(value: &Value) -> Option<DaemonState> {
    if value.get("type").and_then(|t| t.as_str()) != Some("state_changed") {
        return None;
    }
    let data = value.get("data")?;
    match data.get("state").and_then(|s| s.as_str())? {
        "loading_model" => Some(DaemonState::LoadingModel),
        "ready" => Some(DaemonState::Ready),
        "capturing" => Some(DaemonState::Capturing),
        "stopping" => Some(DaemonState::Stopping),
        "fatal" => Some(DaemonState::Fatal),
        _ => None,
    }
}

async fn reader_loop(
    mut rx: tokio::sync::mpsc::Receiver<CommandEvent>,
    state: Arc<AtomicU8>,
    hooks: SummarizerHooks,
    app: AppHandle,
) {
    let mut session: Option<(SessionContext, Arc<StdMutex<Vec<Segment>>>)> = None;

    while let Some(event) = rx.recv().await {
        match event {
            CommandEvent::Stdout(line) => {
                let s = match std::str::from_utf8(&line) {
                    Ok(s) => s,
                    Err(e) => {
                        eprintln!("[transcribe] invalid utf-8 line: {e}");
                        continue;
                    }
                };
                let value: Value = match serde_json::from_str(s) {
                    Ok(v) => v,
                    Err(e) => {
                        eprintln!("[transcribe] json parse error: {e} line={s}");
                        continue;
                    }
                };

                // Forward verbatim to the frontend.
                let _ = app.emit(EVENT_TRANSCRIBE, value.clone());

                // Typed dispatch.
                match value.get("type").and_then(|t| t.as_str()) {
                    Some("state_changed") => {
                        if let Some(new_state) = parse_daemon_state(&value) {
                            state.store(new_state as u8, Ordering::Release);
                            if new_state == DaemonState::Fatal {
                                drain_session(&mut session, &hooks).await;
                            }
                        }
                    }
                    Some("session_started") => {
                        if session.is_some() {
                            // Should not happen — daemon emits one session_started per
                            // start. Defensive: drain the stale one before opening a new.
                            drain_session(&mut session, &hooks).await;
                        }
                        session = Some(begin_session(&hooks));
                    }
                    Some("segment") => {
                        if let (Some(seg), Some((_, segments))) =
                            (parse_segment(&value), session.as_ref())
                        {
                            segments.lock().unwrap().push(seg);
                        }
                    }
                    Some("session_stopped") => {
                        drain_session(&mut session, &hooks).await;
                    }
                    _ => {}
                }
            }
            CommandEvent::Stderr(line) => {
                eprintln!("[transcribe] {}", String::from_utf8_lossy(&line));
            }
            CommandEvent::Terminated(payload) => {
                eprintln!(
                    "[transcribe] terminated: code={:?} signal={:?}",
                    payload.code, payload.signal
                );
                let prior = DaemonState::from_u8(state.load(Ordering::Acquire));
                state.store(DaemonState::Dead as u8, Ordering::Release);
                if prior != DaemonState::Fatal {
                    let timestamp =
                        chrono::Local::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, false);
                    let synthetic = serde_json::json!({
                        "type": "state_changed",
                        "timestamp": timestamp,
                        "data": { "state": "fatal" }
                    });
                    let _ = app.emit(EVENT_TRANSCRIBE, synthetic);
                }
                drain_session(&mut session, &hooks).await;
                break;
            }
            _ => {}
        }
    }
}

fn begin_session(hooks: &SummarizerHooks) -> (SessionContext, Arc<StdMutex<Vec<Segment>>>) {
    let session_id = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    hooks
        .current_session_id
        .store(session_id, Ordering::Release);

    let segments: Arc<StdMutex<Vec<Segment>>> = Arc::new(StdMutex::new(Vec::new()));
    let cancel = Arc::new(AtomicBool::new(false));

    let timeline_state = Arc::new(TimelineState::new(session_id));
    let emitter: Arc<dyn TimelineEmitter> = Arc::new(TauriTimelineEmitter {
        app: hooks.app.clone(),
    });
    let summarizer_cancel = cancel.clone();
    let segments_for_task = segments.clone();
    let config = (*hooks.summarizer).clone();
    let tick_interval = hooks.summary_interval;
    let context_window = hooks.context_window;
    let current_session_id = hooks.current_session_id.clone();

    let task = tokio::spawn(async move {
        summarizer::timeline_loop(TimelineLoopParams {
            segments: segments_for_task,
            state: timeline_state,
            emitter,
            cancel: summarizer_cancel,
            current_session_id,
            config,
            tick_interval,
            context_window,
        })
        .await
    });

    (
        SessionContext {
            summarizer_cancel: cancel,
            summarizer_task: task,
        },
        segments,
    )
}

async fn drain_session(
    session: &mut Option<(SessionContext, Arc<StdMutex<Vec<Segment>>>)>,
    hooks: &SummarizerHooks,
) {
    if let Some((ctx, _segments)) = session.take() {
        ctx.summarizer_cancel.store(true, Ordering::Release);
        let _ = ctx.summarizer_task.await;
        hooks.current_session_id.store(0, Ordering::Release);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::time::Duration;

    // ---- DaemonState atomic encoding roundtrip ----

    #[test]
    fn daemon_state_atomic_roundtrip_for_each_variant() {
        for s in [
            DaemonState::LoadingModel,
            DaemonState::Ready,
            DaemonState::Capturing,
            DaemonState::Stopping,
            DaemonState::Fatal,
            DaemonState::Dead,
        ] {
            let encoded = s as u8;
            let decoded = DaemonState::from_u8(encoded);
            assert_eq!(s, decoded, "roundtrip failed for {s:?}");
        }
    }

    #[test]
    fn daemon_state_from_u8_out_of_range_falls_back_to_dead() {
        // Defensive — if some future code stores an invalid byte, callers should
        // see Dead (so send_command short-circuits with "daemon is dead").
        assert_eq!(DaemonState::from_u8(99), DaemonState::Dead);
        assert_eq!(DaemonState::from_u8(255), DaemonState::Dead);
    }

    // ---- DaemonCommand serialization ----

    #[test]
    fn daemon_command_start_serializes() {
        let s = serde_json::to_string(&DaemonCommand::Start).unwrap();
        assert_eq!(s, r#"{"type":"start"}"#);
    }

    #[test]
    fn daemon_command_stop_serializes() {
        let s = serde_json::to_string(&DaemonCommand::Stop).unwrap();
        assert_eq!(s, r#"{"type":"stop"}"#);
    }

    // ---- drain_session lifecycle ----

    /// SummarizerHooks wants an AppHandle which is a real Tauri runtime type that
    /// can't be constructed in unit tests. drain_session only reads
    /// `hooks.current_session_id`, so we shadow the function for testing with a
    /// signature that takes just the AtomicU64.
    async fn drain_session_for_test(
        session: &mut Option<(SessionContext, Arc<StdMutex<Vec<Segment>>>)>,
        current_session_id: &Arc<AtomicU64>,
    ) {
        if let Some((ctx, _segments)) = session.take() {
            ctx.summarizer_cancel.store(true, Ordering::Release);
            let _ = ctx.summarizer_task.await;
            current_session_id.store(0, Ordering::Release);
        }
    }

    fn make_session_context_with_long_running_task(
    ) -> (SessionContext, Arc<StdMutex<Vec<Segment>>>, Arc<AtomicBool>) {
        let cancel = Arc::new(AtomicBool::new(false));
        let cancel_for_task = cancel.clone();
        // No-op summarizer task that respects the cancel flag — mirrors the
        // production summarizer which polls cancel between ticks.
        let task = tokio::spawn(async move {
            while !cancel_for_task.load(Ordering::Acquire) {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        });
        let segments = Arc::new(StdMutex::new(Vec::new()));
        (
            SessionContext {
                summarizer_cancel: cancel.clone(),
                summarizer_task: task,
            },
            segments,
            cancel,
        )
    }

    #[tokio::test]
    async fn drain_session_cancels_then_awaits_then_clears_session_id() {
        let (ctx, segments, cancel) = make_session_context_with_long_running_task();
        let current_session_id = Arc::new(AtomicU64::new(42));
        let mut session = Some((ctx, segments));

        drain_session_for_test(&mut session, &current_session_id).await;

        assert!(session.is_none(), "session slot should be empty");
        assert!(cancel.load(Ordering::Acquire), "cancel flag should be set");
        assert_eq!(
            current_session_id.load(Ordering::Acquire),
            0,
            "current_session_id should be cleared"
        );
    }

    #[tokio::test]
    async fn drain_session_is_noop_when_no_session() {
        let current_session_id = Arc::new(AtomicU64::new(7));
        let mut session: Option<(SessionContext, Arc<StdMutex<Vec<Segment>>>)> = None;

        drain_session_for_test(&mut session, &current_session_id).await;

        // current_session_id is NOT cleared when there's no session to drain
        // (we only zero it as part of session shutdown).
        assert_eq!(current_session_id.load(Ordering::Acquire), 7);
    }

    // ---- parse_segment (fixtures lifted verbatim from the deleted tail::tests) ----

    #[test]
    fn parse_segment_returns_mic_segment() {
        let v = json!({
            "type": "segment",
            "timestamp": "2026-04-25T10:00:00.000+09:00",
            "data": { "source": "mic", "text": "こんにちは" }
        });
        let seg = parse_segment(&v).unwrap();
        assert_eq!(seg.timestamp, "2026-04-25T10:00:00.000+09:00");
        assert_eq!(seg.source, Source::Mic);
        assert_eq!(seg.text, "こんにちは");
    }

    #[test]
    fn parse_segment_returns_system_segment() {
        let v = json!({
            "type": "segment",
            "timestamp": "2026-04-25T10:00:00.000+09:00",
            "data": { "source": "system", "text": "hello" }
        });
        assert_eq!(parse_segment(&v).unwrap().source, Source::System);
    }

    #[test]
    fn parse_segment_rejects_unknown_source() {
        let v = json!({
            "type": "segment",
            "timestamp": "t",
            "data": { "source": "other", "text": "x" }
        });
        assert!(parse_segment(&v).is_none());
    }

    #[test]
    fn parse_segment_rejects_missing_text() {
        let v = json!({
            "type": "segment",
            "timestamp": "t",
            "data": { "source": "mic" }
        });
        assert!(parse_segment(&v).is_none());
    }

    #[test]
    fn parse_segment_rejects_missing_timestamp() {
        let v = json!({
            "type": "segment",
            "data": { "source": "mic", "text": "x" }
        });
        assert!(parse_segment(&v).is_none());
    }

    #[test]
    fn parse_segment_rejects_non_segment_type() {
        let v = json!({
            "type": "warning",
            "timestamp": "t",
            "data": { "message": "x" }
        });
        assert!(parse_segment(&v).is_none());
    }

    #[test]
    fn parse_segment_rejects_missing_data_field() {
        let v = json!({ "type": "segment", "timestamp": "t" });
        assert!(parse_segment(&v).is_none());
    }

    // ---- parse_daemon_state ----

    #[test]
    fn parse_daemon_state_returns_each_known_state() {
        for (s, expected) in [
            ("loading_model", DaemonState::LoadingModel),
            ("ready", DaemonState::Ready),
            ("capturing", DaemonState::Capturing),
            ("stopping", DaemonState::Stopping),
            ("fatal", DaemonState::Fatal),
        ] {
            let v = json!({
                "type": "state_changed",
                "timestamp": "t",
                "data": { "state": s }
            });
            assert_eq!(parse_daemon_state(&v), Some(expected), "state={s}");
        }
    }

    #[test]
    fn parse_daemon_state_rejects_unknown_state() {
        let v = json!({
            "type": "state_changed",
            "timestamp": "t",
            "data": { "state": "frobnicate" }
        });
        assert!(parse_daemon_state(&v).is_none());
    }

    #[test]
    fn parse_daemon_state_rejects_non_state_changed_type() {
        let v = json!({
            "type": "segment",
            "timestamp": "t",
            "data": { "source": "mic", "text": "x" }
        });
        assert!(parse_daemon_state(&v).is_none());
    }
}
