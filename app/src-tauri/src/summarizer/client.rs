//! Ollama HTTP client: chat completion + health check.

use std::time::Duration;

use serde::{Deserialize, Serialize};

use super::prompt::{build_entry_prompt, Segment, TimelineEntry};

#[derive(thiserror::Error, Debug)]
pub(super) enum SummaryError {
    #[error("HTTP status: {0}")]
    Http(reqwest::StatusCode),
    /// Request exceeded the configured timeout.
    ///
    /// Constructed explicitly at call sites — NOT via `?` from `reqwest::Error`.
    /// `reqwest` timeouts flow into `Transport` by default; promote them to
    /// `Timeout` in `.map_err` when you want to surface the configured duration.
    #[error("request timed out after {0:?}")]
    Timeout(Duration),
    #[error("response parse failed: {0}")]
    Parse(String),
    #[error("transport error: {0}")]
    Transport(#[from] reqwest::Error),
}

const CHAT_TIMEOUT: Duration = Duration::from_secs(120);

#[derive(Serialize)]
struct OllamaChatRequest<'a> {
    model: &'a str,
    stream: bool,
    messages: Vec<OllamaMessage<'a>>,
    options: OllamaOptions,
}

#[derive(Serialize)]
struct OllamaMessage<'a> {
    role: &'a str,
    content: &'a str,
}

#[derive(Serialize)]
struct OllamaOptions {
    temperature: f64,
}

#[derive(Deserialize)]
struct OllamaChatResponse {
    message: OllamaResponseMessage,
}

#[derive(Deserialize)]
struct OllamaResponseMessage {
    content: String,
}

struct ChatRequestOwned {
    model: String,
    system: &'static str,
    user: String,
}

impl Serialize for ChatRequestOwned {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let req = OllamaChatRequest {
            model: &self.model,
            stream: false,
            messages: vec![
                OllamaMessage {
                    role: "system",
                    content: self.system,
                },
                OllamaMessage {
                    role: "user",
                    content: &self.user,
                },
            ],
            options: OllamaOptions { temperature: 0.3 },
        };
        req.serialize(s)
    }
}

#[derive(Clone)]
pub(crate) struct SummarizerConfig {
    http: reqwest::Client,
    host: String,
    model: String,
}

impl SummarizerConfig {
    pub(crate) fn new(http: reqwest::Client, host: String, model: String) -> Self {
        Self { http, host, model }
    }
}

pub(super) async fn generate_summary(
    cfg: &SummarizerConfig,
    new_segments: &[Segment],
    prev_entries: &[TimelineEntry],
) -> Result<String, SummaryError> {
    let (system, user) = build_entry_prompt(prev_entries, new_segments);
    let body = ChatRequestOwned {
        model: cfg.model.clone(),
        system,
        user,
    };
    // Note: `e.is_timeout()` covers `RequestBuilder::timeout()` expiry (which we set above).
    // Connect-level timeouts from `ClientBuilder::connect_timeout` would arrive as
    // `is_connect()` and fall through to `Transport`. Acceptable for MVP.
    let resp = cfg
        .http
        .post(format!("{}/api/chat", cfg.host))
        .json(&body)
        .timeout(CHAT_TIMEOUT)
        .send()
        .await
        .map_err(|e| {
            if e.is_timeout() {
                SummaryError::Timeout(CHAT_TIMEOUT)
            } else {
                SummaryError::Transport(e)
            }
        })?;

    if !resp.status().is_success() {
        return Err(SummaryError::Http(resp.status()));
    }
    let parsed: OllamaChatResponse = resp
        .json()
        .await
        .map_err(|e| SummaryError::Parse(e.to_string()))?;
    Ok(parsed.message.content.trim().to_string())
}

#[derive(Deserialize)]
struct OllamaTagsResponse {
    models: Vec<OllamaTagEntry>,
}

#[derive(Deserialize)]
struct OllamaTagEntry {
    name: String,
}

pub(crate) async fn health_check(cfg: &SummarizerConfig) -> Result<(), String> {
    let resp = cfg
        .http
        .get(format!("{}/api/tags", cfg.host))
        .timeout(Duration::from_secs(5))
        .send()
        .await
        .map_err(|e| format!("Ollama に接続できない ({}): {e}", cfg.host))?;
    if !resp.status().is_success() {
        return Err(format!("Ollama のレスポンスが異常: {}", resp.status()));
    }
    let tags: OllamaTagsResponse = resp
        .json()
        .await
        .map_err(|e| format!("Ollama /api/tags のパースに失敗: {e}"))?;
    let found = tags.models.iter().any(|m| m.name == cfg.model);
    if !found {
        return Err(format!(
            "モデル '{}' が pull されていない。`ollama pull {}` を実行してください。",
            cfg.model, cfg.model
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::super::prompt::{Segment, Source};
    use super::*;
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[test]
    fn summary_error_http_displays_status() {
        let err = SummaryError::Http(reqwest::StatusCode::NOT_FOUND);
        assert_eq!(format!("{err}"), "HTTP status: 404 Not Found");
    }

    #[test]
    fn summary_error_parse_displays_message() {
        let err = SummaryError::Parse("boom".into());
        assert_eq!(format!("{err}"), "response parse failed: boom");
    }

    #[tokio::test]
    async fn generate_summary_returns_message_content_on_200() {
        let server = MockServer::start().await;

        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "model": "qwen3:4b",
                "message": { "role": "assistant", "content": "  要約本文です。  " },
                "done": true
            })))
            .mount(&server)
            .await;

        let cfg = SummarizerConfig::new(reqwest::Client::new(), server.uri(), "qwen3:4b".into());
        let segments = vec![Segment {
            timestamp: "t".into(),
            source: Source::Mic,
            text: "hi".into(),
        }];

        let out = generate_summary(&cfg, &segments, &[]).await.unwrap();
        assert_eq!(out, "要約本文です。");
    }

    #[tokio::test]
    async fn generate_summary_calls_api_chat_with_entry_prompt_when_prev_empty() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "message": { "role": "assistant", "content": "今日は会議が始まった。" }
            })))
            .mount(&server)
            .await;

        let cfg = SummarizerConfig::new(reqwest::Client::new(), server.uri(), "qwen3:4b".into());
        let segments = vec![Segment {
            timestamp: "2026-04-24T10:00:00.000+09:00".into(),
            source: Source::Mic,
            text: "はい".into(),
        }];
        let out = generate_summary(&cfg, &segments, &[]).await.unwrap();
        assert_eq!(out, "今日は会議が始まった。");
    }

    #[tokio::test]
    async fn generate_summary_serializes_previous_entries_in_user_message() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "message": { "role": "assistant", "content": "OK" }
            })))
            .mount(&server)
            .await;

        let cfg = SummarizerConfig::new(reqwest::Client::new(), server.uri(), "qwen3:4b".into());
        let prev = vec![TimelineEntry {
            generation: 1,
            range_start: "2026-04-24T10:00:00.000+09:00".into(),
            range_end: "2026-04-24T10:00:30.000+09:00".into(),
            text: "ぜんかい".into(),
        }];
        let segments = vec![Segment {
            timestamp: "2026-04-24T10:00:30.000+09:00".into(),
            source: Source::Mic,
            text: "こんかい".into(),
        }];
        let _ = generate_summary(&cfg, &segments, &prev).await.unwrap();

        let received = server.received_requests().await.unwrap();
        assert_eq!(received.len(), 1);
        let body: serde_json::Value = serde_json::from_slice(&received[0].body).unwrap();
        let user_msg = body["messages"][1]["content"].as_str().unwrap();
        assert!(
            user_msg.contains("<previous_entries>"),
            "user msg: {user_msg}"
        );
        assert!(user_msg.contains("[10:00:00] ぜんかい"));
        assert!(user_msg.contains("<transcript>"));
        assert!(user_msg.contains("[自分] こんかい"));
    }

    #[tokio::test]
    async fn generate_summary_returns_http_error_on_500() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(ResponseTemplate::new(500))
            .mount(&server)
            .await;

        let cfg = SummarizerConfig::new(reqwest::Client::new(), server.uri(), "x".into());
        let err = generate_summary(&cfg, &[], &[]).await.unwrap_err();
        assert!(
            matches!(err, SummaryError::Http(s) if s.as_u16() == 500),
            "got {err:?}"
        );
    }

    #[tokio::test]
    async fn generate_summary_returns_http_error_on_404() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(ResponseTemplate::new(404))
            .mount(&server)
            .await;

        let cfg = SummarizerConfig::new(reqwest::Client::new(), server.uri(), "x".into());
        let err = generate_summary(&cfg, &[], &[]).await.unwrap_err();
        assert!(matches!(err, SummaryError::Http(s) if s.as_u16() == 404));
    }

    #[tokio::test]
    async fn generate_summary_returns_parse_error_on_invalid_json() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(ResponseTemplate::new(200).set_body_string("not json at all"))
            .mount(&server)
            .await;

        let cfg = SummarizerConfig::new(reqwest::Client::new(), server.uri(), "x".into());
        let err = generate_summary(&cfg, &[], &[]).await.unwrap_err();
        assert!(matches!(err, SummaryError::Parse(_)), "got {err:?}");
    }

    #[tokio::test]
    async fn generate_summary_returns_transport_error_on_unreachable_host() {
        let cfg = SummarizerConfig::new(
            reqwest::Client::new(),
            "http://127.0.0.1:1".into(),
            "x".into(),
        );
        let err = generate_summary(&cfg, &[], &[]).await.unwrap_err();
        assert!(
            matches!(err, SummaryError::Transport(_) | SummaryError::Timeout(_)),
            "got {err:?}"
        );
    }

    #[tokio::test]
    async fn health_check_succeeds_when_exact_model_name_is_present() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/tags"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "models": [
                    { "name": "qwen3:4b", "modified_at": "2026-04-01T00:00:00Z", "size": 0 },
                    { "name": "llama3:8b", "modified_at": "2026-04-01T00:00:00Z", "size": 0 }
                ]
            })))
            .mount(&server)
            .await;

        let cfg = SummarizerConfig::new(reqwest::Client::new(), server.uri(), "qwen3:4b".into());
        health_check(&cfg).await.expect("should pass");
    }

    #[tokio::test]
    async fn health_check_fails_when_model_is_missing() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/tags"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "models": [
                    { "name": "other-model", "modified_at": "", "size": 0 }
                ]
            })))
            .mount(&server)
            .await;

        let cfg = SummarizerConfig::new(reqwest::Client::new(), server.uri(), "qwen3:4b".into());
        let err = health_check(&cfg).await.unwrap_err();
        assert!(err.contains("qwen3:4b"));
        assert!(err.contains("ollama pull"));
    }

    #[tokio::test]
    async fn health_check_does_not_match_on_substring() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/tags"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "models": [
                    { "name": "qwen3:4b-q4_0", "modified_at": "", "size": 0 }
                ]
            })))
            .mount(&server)
            .await;

        let cfg = SummarizerConfig::new(reqwest::Client::new(), server.uri(), "qwen3:4b".into());
        assert!(health_check(&cfg).await.is_err());
    }

    #[tokio::test]
    async fn health_check_fails_on_500() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/tags"))
            .respond_with(ResponseTemplate::new(500))
            .mount(&server)
            .await;

        let cfg = SummarizerConfig::new(reqwest::Client::new(), server.uri(), "x".into());
        let err = health_check(&cfg).await.unwrap_err();
        assert!(err.contains("500"));
    }

    #[tokio::test]
    async fn health_check_fails_when_host_unreachable() {
        let cfg = SummarizerConfig::new(
            reqwest::Client::new(),
            "http://127.0.0.1:1".into(),
            "x".into(),
        );
        let err = health_check(&cfg).await.unwrap_err();
        assert!(err.contains("接続できない"));
    }
}
