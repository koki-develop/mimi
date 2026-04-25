use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use nix::sys::signal::{kill, Signal};
use nix::unistd::Pid;
use tauri::{AppHandle, Manager, State};
use tauri_plugin_shell::process::{CommandChild, CommandEvent};
use tauri_plugin_shell::ShellExt;
use tokio::sync::mpsc::Receiver;
use tokio::sync::oneshot;
use tokio::task::JoinHandle;

use crate::app::state::{AppState, Recording};
use crate::app::tail;
use crate::summarizer::{
    self, Segment, TauriTimelineEmitter, TimelineEmitter, TimelineLoopParams, TimelineState,
};

#[tauri::command]
pub(crate) async fn start_recording(
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<(), String> {
    {
        let guard = state.recording.lock().unwrap();
        if guard.is_some() {
            return Err("already recording".into());
        }
    }

    // Ollama reachability + model presence check must precede sidecar spawn —
    // we want the user to see a clear error before the Swift process starts up.
    let cfg = state.summarizer.clone();
    summarizer::health_check(&cfg).await?;

    let (output_path, session_id) = make_output_path()?;

    let (rx, child, pid) = spawn_sidecar(&app, &output_path)?;

    // session_id is stored *after* spawn succeeds so a spawn failure cannot
    // leave a stale session_id behind.
    state
        .current_session_id
        .store(session_id, Ordering::Release);

    let (term_tx, term_rx) = oneshot::channel();
    spawn_event_monitor(rx, app.clone(), child, term_tx);

    let segments: Arc<Mutex<Vec<Segment>>> = Arc::new(Mutex::new(Vec::new()));

    let tail_cancel = Arc::new(AtomicBool::new(false));
    let tail = tokio::spawn(tail::tail_file(
        output_path.clone(),
        app.clone(),
        tail_cancel.clone(),
        segments.clone(),
    ));

    let timeline_state = Arc::new(TimelineState::new(session_id));
    let summarizer_cancel = Arc::new(AtomicBool::new(false));
    let summarizer = spawn_summarizer_task(
        segments,
        timeline_state,
        summarizer_cancel.clone(),
        &state,
        app.clone(),
    );

    let mut guard = state.recording.lock().unwrap();
    *guard = Some(Recording {
        pid,
        terminated: term_rx,
        tail_cancel,
        tail,
        output_path,
        summarizer_cancel,
        summarizer,
    });
    Ok(())
}

#[tauri::command]
pub(crate) async fn stop_recording(state: State<'_, AppState>) -> Result<(), String> {
    let recording = {
        let mut guard = state.recording.lock().unwrap();
        guard.take()
    };
    let Some(recording) = recording else {
        return Ok(());
    };
    shutdown_recording(recording, &state, true).await;
    Ok(())
}

fn make_output_path() -> Result<(PathBuf, u64), String> {
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_millis();
    let path = std::env::temp_dir().join(format!("mimi-{ts}.jsonl"));
    Ok((path, ts as u64))
}

fn spawn_sidecar(
    app: &AppHandle,
    output_path: &Path,
) -> Result<(Receiver<CommandEvent>, CommandChild, u32), String> {
    let sidecar = app
        .shell()
        .sidecar("transcribe")
        .map_err(|e| format!("sidecar lookup failed: {e}"))?
        .args(["-o".to_string(), output_path.to_string_lossy().into_owned()]);
    let (rx, child) = sidecar.spawn().map_err(|e| format!("spawn failed: {e}"))?;
    let pid = child.pid();
    Ok((rx, child, pid))
}

fn spawn_event_monitor(
    mut rx: Receiver<CommandEvent>,
    app: AppHandle,
    child: CommandChild,
    term_tx: oneshot::Sender<()>,
) {
    tokio::spawn(async move {
        // Holding `child` in this scope prevents the shell plugin from reaping
        // the CommandChild before we've observed Terminated.
        let _child = child;
        let mut term_tx = Some(term_tx);
        while let Some(event) = rx.recv().await {
            match event {
                CommandEvent::Stderr(line) => {
                    eprintln!("[transcribe] {}", String::from_utf8_lossy(&line));
                }
                CommandEvent::Stdout(line) => {
                    eprintln!("[transcribe stdout] {}", String::from_utf8_lossy(&line));
                }
                CommandEvent::Terminated(payload) => {
                    eprintln!(
                        "[transcribe] terminated: code={:?} signal={:?}",
                        payload.code, payload.signal
                    );
                    if let Some(tx) = term_tx.take() {
                        let _ = tx.send(());
                    }
                    // Sidecar died on its own — race stop_recording for Recording
                    // ownership. Winner runs the cleanup; loser no-ops.
                    let state = app.state::<AppState>();
                    let taken = {
                        let mut guard = state.recording.lock().unwrap();
                        guard.take()
                    };
                    if let Some(recording) = taken {
                        shutdown_recording(recording, &state, false).await;
                    }
                    break;
                }
                _ => {}
            }
        }
    });
}

fn spawn_summarizer_task(
    segments: Arc<Mutex<Vec<Segment>>>,
    timeline_state: Arc<TimelineState>,
    cancel: Arc<AtomicBool>,
    state: &AppState,
    app: AppHandle,
) -> JoinHandle<()> {
    let emitter: Arc<dyn TimelineEmitter> = Arc::new(TauriTimelineEmitter { app });
    let config = (*state.summarizer).clone();
    let tick_interval = state.summary_interval;
    let context_window = state.context_window;
    let current_session_id = state.current_session_id.clone();
    tokio::spawn(async move {
        summarizer::timeline_loop(TimelineLoopParams {
            segments,
            state: timeline_state,
            emitter,
            cancel,
            current_session_id,
            config,
            tick_interval,
            context_window,
        })
        .await
    })
}

/// Consolidated 7-step cleanup shared by `stop_recording` and the `Terminated`
/// handler. Ordering follows
/// `docs/superpowers/specs/2026-04-24-timeline-summarizer-design.md` §4.2. Two
/// callers race to `take()` the `Recording` before calling this — that race is
/// load-bearing; **only** the cleanup body is shared.
///
/// - `send_sigint = true`  → called from `stop_recording` (the sidecar is still
///   running; we must SIGINT and wait for Terminated).
/// - `send_sigint = false` → called from the `Terminated` handler (the sidecar
///   already exited; SIGINT + wait are unnecessary).
async fn shutdown_recording(recording: Recording, state: &AppState, send_sigint: bool) {
    // 1. summarizer_cancel first; also wipe session_id so any in-flight child task
    //    from this session aborts its emit.
    recording.summarizer_cancel.store(true, Ordering::Release);
    state.current_session_id.store(0, Ordering::Release);

    // 2-3. SIGINT + terminated-waiter (stop_recording path only)
    if send_sigint {
        if let Err(e) = kill(Pid::from_raw(recording.pid as i32), Signal::SIGINT) {
            eprintln!("[stop] SIGINT failed (process may have exited): {e}");
        } else {
            let _ = tokio::time::timeout(Duration::from_secs(10), recording.terminated).await;
        }
    }

    // 4. give the tail loop one EOF polling cycle to drain any trailing bytes.
    tokio::time::sleep(Duration::from_millis(200)).await;

    // 5. stop the tail and wait for it.
    recording.tail_cancel.store(true, Ordering::Release);
    let _ = recording.tail.await;

    // 6. join the summarizer loop (spawned child tasks are detached).
    let _ = recording.summarizer.await;

    // 7. delete the tmp JSONL.
    let _ = std::fs::remove_file(&recording.output_path);
}
