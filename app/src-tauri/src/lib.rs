mod app;
mod config;
mod summarizer;

use crate::app::{commands, AppState};
use crate::config::Config;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_shell::init())
        .manage(AppState::new(Config::from_env()))
        .invoke_handler(tauri::generate_handler![
            commands::start_recording,
            commands::stop_recording,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
