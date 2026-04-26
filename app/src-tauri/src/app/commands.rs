use tauri::State;

use crate::app::daemon::{DaemonCommand, DaemonState};
use crate::app::state::AppState;
use crate::summarizer;

/// `start_recording` の Tauri command が daemon に start を投げる前に行う state 検証。
/// pure function なのでユニットテストで全分岐網羅できる。
fn validate_start_state(state: DaemonState) -> Result<(), String> {
    match state {
        DaemonState::Ready => Ok(()),
        DaemonState::Capturing | DaemonState::Stopping => Err("already recording".into()),
        other => Err(format!("daemon not ready (state: {other:?})")),
    }
}

#[tauri::command]
pub(crate) async fn start_recording(state: State<'_, AppState>) -> Result<(), String> {
    // Ollama health check (preserved from current behavior — fail-fast before
    // bothering the daemon).
    summarizer::health_check(&state.summarizer).await?;

    // Defense in depth: the frontend gates the button on Daemon::state == Ready,
    // but the user could race two clicks. The daemon will also reject the second
    // start with an `error` event, so this Rust-side check is purely to give the
    // Tauri command a synchronous error code.
    validate_start_state(state.daemon.state())?;

    state.daemon.send_command(&DaemonCommand::Start).await
}

#[tauri::command]
pub(crate) async fn stop_recording(state: State<'_, AppState>) -> Result<(), String> {
    // Idempotent. If not capturing, the daemon will emit an error event (which
    // surfaces via the event channel); our send still succeeds.
    state.daemon.send_command(&DaemonCommand::Stop).await
}

/// Toggles whether mic audio is forwarded into the Whisper transcriber.
/// Daemon-wide (persists across sessions, resets on app restart). The Swift
/// daemon emits no response event — frontend updates state optimistically.
#[tauri::command]
pub(crate) async fn set_mic_enabled(
    state: State<'_, AppState>,
    enabled: bool,
) -> Result<(), String> {
    state
        .daemon
        .send_command(&DaemonCommand::SetMicEnabled { enabled })
        .await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_start_state_accepts_ready() {
        assert!(validate_start_state(DaemonState::Ready).is_ok());
    }

    #[test]
    fn validate_start_state_rejects_capturing_as_already_recording() {
        let err = validate_start_state(DaemonState::Capturing).unwrap_err();
        assert_eq!(err, "already recording");
    }

    #[test]
    fn validate_start_state_rejects_stopping_as_already_recording() {
        let err = validate_start_state(DaemonState::Stopping).unwrap_err();
        assert_eq!(err, "already recording");
    }

    #[test]
    fn validate_start_state_rejects_loading_model_as_not_ready() {
        let err = validate_start_state(DaemonState::LoadingModel).unwrap_err();
        assert!(
            err.starts_with("daemon not ready"),
            "unexpected message: {err}"
        );
    }

    #[test]
    fn validate_start_state_rejects_dead_as_not_ready() {
        let err = validate_start_state(DaemonState::Dead).unwrap_err();
        assert!(
            err.starts_with("daemon not ready"),
            "unexpected message: {err}"
        );
    }

    #[test]
    fn validate_start_state_rejects_fatal_as_not_ready() {
        let err = validate_start_state(DaemonState::Fatal).unwrap_err();
        assert!(
            err.starts_with("daemon not ready"),
            "unexpected message: {err}"
        );
    }
}
