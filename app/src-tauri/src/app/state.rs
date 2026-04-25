use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::oneshot;
use tokio::task::JoinHandle;

use crate::config::Config;
use crate::summarizer::SummarizerConfig;

pub(crate) struct Recording {
    pub(super) pid: u32,
    pub(super) terminated: oneshot::Receiver<()>,
    pub(super) tail_cancel: Arc<AtomicBool>,
    pub(super) tail: JoinHandle<()>,
    pub(super) output_path: PathBuf,
    pub(super) summarizer_cancel: Arc<AtomicBool>,
    pub(super) summarizer: JoinHandle<()>,
}

pub(crate) struct AppState {
    pub(super) recording: Mutex<Option<Recording>>,
    pub(super) current_session_id: Arc<AtomicU64>,
    pub(super) summarizer: Arc<SummarizerConfig>,
    pub(super) summary_interval: Duration,
    pub(super) context_window: usize,
}

impl AppState {
    pub(crate) fn new(config: Config) -> Self {
        let http = reqwest::Client::builder()
            .build()
            .expect("failed to build reqwest client");
        let summarizer = SummarizerConfig::new(http, config.host, config.model);
        Self {
            recording: Mutex::new(None),
            current_session_id: Arc::new(AtomicU64::new(0)),
            summarizer: Arc::new(summarizer),
            summary_interval: config.summary_interval,
            context_window: config.context_window,
        }
    }
}
