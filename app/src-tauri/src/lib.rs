mod app;
mod config;
mod summarizer;

use std::sync::atomic::AtomicU64;
use std::sync::Arc;

use tauri::Manager;

use crate::app::daemon::{Daemon, DaemonSpawnConfig, SummarizerHooks};
use crate::app::{commands, AppState};
use crate::config::Config;
use crate::summarizer::SummarizerConfig;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_shell::init())
        .setup(|app| {
            let config = Config::from_env();
            let current_session_id = Arc::new(AtomicU64::new(0));

            // Single SummarizerConfig (= single reqwest::Client / connection pool)
            // shared between the daemon's stdout-reader (which spawns per-session
            // summarizer tasks) and AppState (which `start_recording`'s health_check
            // borrows from).
            let http = reqwest::Client::builder()
                .build()
                .expect("failed to build reqwest client");
            let summarizer_config = Arc::new(SummarizerConfig::new(
                http,
                config.host.clone(),
                config.model.clone(),
            ));

            let hooks = SummarizerHooks {
                summarizer: summarizer_config.clone(),
                summary_interval: config.summary_interval,
                context_window: config.context_window,
                current_session_id: current_session_id.clone(),
                app: app.handle().clone(),
            };

            let spawn_config = DaemonSpawnConfig {
                model: std::env::var("MIMI_TRANSCRIBE_MODEL")
                    .unwrap_or_else(|_| "openai_whisper-large-v3-v20240930_turbo".into()),
                language: std::env::var("MIMI_TRANSCRIBE_LANGUAGE").unwrap_or_else(|_| "ja".into()),
                verbose: std::env::var("MIMI_TRANSCRIBE_VERBOSE")
                    .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
                    .unwrap_or(false),
            };

            let daemon =
                tauri::async_runtime::block_on(Daemon::spawn(app.handle(), hooks, spawn_config))?;

            app.manage(AppState::new(daemon, summarizer_config));
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::start_recording,
            commands::stop_recording,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
