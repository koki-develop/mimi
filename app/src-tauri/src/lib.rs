mod summarizer;

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use nix::sys::signal::{kill, Signal};
use nix::unistd::Pid;
use serde_json::Value;
use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_shell::process::CommandEvent;
use tauri_plugin_shell::ShellExt;
use tokio::io::AsyncReadExt;
use tokio::sync::oneshot;
use tokio::task::JoinHandle;

use crate::summarizer::Segment;

struct Recording {
    pid: u32,
    terminated: oneshot::Receiver<()>,
    tail_cancel: Arc<AtomicBool>,
    tail: JoinHandle<()>,
    output_path: PathBuf,
    segments: Arc<Mutex<Vec<Segment>>>,
    summarizer_cancel: Arc<AtomicBool>,
    summarizer: JoinHandle<()>,
}

struct AppState {
    recording: Mutex<Option<Recording>>,
    current_session_id: Arc<AtomicU64>,
    summarizer_config: Arc<summarizer::SummarizerConfig>,
    summary_interval: Duration,
    context_window: usize,
}

impl AppState {
    fn new(cfg: summarizer::SummarizerConfig, summary_interval: Duration, context_window: usize) -> Self {
        Self {
            recording: Mutex::new(None),
            current_session_id: Arc::new(AtomicU64::new(0)),
            summarizer_config: Arc::new(cfg),
            summary_interval,
            context_window,
        }
    }
}

#[tauri::command]
async fn start_recording(app: AppHandle, state: State<'_, AppState>) -> Result<(), String> {
    {
        let guard = state.recording.lock().unwrap();
        if guard.is_some() {
            return Err("already recording".into());
        }
    }

    // ヘルスチェック (Ollama 疎通 + モデル存在) を sidecar spawn より先に
    let cfg = state.summarizer_config.clone();
    summarizer::health_check(&cfg).await?;

    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_millis();
    let output_path = std::env::temp_dir().join(format!("mimi-{ts}.jsonl"));

    let session_id: u64 = ts as u64;

    let sidecar = app
        .shell()
        .sidecar("transcribe")
        .map_err(|e| format!("sidecar lookup failed: {e}"))?
        .args([
            "-o".to_string(),
            output_path.to_string_lossy().into_owned(),
        ]);
    let (mut rx, child) = sidecar.spawn().map_err(|e| format!("spawn failed: {e}"))?;
    let pid = child.pid();

    // sidecar spawn 成功後に store する (spawn 失敗時に stale な値を残さないため)
    state.current_session_id.store(session_id, std::sync::atomic::Ordering::Release);

    let (term_tx, term_rx) = oneshot::channel();
    let rx_app = app.clone();
    tokio::spawn(async move {
        // CommandChild を drop するとプラグイン側で子プロセスが reap される可能性があるため、
        // Terminated を見届けるまでこのスコープで保持する。
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
                    let state = rx_app.state::<AppState>();
                    let taken = {
                        let mut guard = state.recording.lock().unwrap();
                        guard.take()
                    };
                    if let Some(recording) = taken {
                        // stop_recording と同順序のクリーンアップ
                        // (docs/superpowers/specs/2026-04-24-timeline-summarizer-design.md §4.2)
                        // 1. summarizer_cancel 最初 (+ session_id=0 で走行中 child の emit を弾く)
                        recording.summarizer_cancel.store(true, Ordering::Release);
                        state.current_session_id.store(0, std::sync::atomic::Ordering::Release);
                        // 2-3. SIGINT と terminated 待ちはこのパスでは不要
                        // 4. tail の EOF ポーリング 1 サイクル分
                        tokio::time::sleep(Duration::from_millis(200)).await;
                        // 5. tail cancel + await
                        recording.tail_cancel.store(true, Ordering::Release);
                        let _ = recording.tail.await;
                        // 6. summarizer loop join
                        let _ = recording.summarizer.await;
                        // 7. remove_file
                        let _ = std::fs::remove_file(&recording.output_path);
                    }
                    break;
                }
                _ => {}
            }
        }
    });

    let segments: Arc<Mutex<Vec<Segment>>> = Arc::new(Mutex::new(Vec::new()));

    use summarizer::TimelineState;

    // tail
    let tail_cancel = Arc::new(AtomicBool::new(false));
    let tail_cancel_c = tail_cancel.clone();
    let app_handle = app.clone();
    let tail_path = output_path.clone();
    let segments_for_tail = segments.clone();
    let tail = tokio::spawn(async move {
        tail_file(tail_path, app_handle, tail_cancel_c, segments_for_tail).await
    });

    // timeline summarizer
    let timeline_state = Arc::new(TimelineState::new(session_id));
    let summarizer_cancel = Arc::new(AtomicBool::new(false));
    let emitter: Arc<dyn summarizer::TimelineEmitter> =
        Arc::new(summarizer::TauriTimelineEmitter { app: app.clone() });
    let segments_for_loop = segments.clone();
    let cancel_for_loop = summarizer_cancel.clone();
    let session_id_for_loop = state.current_session_id.clone();
    let cfg_for_loop = cfg.as_ref().clone();
    let summary_interval_for_loop = state.summary_interval;
    let context_window_for_loop = state.context_window;
    let summarizer = tokio::spawn(async move {
        summarizer::timeline_loop(
            segments_for_loop,
            timeline_state,
            emitter,
            cancel_for_loop,
            session_id_for_loop,
            cfg_for_loop,
            summary_interval_for_loop,
            context_window_for_loop,
        ).await
    });

    let mut guard = state.recording.lock().unwrap();
    *guard = Some(Recording {
        pid,
        terminated: term_rx,
        tail_cancel,
        tail,
        output_path,
        segments,
        summarizer_cancel,
        summarizer,
    });
    Ok(())
}

#[tauri::command]
async fn stop_recording(state: State<'_, AppState>) -> Result<(), String> {
    let recording = {
        let mut guard = state.recording.lock().unwrap();
        guard.take()
    };
    let Some(recording) = recording else {
        return Ok(());
    };
    let Recording {
        pid,
        terminated,
        tail_cancel,
        tail,
        output_path,
        segments: _segments,
        summarizer_cancel,
        summarizer,
    } = recording;

    // 7 ステップ (docs/superpowers/specs/2026-04-24-timeline-summarizer-design.md §4.2):
    // 1. summarizer_cancel 最初 (+ session_id=0 で走行中 child の emit を弾く)
    summarizer_cancel.store(true, Ordering::Release);
    state.current_session_id.store(0, std::sync::atomic::Ordering::Release);

    // 2. SIGINT
    if let Err(e) = kill(Pid::from_raw(pid as i32), Signal::SIGINT) {
        eprintln!("[stop] SIGINT failed (process may have exited): {e}");
    } else {
        // 3. terminated を最大 10 秒待つ
        let _ = tokio::time::timeout(Duration::from_secs(10), terminated).await;
    }

    // 4. tail の EOF ポーリング 1 サイクル分
    tokio::time::sleep(Duration::from_millis(200)).await;

    // 5. tail_cancel + tail.await
    tail_cancel.store(true, Ordering::Release);
    let _ = tail.await;

    // 6. summarizer.await (ループ task の join。子タスクは detached)
    let _ = summarizer.await;

    // 7. remove_file
    let _ = std::fs::remove_file(&output_path);
    Ok(())
}

async fn tail_file(
    path: PathBuf,
    app: AppHandle,
    cancel: Arc<AtomicBool>,
    segments: Arc<Mutex<Vec<Segment>>>,
) {
    // sidecar spawn と tail は並行起動するため、JSONLWriter がファイルを作るまでポーリング待機
    loop {
        if cancel.load(Ordering::Acquire) {
            return;
        }
        if path.exists() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }

    let mut file = match tokio::fs::File::open(&path).await {
        Ok(f) => f,
        Err(e) => {
            eprintln!("[tail] open failed: {e}");
            return;
        }
    };
    // UTF-8 コードポイントがチャンク境界を跨いで壊れるのを避けるため、バイト列のまま保持して
    // \n 区切りで完全な行が揃ってからデコードする。
    let mut partial: Vec<u8> = Vec::new();
    let mut buf = vec![0u8; 8192];

    loop {
        let n = match file.read(&mut buf).await {
            Ok(n) => n,
            Err(e) => {
                eprintln!("[tail] read error: {e}");
                return;
            }
        };

        if n == 0 {
            if cancel.load(Ordering::Acquire) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
            continue;
        }

        partial.extend_from_slice(&buf[..n]);
        while let Some(idx) = partial.iter().position(|&b| b == b'\n') {
            let drained: Vec<u8> = partial.drain(..=idx).collect();
            let trimmed_end = drained
                .iter()
                .rposition(|&b| b != b'\n' && b != b'\r')
                .map(|i| i + 1)
                .unwrap_or(0);
            let line_bytes = &drained[..trimmed_end];
            if line_bytes.is_empty() {
                continue;
            }
            match std::str::from_utf8(line_bytes) {
                Ok(s) => match serde_json::from_str::<Value>(s) {
                    Ok(value) => {
                        let _ = app.emit("transcribe://event", value.clone());
                        if value.get("type").and_then(|t| t.as_str()) == Some("segment") {
                            if let Some(data) = value.get("data") {
                                let source = match data.get("source").and_then(|s| s.as_str()) {
                                    Some("mic") => Some(summarizer::Source::Mic),
                                    Some("system") => Some(summarizer::Source::System),
                                    _ => None,
                                };
                                let text = data.get("text").and_then(|t| t.as_str()).map(|s| s.to_string());
                                let timestamp = value.get("timestamp").and_then(|t| t.as_str()).map(|s| s.to_string());
                                if let (Some(source), Some(text), Some(timestamp)) = (source, text, timestamp) {
                                    segments.lock().unwrap().push(Segment { timestamp, source, text });
                                }
                            }
                        }
                    }
                    Err(e) => {
                        eprintln!("[tail] json parse error: {e} line={s}");
                    }
                },
                Err(e) => {
                    eprintln!("[tail] invalid utf-8 line: {e}");
                }
            }
        }
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let host = std::env::var("MIMI_OLLAMA_HOST")
        .unwrap_or_else(|_| "http://localhost:11434".to_string());
    let model = std::env::var("MIMI_OLLAMA_MODEL")
        .unwrap_or_else(|_| "qwen3:4b-instruct".to_string());
    let summary_interval = {
        let secs = std::env::var("MIMI_SUMMARY_INTERVAL_SECONDS")
            .ok()
            .and_then(|s| s.parse::<u64>().ok())
            .unwrap_or(30)
            .max(10);  // clamp min to 10s
        Duration::from_secs(secs)
    };
    let context_window = std::env::var("MIMI_CONTEXT_WINDOW_ENTRIES")
        .ok()
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(10)
        .max(1);  // clamp min to 1
    let http = reqwest::Client::builder()
        .build()
        .expect("failed to build reqwest client");
    let cfg = summarizer::SummarizerConfig::new(http, host, model);

    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_shell::init())
        .manage(AppState::new(cfg, summary_interval, context_window))
        .invoke_handler(tauri::generate_handler![start_recording, stop_recording])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
