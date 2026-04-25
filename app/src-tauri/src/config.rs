use std::time::Duration;

pub(crate) struct Config {
    pub(crate) host: String,
    pub(crate) model: String,
    pub(crate) summary_interval: Duration,
    pub(crate) context_window: usize,
}

impl Config {
    pub(crate) fn from_env() -> Self {
        let host = std::env::var("MIMI_OLLAMA_HOST")
            .unwrap_or_else(|_| "http://localhost:11434".to_string());
        let model =
            std::env::var("MIMI_OLLAMA_MODEL").unwrap_or_else(|_| "qwen3:30b-instruct".to_string());
        let summary_interval = {
            let secs = std::env::var("MIMI_SUMMARY_INTERVAL_SECONDS")
                .ok()
                .and_then(|s| s.parse::<u64>().ok())
                .unwrap_or(30)
                .max(10);
            Duration::from_secs(secs)
        };
        let context_window = std::env::var("MIMI_CONTEXT_WINDOW_ENTRIES")
            .ok()
            .and_then(|s| s.parse::<usize>().ok())
            .unwrap_or(10)
            .max(1);
        Self {
            host,
            model,
            summary_interval,
            context_window,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    // Env var access is process-global. Serialize tests with a mutex to avoid
    // interleaved set/unset from other #[test]-thread workers.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    struct EnvGuard<'a> {
        _lock: std::sync::MutexGuard<'a, ()>,
        keys: Vec<&'static str>,
    }

    impl<'a> EnvGuard<'a> {
        fn new() -> Self {
            let lock = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
            let keys = vec![
                "MIMI_OLLAMA_HOST",
                "MIMI_OLLAMA_MODEL",
                "MIMI_SUMMARY_INTERVAL_SECONDS",
                "MIMI_CONTEXT_WINDOW_ENTRIES",
            ];
            for k in &keys {
                std::env::remove_var(k);
            }
            Self { _lock: lock, keys }
        }
    }

    impl<'a> Drop for EnvGuard<'a> {
        fn drop(&mut self) {
            for k in &self.keys {
                std::env::remove_var(k);
            }
        }
    }

    #[test]
    fn from_env_uses_defaults_when_vars_unset() {
        let _g = EnvGuard::new();
        let c = Config::from_env();
        assert_eq!(c.host, "http://localhost:11434");
        assert_eq!(c.model, "qwen3:30b-instruct");
        assert_eq!(c.summary_interval, Duration::from_secs(30));
        assert_eq!(c.context_window, 10);
    }

    #[test]
    fn from_env_reads_host_and_model() {
        let _g = EnvGuard::new();
        std::env::set_var("MIMI_OLLAMA_HOST", "http://example.com:9999");
        std::env::set_var("MIMI_OLLAMA_MODEL", "custom-model:7b");
        let c = Config::from_env();
        assert_eq!(c.host, "http://example.com:9999");
        assert_eq!(c.model, "custom-model:7b");
    }

    #[test]
    fn from_env_reads_summary_interval_seconds() {
        let _g = EnvGuard::new();
        std::env::set_var("MIMI_SUMMARY_INTERVAL_SECONDS", "45");
        let c = Config::from_env();
        assert_eq!(c.summary_interval, Duration::from_secs(45));
    }

    #[test]
    fn from_env_clamps_summary_interval_below_10s() {
        let _g = EnvGuard::new();
        std::env::set_var("MIMI_SUMMARY_INTERVAL_SECONDS", "5");
        let c = Config::from_env();
        assert_eq!(c.summary_interval, Duration::from_secs(10));
    }

    #[test]
    fn from_env_falls_back_to_default_on_non_numeric_interval() {
        let _g = EnvGuard::new();
        std::env::set_var("MIMI_SUMMARY_INTERVAL_SECONDS", "not-a-number");
        let c = Config::from_env();
        assert_eq!(c.summary_interval, Duration::from_secs(30));
    }

    #[test]
    fn from_env_reads_context_window() {
        let _g = EnvGuard::new();
        std::env::set_var("MIMI_CONTEXT_WINDOW_ENTRIES", "25");
        let c = Config::from_env();
        assert_eq!(c.context_window, 25);
    }

    #[test]
    fn from_env_clamps_context_window_below_1() {
        let _g = EnvGuard::new();
        std::env::set_var("MIMI_CONTEXT_WINDOW_ENTRIES", "0");
        let c = Config::from_env();
        assert_eq!(c.context_window, 1);
    }

    #[test]
    fn from_env_falls_back_to_default_on_non_numeric_context_window() {
        let _g = EnvGuard::new();
        std::env::set_var("MIMI_CONTEXT_WINDOW_ENTRIES", "xyz");
        let c = Config::from_env();
        assert_eq!(c.context_window, 10);
    }
}
