//! 録音中リアルタイム要約のパイプライン。
//! モジュール構成は docs/superpowers/specs/2026-04-24-recording-summarizer-design.md を参照。

use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Source {
    Mic,
    System,
}

/// A transcription segment emitted by the Swift sidecar.
///
/// Note: the field names on this struct happen to correspond to the Swift-side
/// JSONL keys (`timestamp`, `source`, `text`), but the integration in
/// `src-tauri/src/lib.rs::tail_file` does NOT serde-deserialize directly —
/// it manually picks fields out of `serde_json::Value` and constructs
/// `Segment`. The `Serialize`/`Deserialize` derives are kept for future use
/// (e.g., persistence, IPC) but are not currently on any hot path.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Segment {
    pub timestamp: String, // ISO8601
    pub source: Source,
    pub text: String,
}

#[derive(thiserror::Error, Debug)]
pub enum SummaryError {
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

fn escape_xml(s: &str) -> String {
    s.replace('&', "&amp;")
     .replace('<', "&lt;")
     .replace('>', "&gt;")
}

const CHAT_TIMEOUT: Duration = Duration::from_secs(120);
const MAX_CONCURRENT_SUMMARIES: u8 = 2;
const CANCEL_POLL_INTERVAL: Duration = Duration::from_millis(100);

const SYSTEM_PROMPT_INITIAL: &str = "会議の音声文字起こしを要約するタスクです。

入力:
<transcript> タグ内に発話の時系列記録が与えられます。発話の表記:
- `[自分]` : 記録者本人の発話（マイク入力）
- `[他者]` : それ以外の発話（1 人とは限らず、複数人が含まれる可能性があります）

出力要件:
- 日本語
- 1 段落のみ。4〜6 文、全体で 200〜400 字程度
- 会話の流れがわかる連文で書く（箇条書き禁止）
- 発話内容に忠実に。記録にないことは書かない（推測・補完・創作禁止）
- 「要約：」等の前置き、自己言及、メタ的コメントは書かない
- 思考過程や下書きは書かず、完成した要約本文のみを出力する";

fn format_segments(segments: &[Segment]) -> String {
    segments
        .iter()
        .map(|s| {
            let speaker = match s.source {
                Source::Mic => "[自分]",
                Source::System => "[他者]",
            };
            format!("{speaker} {}", escape_xml(&s.text))
        })
        .collect::<Vec<_>>()
        .join("\n")
}

pub fn build_initial_prompt(segments: &[Segment]) -> (&'static str, String) {
    let body = format_segments(segments);
    let user = if body.is_empty() {
        "<transcript>\n</transcript>".to_string()
    } else {
        format!("<transcript>\n{body}\n</transcript>")
    };
    (SYSTEM_PROMPT_INITIAL, user)
}

const SYSTEM_PROMPT_UPDATE: &str = "会議の音声文字起こしを継続的に要約するタスクです。直前の要約を、新しく追加された発話の内容を取り込んだ最新版に更新します。

入力:
- <previous_summary> タグ内: 直前時点までの要約
- <transcript> タグ内: その後に追加された発話の時系列記録

発話の表記:
- `[自分]` : 記録者本人の発話（マイク入力）
- `[他者]` : それ以外の発話（1 人とは限らず、複数人が含まれる可能性があります）

更新ルール:
- 直前の要約を土台として、新しい発話の内容を反映した「現時点までの流れ」を表す最新版を出力する
- 古い情報が新しい発話で訂正・更新された場合は最新の状態を優先する
- 議論が発展したときはその展開も反映する

出力要件:
- 日本語
- 1 段落のみ。4〜6 文、全体で 200〜400 字程度
- 会話の流れがわかる連文で書く（箇条書き禁止）
- 発話内容に忠実に。記録にないことは書かない（推測・補完・創作禁止）
- 「要約：」等の前置き、自己言及、メタ的コメントは書かない
- 思考過程や下書きは書かず、完成した要約本文のみを出力する";

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

fn build_chat_request(model: &str, new_segments: &[Segment], prev: Option<&str>) -> ChatRequestOwned {
    let (system, user) = match prev {
        None => build_initial_prompt(new_segments),
        Some(p) => build_update_prompt(p, new_segments),
    };
    ChatRequestOwned { model: model.to_string(), system, user }
}

impl Serialize for ChatRequestOwned {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let req = OllamaChatRequest {
            model: &self.model,
            stream: false,
            messages: vec![
                OllamaMessage { role: "system", content: self.system },
                OllamaMessage { role: "user",   content: &self.user },
            ],
            options: OllamaOptions { temperature: 0.3 },
        };
        req.serialize(s)
    }
}

#[derive(Clone)]
pub struct SummarizerConfig {
    http: reqwest::Client,
    pub host: String,
    pub model: String,
}

impl SummarizerConfig {
    pub fn new(http: reqwest::Client, host: String, model: String) -> Self {
        Self { http, host, model }
    }
}

pub async fn generate_summary(
    cfg: &SummarizerConfig,
    new_segments: &[Segment],
    prev: Option<&str>,
) -> Result<String, SummaryError> {
    let body = build_chat_request(&cfg.model, new_segments, prev);
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
        .map_err(|e| if e.is_timeout() { SummaryError::Timeout(CHAT_TIMEOUT) } else { SummaryError::Transport(e) })?;

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

pub async fn health_check(cfg: &SummarizerConfig) -> Result<(), String> {
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

pub fn build_update_prompt(prev_summary: &str, segments: &[Segment]) -> (&'static str, String) {
    let body = format_segments(segments);
    let transcript = if body.is_empty() {
        "<transcript>\n</transcript>".to_string()
    } else {
        format!("<transcript>\n{body}\n</transcript>")
    };
    let user = format!(
        "<previous_summary>\n{}\n</previous_summary>\n\n{transcript}",
        escape_xml(prev_summary)
    );
    (SYSTEM_PROMPT_UPDATE, user)
}

// ---------------------------------------------------------------------------
// SummarizerState — concurrency admission
// ---------------------------------------------------------------------------

pub struct SummarizerState {
    pub session_id: u64,
    generation: AtomicU64,
    running_count: AtomicU8,
    latest_displayed_gen: AtomicU64,
    latest_summary: Mutex<Option<String>>,
}

impl SummarizerState {
    pub fn new(session_id: u64) -> Self {
        Self {
            session_id,
            generation: AtomicU64::new(0),
            running_count: AtomicU8::new(0),
            latest_displayed_gen: AtomicU64::new(0),
            latest_summary: Mutex::new(None),
        }
    }

    /// CAS で最大 2 並列まで受け入れる。受け入れたら true、満員なら false。
    pub fn try_admit(&self) -> bool {
        self.running_count
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| {
                if n < MAX_CONCURRENT_SUMMARIES { Some(n + 1) } else { None }
            })
            .is_ok()
    }

    pub fn release(&self) {
        // spec §5.2.2 は `fetch_sub(1, Ordering::AcqRel)` を記述するが、
        // running_count が 0 のときの `fetch_sub` は u8 の wrap で 255 になり
        // 二度と admit できなくなる致命的バグを生む。MVP 実装では spec より厳格に
        // CAS で saturating sub を採用する。
        self.running_count
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| {
                if n > 0 { Some(n - 1) } else { Some(0) }
            })
            .ok();
    }
}

// ---------------------------------------------------------------------------
// SummaryEmitter — event emission trait
// ---------------------------------------------------------------------------

pub trait SummaryEmitter: Send + Sync + 'static {
    fn emit_generating(&self, session_id: u64, generation: u64);
    fn emit_summary(&self, session_id: u64, generation: u64, text: &str);
    fn emit_error(&self, session_id: u64, generation: u64, message: &str);
}

// ---------------------------------------------------------------------------
// SummaryEventPayload — discriminated-union event types emitted to the frontend
// ---------------------------------------------------------------------------

#[derive(Serialize, Clone)]
#[serde(tag = "type", rename_all = "lowercase")]
enum SummaryEventPayload<'a> {
    Generating { session_id: u64, generation: u64, timestamp: &'a str },
    Summary { session_id: u64, generation: u64, timestamp: &'a str, text: &'a str },
    Error { session_id: u64, generation: u64, timestamp: &'a str, message: &'a str },
}

fn summary_event_generating(session_id: u64, generation: u64, ts: &str) -> SummaryEventPayload<'_> {
    SummaryEventPayload::Generating { session_id, generation, timestamp: ts }
}
fn summary_event_summary<'a>(session_id: u64, generation: u64, ts: &'a str, text: &'a str) -> SummaryEventPayload<'a> {
    SummaryEventPayload::Summary { session_id, generation, timestamp: ts, text }
}
fn summary_event_error<'a>(session_id: u64, generation: u64, ts: &'a str, message: &'a str) -> SummaryEventPayload<'a> {
    SummaryEventPayload::Error { session_id, generation, timestamp: ts, message }
}

// ---------------------------------------------------------------------------
// TauriSummaryEmitter — emits summary events to the Tauri frontend
// ---------------------------------------------------------------------------

pub struct TauriSummaryEmitter {
    pub app: AppHandle,
}

impl TauriSummaryEmitter {
    fn now_iso() -> String {
        use chrono::{DateTime, Local, Utc};
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default();
        let millis = now.as_millis() as i64;
        DateTime::<Utc>::from_timestamp_millis(millis)
            .map(|dt| dt.with_timezone(&Local).to_rfc3339_opts(chrono::SecondsFormat::Millis, false))
            .unwrap_or_else(|| "1970-01-01T00:00:00.000+00:00".to_string())
    }
}

impl SummaryEmitter for TauriSummaryEmitter {
    fn emit_generating(&self, session_id: u64, generation: u64) {
        let ts = Self::now_iso();
        let _ = self.app.emit("summary://event", summary_event_generating(session_id, generation, &ts));
    }
    fn emit_summary(&self, session_id: u64, generation: u64, text: &str) {
        let ts = Self::now_iso();
        let _ = self.app.emit("summary://event", summary_event_summary(session_id, generation, &ts, text));
    }
    fn emit_error(&self, session_id: u64, generation: u64, message: &str) {
        let ts = Self::now_iso();
        let _ = self.app.emit("summary://event", summary_event_error(session_id, generation, &ts, message));
    }
}

// ---------------------------------------------------------------------------
// wait_for_cancel — polls an AtomicBool until it flips to true
// ---------------------------------------------------------------------------

pub async fn wait_for_cancel(cancel: &Arc<AtomicBool>) {
    loop {
        if cancel.load(Ordering::Acquire) { return; }
        tokio::time::sleep(CANCEL_POLL_INTERVAL).await;
    }
}

// ---------------------------------------------------------------------------
// summarizer_loop — main periodic summarization loop
// ---------------------------------------------------------------------------

pub async fn summarizer_loop(
    segments: Arc<Mutex<Vec<Segment>>>,
    state: Arc<SummarizerState>,
    emitter: Arc<dyn SummaryEmitter>,
    cancel: Arc<AtomicBool>,
    current_session_id: Arc<AtomicU64>,
    config: SummarizerConfig,
    tick_interval: Duration,
) {
    let mut ticker = tokio::time::interval(tick_interval);
    ticker.tick().await; // 初回即時発火を捨てる

    let mut last_tried_end_index: usize = 0;

    loop {
        tokio::select! {
            _ = ticker.tick() => {}
            () = wait_for_cancel(&cancel) => return,
        }
        if cancel.load(Ordering::Acquire) { return; }

        // 新規 segment 切り出し
        let (new_segments, tried_end_index) = {
            let lock = segments.lock().unwrap();
            if lock.len() == last_tried_end_index {
                continue;
            }
            let slice = lock[last_tried_end_index..].to_vec();
            (slice, lock.len())
        };
        last_tried_end_index = tried_end_index;

        if !state.try_admit() {
            continue;
        }

        let gen = state.generation.fetch_add(1, Ordering::AcqRel) + 1;
        let prev = state.latest_summary.lock().unwrap().clone();
        emitter.emit_generating(state.session_id, gen);

        let state_c = state.clone();
        let emitter_c = emitter.clone();
        let cfg_c = config.clone();
        let current_session_id_c = current_session_id.clone();
        tokio::spawn(async move {
            let result = generate_summary(&cfg_c, &new_segments, prev.as_deref()).await;

            if current_session_id_c.load(Ordering::Acquire) != state_c.session_id {
                state_c.release();
                return;
            }

            match result {
                Ok(text) => {
                    if gen <= state_c.latest_displayed_gen.load(Ordering::Acquire) {
                        state_c.release();
                        return;
                    }
                    state_c.latest_displayed_gen.store(gen, Ordering::Release);
                    *state_c.latest_summary.lock().unwrap() = Some(text.clone());
                    emitter_c.emit_summary(state_c.session_id, gen, &text);
                }
                Err(e) => {
                    emitter_c.emit_error(state_c.session_id, gen, &e.to_string());
                }
            }
            state_c.release();
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
    use wiremock::{MockServer, Mock, ResponseTemplate};
    use wiremock::matchers::{method, path};

    // ---------------------------------------------------------------------------
    // MockEmitter for testing
    // ---------------------------------------------------------------------------

    #[derive(Debug, Clone)]
    pub enum EmittedEvent {
        Generating { session_id: u64, generation: u64 },
        Summary { session_id: u64, generation: u64, text: String },
        Error { session_id: u64, generation: u64, message: String },
    }

    #[derive(Default)]
    pub struct MockEmitter {
        pub calls: Mutex<Vec<EmittedEvent>>,
    }

    impl SummaryEmitter for MockEmitter {
        fn emit_generating(&self, session_id: u64, generation: u64) {
            self.calls.lock().unwrap().push(EmittedEvent::Generating { session_id, generation });
        }
        fn emit_summary(&self, session_id: u64, generation: u64, text: &str) {
            self.calls.lock().unwrap().push(EmittedEvent::Summary { session_id, generation, text: text.to_string() });
        }
        fn emit_error(&self, session_id: u64, generation: u64, message: &str) {
            self.calls.lock().unwrap().push(EmittedEvent::Error { session_id, generation, message: message.to_string() });
        }
    }

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

    #[test]
    fn escape_xml_replaces_angle_brackets() {
        assert_eq!(escape_xml("<tag>"), "&lt;tag&gt;");
        assert_eq!(escape_xml("no brackets"), "no brackets");
        assert_eq!(escape_xml("a<b>c<d>"), "a&lt;b&gt;c&lt;d&gt;");
    }

    #[test]
    fn escape_xml_replaces_ampersand_first() {
        assert_eq!(escape_xml("Q&A"), "Q&amp;A");
        assert_eq!(escape_xml("a&b<c>"), "a&amp;b&lt;c&gt;");
        assert_eq!(escape_xml("already &amp;"), "already &amp;amp;"); // double-escape is expected (idempotent escape is not a goal)
    }

    #[test]
    fn escape_xml_preserves_non_ascii() {
        assert_eq!(escape_xml("日本語は<そのまま>"), "日本語は&lt;そのまま&gt;");
    }

    #[test]
    fn build_initial_prompt_wraps_segments_in_transcript_tags() {
        let segments = vec![
            Segment { timestamp: "t1".into(), source: Source::Mic, text: "こんにちは".into() },
            Segment { timestamp: "t2".into(), source: Source::System, text: "はい<どうぞ>".into() },
        ];
        let (system, user) = build_initial_prompt(&segments);

        assert!(system.contains("<transcript> タグ内"), "system prompt should describe <transcript> tag");
        assert!(system.contains("[自分]"), "system prompt should mention [自分]");
        assert!(system.contains("[他者]"), "system prompt should mention [他者]");
        assert!(!system.contains("<previous_summary>"), "initial prompt must not reference previous_summary");

        assert_eq!(
            user,
            "<transcript>\n[自分] こんにちは\n[他者] はい&lt;どうぞ&gt;\n</transcript>"
        );
    }

    #[test]
    fn build_initial_prompt_handles_empty_segments() {
        let (_, user) = build_initial_prompt(&[]);
        assert_eq!(user, "<transcript>\n</transcript>");
    }

    #[test]
    fn build_update_prompt_includes_previous_summary_and_new_segments() {
        let segments = vec![
            Segment { timestamp: "t3".into(), source: Source::Mic, text: "進捗を共有します".into() },
        ];
        let (system, user) = build_update_prompt("これまでの要約本文", &segments);

        assert!(system.contains("<previous_summary>"), "update prompt should mention previous_summary");
        assert!(system.contains("<transcript>"), "update prompt should mention transcript");
        assert!(system.contains("更新ルール"), "update prompt should contain update rules");

        assert_eq!(
            user,
            "<previous_summary>\nこれまでの要約本文\n</previous_summary>\n\n<transcript>\n[自分] 進捗を共有します\n</transcript>"
        );
    }

    #[test]
    fn build_update_prompt_escapes_previous_summary_brackets() {
        let (_, user) = build_update_prompt("要<約>", &[]);
        assert!(user.contains("要&lt;約&gt;"), "previous summary must be xml-escaped");
    }

    // Task 8 tests
    #[test]
    fn build_chat_request_initial_has_expected_shape() {
        let segments = vec![
            Segment { timestamp: "t1".into(), source: Source::Mic, text: "テスト".into() },
        ];
        let body = build_chat_request("qwen3:4b", &segments, None);
        let json = serde_json::to_value(&body).unwrap();

        assert_eq!(json["model"], "qwen3:4b");
        assert_eq!(json["stream"], false);
        assert_eq!(json["options"]["temperature"], 0.3);
        assert!(json.get("think").is_none(), "think should not be sent anymore");
        assert!(json["options"].get("stop").is_none(), "stop tokens should not be sent anymore");

        let messages = json["messages"].as_array().unwrap();
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0]["role"], "system");
        assert!(messages[0]["content"].as_str().unwrap().contains("<transcript>"));
        assert!(!messages[0]["content"].as_str().unwrap().contains("<previous_summary>"));
        assert_eq!(messages[1]["role"], "user");
        assert!(messages[1]["content"].as_str().unwrap().contains("[自分] テスト"));
    }

    #[test]
    fn build_chat_request_update_uses_update_system_prompt_and_includes_previous_summary() {
        let segments = vec![
            Segment { timestamp: "t2".into(), source: Source::System, text: "続き".into() },
        ];
        let body = build_chat_request("qwen3:4b", &segments, Some("前回の要約"));
        let json = serde_json::to_value(&body).unwrap();

        let messages = json["messages"].as_array().unwrap();
        assert!(messages[0]["content"].as_str().unwrap().contains("<previous_summary>"));
        assert!(messages[1]["content"].as_str().unwrap().contains("<previous_summary>\n前回の要約"));
        assert!(messages[1]["content"].as_str().unwrap().contains("[他者] 続き"));
    }

    // Task 9 tests
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
        let segments = vec![Segment { timestamp: "t".into(), source: Source::Mic, text: "hi".into() }];

        let out = generate_summary(&cfg, &segments, None).await.unwrap();
        assert_eq!(out, "要約本文です。");
    }

    // Task 10 tests
    #[tokio::test]
    async fn generate_summary_returns_http_error_on_500() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(ResponseTemplate::new(500))
            .mount(&server)
            .await;

        let cfg = SummarizerConfig::new(reqwest::Client::new(), server.uri(), "x".into());
        let err = generate_summary(&cfg, &[], None).await.unwrap_err();
        assert!(matches!(err, SummaryError::Http(s) if s.as_u16() == 500), "got {err:?}");
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
        let err = generate_summary(&cfg, &[], None).await.unwrap_err();
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
        let err = generate_summary(&cfg, &[], None).await.unwrap_err();
        assert!(matches!(err, SummaryError::Parse(_)), "got {err:?}");
    }

    #[tokio::test]
    async fn generate_summary_returns_transport_error_on_unreachable_host() {
        let cfg = SummarizerConfig::new(reqwest::Client::new(), "http://127.0.0.1:1".into(), "x".into());
        let err = generate_summary(&cfg, &[], None).await.unwrap_err();
        assert!(
            matches!(err, SummaryError::Transport(_) | SummaryError::Timeout(_)),
            "got {err:?}"
        );
    }

    // Task 11 test
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

    // Task 12 tests
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
        let cfg = SummarizerConfig::new(reqwest::Client::new(), "http://127.0.0.1:1".into(), "x".into());
        let err = health_check(&cfg).await.unwrap_err();
        assert!(err.contains("接続できない"));
    }

    // ---------------------------------------------------------------------------
    // Task 13: SummarizerState tests
    // ---------------------------------------------------------------------------

    #[test]
    fn summarizer_state_new_initializes_defaults() {
        let s = SummarizerState::new(42);
        assert_eq!(s.session_id, 42);
        assert_eq!(s.generation.load(Ordering::Acquire), 0);
        assert_eq!(s.running_count.load(Ordering::Acquire), 0);
        assert_eq!(s.latest_displayed_gen.load(Ordering::Acquire), 0);
        assert!(s.latest_summary.lock().unwrap().is_none());
    }

    #[test]
    fn try_admit_succeeds_up_to_two_and_fails_on_third() {
        let s = SummarizerState::new(1);
        assert!(s.try_admit(), "1st admit should succeed");
        assert!(s.try_admit(), "2nd admit should succeed");
        assert!(!s.try_admit(), "3rd admit should fail");
        s.release();
        assert!(s.try_admit(), "after release, 3rd admit should succeed");
    }

    #[test]
    fn release_does_not_go_below_zero() {
        let s = SummarizerState::new(1);
        s.release();
        assert_eq!(s.running_count.load(Ordering::Acquire), 0,
            "release on zero-count should saturate at 0");
    }

    // ---------------------------------------------------------------------------
    // Task 14: MockEmitter test
    // ---------------------------------------------------------------------------

    #[test]
    fn mock_emitter_records_calls_in_order() {
        let m = Arc::new(MockEmitter::default());
        m.emit_generating(10, 1);
        m.emit_summary(10, 1, "hello");
        m.emit_error(10, 2, "err");

        let calls = m.calls.lock().unwrap().clone();
        assert_eq!(calls.len(), 3);
        assert!(matches!(calls[0], EmittedEvent::Generating { session_id: 10, generation: 1 }));
        assert!(matches!(&calls[1], EmittedEvent::Summary { session_id: 10, generation: 1, text } if text == "hello"));
        assert!(matches!(&calls[2], EmittedEvent::Error { session_id: 10, generation: 2, message } if message == "err"));
    }

    // ---------------------------------------------------------------------------
    // Task 15: wait_for_cancel tests
    // ---------------------------------------------------------------------------

    #[tokio::test]
    async fn wait_for_cancel_returns_when_flag_flips_to_true() {
        let flag = Arc::new(AtomicBool::new(false));
        let flag_c = flag.clone();

        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(200)).await;
            flag_c.store(true, Ordering::Release);
        });

        let start = std::time::Instant::now();
        wait_for_cancel(&flag).await;
        let elapsed = start.elapsed();
        assert!(elapsed >= Duration::from_millis(200), "should wait at least 200ms");
        assert!(elapsed < Duration::from_millis(1000), "should return shortly after flag flip, got {elapsed:?}");
    }

    #[tokio::test]
    async fn wait_for_cancel_returns_immediately_if_already_true() {
        let flag = Arc::new(AtomicBool::new(true));
        let start = std::time::Instant::now();
        wait_for_cancel(&flag).await;
        assert!(start.elapsed() < Duration::from_millis(200));
    }

    // ---------------------------------------------------------------------------
    // Task 16: summarizer_loop exits on cancel
    // ---------------------------------------------------------------------------

    #[tokio::test]
    async fn summarizer_loop_exits_on_cancel() {
        let segments = Arc::new(Mutex::new(Vec::<Segment>::new()));
        let state = Arc::new(SummarizerState::new(1));
        let emitter: Arc<dyn SummaryEmitter> = Arc::new(MockEmitter::default());
        let cancel = Arc::new(AtomicBool::new(false));
        let current_session_id = Arc::new(AtomicU64::new(1));
        let cfg = SummarizerConfig::new(reqwest::Client::new(), "http://unused".into(), "x".into());

        let cancel_c = cancel.clone();
        let handle = tokio::spawn(summarizer_loop(
            segments, state, emitter, cancel, current_session_id, cfg,
            Duration::from_millis(50),
        ));

        tokio::time::sleep(Duration::from_millis(150)).await;
        cancel_c.store(true, Ordering::Release);

        let joined = tokio::time::timeout(Duration::from_secs(2), handle).await;
        assert!(joined.is_ok(), "summarizer_loop should exit within 2s after cancel");
    }

    // ---------------------------------------------------------------------------
    // Task 17: happy path + skip-when-no-new-segments
    // ---------------------------------------------------------------------------

    #[tokio::test]
    async fn summarizer_loop_emits_summary_for_new_segments() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "message": { "role": "assistant", "content": "まとめ" }
            })))
            .mount(&server)
            .await;

        let segments = Arc::new(Mutex::new(vec![
            Segment { timestamp: "t".into(), source: Source::Mic, text: "hi".into() },
        ]));
        let state = Arc::new(SummarizerState::new(100));
        let emitter_inner = Arc::new(MockEmitter::default());
        let emitter: Arc<dyn SummaryEmitter> = emitter_inner.clone();
        let cancel = Arc::new(AtomicBool::new(false));
        let current_session_id = Arc::new(AtomicU64::new(100));
        let cfg = SummarizerConfig::new(reqwest::Client::new(), server.uri(), "qwen3:4b".into());

        let cancel_c = cancel.clone();
        let handle = tokio::spawn(summarizer_loop(
            segments, state, emitter, cancel, current_session_id, cfg,
            Duration::from_millis(50),
        ));

        tokio::time::sleep(Duration::from_millis(400)).await;
        cancel_c.store(true, Ordering::Release);
        let _ = tokio::time::timeout(Duration::from_secs(2), handle).await;

        let calls = emitter_inner.calls.lock().unwrap().clone();
        let summary_count = calls.iter().filter(|e| matches!(e, EmittedEvent::Summary { .. })).count();
        let generating_count = calls.iter().filter(|e| matches!(e, EmittedEvent::Generating { .. })).count();
        assert!(summary_count >= 1, "expected >= 1 summary emit, got calls: {calls:?}");
        assert_eq!(generating_count, summary_count, "each summary should be preceded by a generating event");
    }

    #[tokio::test]
    async fn summarizer_loop_skips_when_no_new_segments() {
        let server = MockServer::start().await;

        let segments = Arc::new(Mutex::new(Vec::<Segment>::new()));
        let state = Arc::new(SummarizerState::new(1));
        let emitter_inner = Arc::new(MockEmitter::default());
        let emitter: Arc<dyn SummaryEmitter> = emitter_inner.clone();
        let cancel = Arc::new(AtomicBool::new(false));
        let current_session_id = Arc::new(AtomicU64::new(1));
        let cfg = SummarizerConfig::new(reqwest::Client::new(), server.uri(), "x".into());

        let cancel_c = cancel.clone();
        let handle = tokio::spawn(summarizer_loop(
            segments, state, emitter, cancel, current_session_id, cfg,
            Duration::from_millis(50),
        ));
        tokio::time::sleep(Duration::from_millis(300)).await;
        cancel_c.store(true, Ordering::Release);
        let _ = tokio::time::timeout(Duration::from_secs(2), handle).await;

        let calls = emitter_inner.calls.lock().unwrap().clone();
        assert!(calls.is_empty(), "no segments → no emit, got {calls:?}");
    }

    // ---------------------------------------------------------------------------
    // Task 18: generation skew — newer gen finishes first, older discarded
    // ---------------------------------------------------------------------------

    #[tokio::test]
    async fn summarizer_loop_discards_older_generation_when_newer_finishes_first() {
        use std::sync::atomic::AtomicUsize;

        let server = MockServer::start().await;
        let call_count = Arc::new(AtomicUsize::new(0));
        let cc = call_count.clone();

        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(move |_: &wiremock::Request| {
                let n = cc.fetch_add(1, Ordering::AcqRel);
                if n == 0 {
                    ResponseTemplate::new(200)
                        .set_delay(Duration::from_millis(400))
                        .set_body_json(serde_json::json!({
                            "message": { "role": "assistant", "content": "GEN1" }
                        }))
                } else {
                    ResponseTemplate::new(200)
                        .set_delay(Duration::from_millis(50))
                        .set_body_json(serde_json::json!({
                            "message": { "role": "assistant", "content": "GEN2" }
                        }))
                }
            })
            .mount(&server)
            .await;

        let segments = Arc::new(Mutex::new(vec![
            Segment { timestamp: "t1".into(), source: Source::Mic, text: "a".into() },
        ]));
        let state = Arc::new(SummarizerState::new(1));
        let emitter_inner = Arc::new(MockEmitter::default());
        let emitter: Arc<dyn SummaryEmitter> = emitter_inner.clone();
        let cancel = Arc::new(AtomicBool::new(false));
        let current_session_id = Arc::new(AtomicU64::new(1));
        let cfg = SummarizerConfig::new(reqwest::Client::new(), server.uri(), "x".into());

        let segments_c = segments.clone();
        let cancel_c = cancel.clone();
        let handle = tokio::spawn(summarizer_loop(
            segments, state, emitter, cancel, current_session_id, cfg,
            Duration::from_millis(50),
        ));

        tokio::time::sleep(Duration::from_millis(120)).await;
        segments_c.lock().unwrap().push(
            Segment { timestamp: "t2".into(), source: Source::Mic, text: "b".into() }
        );
        tokio::time::sleep(Duration::from_millis(600)).await;
        cancel_c.store(true, Ordering::Release);
        let _ = tokio::time::timeout(Duration::from_secs(2), handle).await;

        let calls = emitter_inner.calls.lock().unwrap().clone();
        let summaries: Vec<_> = calls.iter().filter_map(|e| {
            if let EmittedEvent::Summary { generation, text, .. } = e { Some((*generation, text.clone())) } else { None }
        }).collect();

        assert!(summaries.iter().any(|(g, t)| *g == 2 && t == "GEN2"), "gen2 should be emitted: {summaries:?}");
        assert!(!summaries.iter().any(|(g, t)| *g == 1 && t == "GEN1"),
            "gen1 must be discarded because gen2 already displayed: {summaries:?}");
    }

    // ---------------------------------------------------------------------------
    // Task 19: session_id guard
    // ---------------------------------------------------------------------------

    #[tokio::test]
    async fn summarizer_loop_does_not_emit_when_session_id_changed() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(ResponseTemplate::new(200)
                .set_delay(Duration::from_millis(300))
                .set_body_json(serde_json::json!({
                    "message": { "role": "assistant", "content": "stale" }
                })))
            .mount(&server)
            .await;

        let segments = Arc::new(Mutex::new(vec![
            Segment { timestamp: "t".into(), source: Source::Mic, text: "a".into() },
        ]));
        let state = Arc::new(SummarizerState::new(1));
        let emitter_inner = Arc::new(MockEmitter::default());
        let emitter: Arc<dyn SummaryEmitter> = emitter_inner.clone();
        let cancel = Arc::new(AtomicBool::new(false));
        let current_session_id = Arc::new(AtomicU64::new(1));
        let cfg = SummarizerConfig::new(reqwest::Client::new(), server.uri(), "x".into());

        let current_session_id_c = current_session_id.clone();
        let cancel_c = cancel.clone();
        let handle = tokio::spawn(summarizer_loop(
            segments, state, emitter, cancel, current_session_id, cfg,
            Duration::from_millis(50),
        ));

        tokio::time::sleep(Duration::from_millis(150)).await;
        current_session_id_c.store(999, Ordering::Release);
        tokio::time::sleep(Duration::from_millis(400)).await;
        cancel_c.store(true, Ordering::Release);
        let _ = tokio::time::timeout(Duration::from_secs(2), handle).await;

        let calls = emitter_inner.calls.lock().unwrap().clone();
        assert!(
            !calls.iter().any(|e| matches!(e, EmittedEvent::Summary { .. })),
            "summary must not be emitted for stale session: {calls:?}"
        );
    }

    // ---------------------------------------------------------------------------
    // Task 21: SummaryEventPayload serialization test
    // ---------------------------------------------------------------------------

    #[test]
    fn summary_event_payloads_serialize_as_discriminated_union() {
        let gen_json = serde_json::to_value(&summary_event_generating(100, 5, "2026-04-24T10:00:00.000+09:00")).unwrap();
        assert_eq!(gen_json["type"], "generating");
        assert_eq!(gen_json["session_id"], 100);
        assert_eq!(gen_json["generation"], 5);
        assert_eq!(gen_json["timestamp"], "2026-04-24T10:00:00.000+09:00");

        let sum_json = serde_json::to_value(&summary_event_summary(100, 5, "2026-04-24T10:00:00.000+09:00", "要約本文")).unwrap();
        assert_eq!(sum_json["type"], "summary");
        assert_eq!(sum_json["text"], "要約本文");

        let err_json = serde_json::to_value(&summary_event_error(100, 5, "2026-04-24T10:00:00.000+09:00", "エラー")).unwrap();
        assert_eq!(err_json["type"], "error");
        assert_eq!(err_json["message"], "エラー");
    }

    // ---------------------------------------------------------------------------
    // Task 20: running_count leak on generation error
    // ---------------------------------------------------------------------------

    #[tokio::test]
    async fn summarizer_loop_releases_slot_on_generation_error() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(ResponseTemplate::new(500))
            .mount(&server)
            .await;

        let segments = Arc::new(Mutex::new(vec![
            Segment { timestamp: "t".into(), source: Source::Mic, text: "a".into() },
        ]));
        let state = Arc::new(SummarizerState::new(1));
        let state_c = state.clone();
        let emitter_inner = Arc::new(MockEmitter::default());
        let emitter: Arc<dyn SummaryEmitter> = emitter_inner.clone();
        let cancel = Arc::new(AtomicBool::new(false));
        let current_session_id = Arc::new(AtomicU64::new(1));
        let cfg = SummarizerConfig::new(reqwest::Client::new(), server.uri(), "x".into());

        let cancel_c = cancel.clone();
        let handle = tokio::spawn(summarizer_loop(
            segments, state, emitter, cancel, current_session_id, cfg,
            Duration::from_millis(50),
        ));

        tokio::time::sleep(Duration::from_millis(500)).await;
        cancel_c.store(true, Ordering::Release);
        let _ = tokio::time::timeout(Duration::from_secs(2), handle).await;

        tokio::time::sleep(Duration::from_millis(100)).await;
        let running = state_c.running_count.load(Ordering::Acquire);
        assert_eq!(running, 0, "running_count should be 0 after all generations errored, got {running}");

        let error_count = emitter_inner.calls.lock().unwrap().iter()
            .filter(|e| matches!(e, EmittedEvent::Error { .. })).count();
        assert!(error_count >= 1, "expected at least 1 error emit");
    }
}
