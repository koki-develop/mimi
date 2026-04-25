use std::sync::Arc;

use crate::app::daemon::Daemon;
use crate::summarizer::SummarizerConfig;

pub(crate) struct AppState {
    pub(super) daemon: Daemon,
    /// `start_recording` の Ollama health check で参照する。
    pub(super) summarizer: Arc<SummarizerConfig>,
}

impl AppState {
    pub(crate) fn new(daemon: Daemon, summarizer: Arc<SummarizerConfig>) -> Self {
        Self { daemon, summarizer }
    }
}
