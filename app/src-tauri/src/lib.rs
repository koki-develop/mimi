use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
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

struct Recording {
    pid: u32,
    terminated: oneshot::Receiver<()>,
    tail_cancel: Arc<AtomicBool>,
    tail: JoinHandle<()>,
    output_path: PathBuf,
}

#[derive(Default)]
struct AppState {
    recording: Mutex<Option<Recording>>,
}

#[tauri::command]
async fn start_recording(app: AppHandle, state: State<'_, AppState>) -> Result<(), String> {
    {
        let guard = state.recording.lock().unwrap();
        if guard.is_some() {
            return Err("already recording".into());
        }
    }

    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_millis();
    let output_path = std::env::temp_dir().join(format!("mimi-{ts}.jsonl"));

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
                    // stop_recording がまだ take していない(= sidecar が自力で死んだ)ケースでは
                    // ここで tail / tmp / state の後片付けを行う。stop_recording が先行していた場合は
                    // take() が None を返すだけなので no-op になる。
                    let state = rx_app.state::<AppState>();
                    let taken = {
                        let mut guard = state.recording.lock().unwrap();
                        guard.take()
                    };
                    if let Some(recording) = taken {
                        recording.tail_cancel.store(true, Ordering::Release);
                        let _ = recording.tail.await;
                        let _ = std::fs::remove_file(&recording.output_path);
                    }
                    break;
                }
                _ => {}
            }
        }
    });

    let tail_cancel = Arc::new(AtomicBool::new(false));
    let tail_cancel_c = tail_cancel.clone();
    let app_handle = app.clone();
    let tail_path = output_path.clone();
    let tail = tokio::spawn(async move { tail_file(tail_path, app_handle, tail_cancel_c).await });

    let mut guard = state.recording.lock().unwrap();
    *guard = Some(Recording {
        pid,
        terminated: term_rx,
        tail_cancel,
        tail,
        output_path,
    });
    Ok(())
}

#[tauri::command]
async fn stop_recording(state: State<'_, AppState>) -> Result<(), String> {
    let recording = {
        let mut guard = state.recording.lock().unwrap();
        guard.take()
    };
    // rx タスクが自力停止時に先に take していることがある。その場合は no-op で成功扱い。
    let Some(recording) = recording else {
        return Ok(());
    };
    let Recording {
        pid,
        terminated,
        tail_cancel,
        tail,
        output_path,
    } = recording;

    // SIGINT が失敗する(ESRCH 等、プロセスが既に死んでいる)ケースは許容して cleanup を進める
    if let Err(e) = kill(Pid::from_raw(pid as i32), Signal::SIGINT) {
        eprintln!("[stop] SIGINT failed (process may have exited): {e}");
    } else {
        let _ = tokio::time::timeout(Duration::from_secs(10), terminated).await;
    }
    // tail の EOF ポーリング 1 サイクル分の余裕を持たせて最終行のドレインを確実にする
    tokio::time::sleep(Duration::from_millis(200)).await;
    tail_cancel.store(true, Ordering::Release);
    let _ = tail.await;

    let _ = std::fs::remove_file(&output_path);
    Ok(())
}

async fn tail_file(path: PathBuf, app: AppHandle, cancel: Arc<AtomicBool>) {
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
                        let _ = app.emit("transcribe://event", value);
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
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_shell::init())
        .manage(AppState::default())
        .invoke_handler(tauri::generate_handler![start_recording, stop_recording])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
