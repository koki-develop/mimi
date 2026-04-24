//! 録音中のタイムライン要約のパイプライン。
//! 設計: docs/superpowers/specs/2026-04-24-timeline-summarizer-design.md

use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TimelineEntry {
    pub generation: u64,
    /// 対象 segments の最初の timestamp (ISO8601)。
    /// carry-over 発生時は前回失敗分の最古 segment の timestamp が入る (spec §4.1)。
    pub range_start: String,
    /// 対象 segments の最後の timestamp (ISO8601)。
    pub range_end: String,
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
const CANCEL_POLL_INTERVAL: Duration = Duration::from_millis(100);

const SYSTEM_PROMPT_ENTRY: &str = "会議の音声文字起こしを一定時間ごとに要約するタスクです。タイムライン形式で、各エントリは短時間区間の発話をまとめたものです。

入力:
- <previous_entries> タグ内（省略される場合あり）: 直近の既存エントリ群（古い→新しい順、各行 `[HH:MM:SS] 本文`）
- <transcript> タグ内: 今回の区間の発話の時系列記録

発話の表記:
- `[自分]` : 記録者本人の発話（マイク入力）
- `[他者]` : それ以外の発話（1 人とは限らず、複数人が含まれる可能性があります）

出力要件:
- 今回の <transcript> 区間で起きた内容に焦点を絞って要約する（previous_entries はあくまで文脈参照用）
- 日本語 1 段落、4〜6 文、全体で 200〜400 字程度
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

fn iso_to_hms(iso: &str) -> String {
    use chrono::DateTime;
    DateTime::parse_from_rfc3339(iso)
        .map(|dt| dt.format("%H:%M:%S").to_string())
        .unwrap_or_else(|e| {
            eprintln!("[timeline] iso_to_hms: RFC3339 parse failed for {iso:?}: {e}");
            iso.to_string()
        })
}

fn format_previous_entries(entries: &[TimelineEntry]) -> String {
    entries
        .iter()
        .map(|e| format!("[{}] {}", iso_to_hms(&e.range_start), escape_xml(&e.text)))
        .collect::<Vec<_>>()
        .join("\n")
}

pub fn build_entry_prompt(
    prev_entries: &[TimelineEntry],
    segments: &[Segment],
) -> (&'static str, String) {
    let transcript_body = format_segments(segments);
    let transcript_block = if transcript_body.is_empty() {
        "<transcript>\n</transcript>".to_string()
    } else {
        format!("<transcript>\n{transcript_body}\n</transcript>")
    };
    let user = if prev_entries.is_empty() {
        transcript_block
    } else {
        let prev_body = format_previous_entries(prev_entries);
        format!("<previous_entries>\n{prev_body}\n</previous_entries>\n\n{transcript_block}")
    };
    (SYSTEM_PROMPT_ENTRY, user)
}

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

// ---------------------------------------------------------------------------
// TimelineState — session scope + serial-execution gate (in_flight)
// ---------------------------------------------------------------------------

pub struct TimelineState {
    pub session_id: u64,
    pub current_generation: AtomicU64,
    /// 「ここまでの segments は成功裏に要約済み」を示すポインタ。
    /// **成功時のみ進める** (spec §4.1)。失敗時は進めず、次 tick で segments が合流する (carry-over)。
    pub last_committed_end_index: AtomicUsize,
    pub in_flight: AtomicBool,
    pub entries: Mutex<Vec<TimelineEntry>>,
}

impl TimelineState {
    pub fn new(session_id: u64) -> Self {
        Self {
            session_id,
            current_generation: AtomicU64::new(0),
            last_committed_end_index: AtomicUsize::new(0),
            in_flight: AtomicBool::new(false),
            entries: Mutex::new(Vec::new()),
        }
    }
}

// ---------------------------------------------------------------------------
// InFlightGuard — RAII release for TimelineState::in_flight
// ---------------------------------------------------------------------------
//
// 直列ゲートの release を Drop に委ねることで、spawned task の panic
// (mutex poisoning やアロケーション失敗など) で in_flight が永久 true に
// なって以降の tick が全部スキップされる事故を防ぐ。
// admit (swap(true)) 成功直後に生成し、empty-segments path では scope 終了で、
// spawn 経由では task 終了時にそれぞれ自動解除される。
struct InFlightGuard(Arc<TimelineState>);

impl Drop for InFlightGuard {
    fn drop(&mut self) {
        self.0.in_flight.store(false, Ordering::Release);
    }
}

// ---------------------------------------------------------------------------
// TimelineEmitter — event emission trait
// ---------------------------------------------------------------------------

pub trait TimelineEmitter: Send + Sync + 'static {
    fn emit_generating(&self, session_id: u64, generation: u64);
    fn emit_entry(&self, session_id: u64, entry: &TimelineEntry);
    fn emit_error(&self, session_id: u64, generation: u64, message: &str);
}

// ---------------------------------------------------------------------------
// TimelineEventPayload — discriminated-union event types emitted to the frontend
// ---------------------------------------------------------------------------

#[derive(Serialize, Clone)]
#[serde(tag = "type", rename_all = "lowercase")]
enum TimelineEventPayload<'a> {
    Generating { session_id: u64, generation: u64, timestamp: &'a str },
    Entry { session_id: u64, generation: u64, entry: &'a TimelineEntry },
    Error { session_id: u64, generation: u64, timestamp: &'a str, message: &'a str },
}

fn timeline_event_generating(session_id: u64, generation: u64, ts: &str) -> TimelineEventPayload<'_> {
    TimelineEventPayload::Generating { session_id, generation, timestamp: ts }
}
fn timeline_event_entry<'a>(session_id: u64, entry: &'a TimelineEntry) -> TimelineEventPayload<'a> {
    TimelineEventPayload::Entry { session_id, generation: entry.generation, entry }
}
fn timeline_event_error<'a>(session_id: u64, generation: u64, ts: &'a str, message: &'a str) -> TimelineEventPayload<'a> {
    TimelineEventPayload::Error { session_id, generation, timestamp: ts, message }
}

// ---------------------------------------------------------------------------
// TauriTimelineEmitter — emits timeline events to the Tauri frontend
// ---------------------------------------------------------------------------

pub struct TauriTimelineEmitter {
    pub app: AppHandle,
}

impl TauriTimelineEmitter {
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

impl TimelineEmitter for TauriTimelineEmitter {
    fn emit_generating(&self, session_id: u64, generation: u64) {
        let ts = Self::now_iso();
        if let Err(e) = self
            .app
            .emit("timeline://event", timeline_event_generating(session_id, generation, &ts))
        {
            eprintln!("[timeline] emit generating failed (gen={generation}): {e}");
        }
    }
    fn emit_entry(&self, session_id: u64, entry: &TimelineEntry) {
        if let Err(e) = self
            .app
            .emit("timeline://event", timeline_event_entry(session_id, entry))
        {
            eprintln!("[timeline] emit entry failed (gen={}): {e}", entry.generation);
        }
    }
    fn emit_error(&self, session_id: u64, generation: u64, message: &str) {
        let ts = Self::now_iso();
        if let Err(e) = self
            .app
            .emit("timeline://event", timeline_event_error(session_id, generation, &ts, message))
        {
            eprintln!("[timeline] emit error failed (gen={generation}, message={message:?}): {e}");
        }
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
// timeline_loop — main periodic timeline-entry generation loop
// ---------------------------------------------------------------------------

#[allow(clippy::too_many_arguments)]
pub async fn timeline_loop(
    segments: Arc<Mutex<Vec<Segment>>>,
    state: Arc<TimelineState>,
    emitter: Arc<dyn TimelineEmitter>,
    cancel: Arc<AtomicBool>,
    current_session_id: Arc<AtomicU64>,
    config: SummarizerConfig,
    tick_interval: Duration,
    context_window: usize,
) {
    let mut ticker = tokio::time::interval(tick_interval);
    ticker.tick().await; // 初回即時発火を捨てる

    loop {
        tokio::select! {
            _ = ticker.tick() => {}
            () = wait_for_cancel(&cancel) => return,
        }
        if cancel.load(Ordering::Acquire) { return; }

        // 直列ゲート: 前回生成がまだ走っているならスキップ
        // （segments は累積しているので次 tick で合流）
        if state.in_flight.swap(true, Ordering::AcqRel) {
            continue;
        }
        // この guard が生きている限り in_flight = true。Drop 時に自動 release。
        // empty-segments で continue するパス、spawn に move するパス、spawn 内で panic した場合
        // のいずれでも確実に解除される。
        let guard = InFlightGuard(state.clone());

        // 新規 segment 切り出し
        let end_index = {
            let lock = segments.lock().unwrap();
            lock.len()
        };
        let start_index = state.last_committed_end_index.load(Ordering::Acquire);
        if end_index <= start_index {
            // guard が scope 終了で drop → in_flight release
            continue;
        }
        let new_segments: Vec<Segment> = {
            let lock = segments.lock().unwrap();
            lock[start_index..end_index].to_vec()
        };
        // 直前の空チェックで new_segments が空にならないことが保証されている
        let range_start = new_segments.first().unwrap().timestamp.clone();
        let range_end = new_segments.last().unwrap().timestamp.clone();

        let generation = state.current_generation.fetch_add(1, Ordering::AcqRel) + 1;
        let prev_entries: Vec<TimelineEntry> = {
            let lock = state.entries.lock().unwrap();
            let n = lock.len();
            let take_from = n.saturating_sub(context_window);
            lock[take_from..].to_vec()
        };

        emitter.emit_generating(state.session_id, generation);

        let state_c = state.clone();
        let emitter_c = emitter.clone();
        let cfg_c = config.clone();
        let current_session_id_c = current_session_id.clone();
        tokio::spawn(async move {
            // guard を task に move。task 完了 or panic で Drop → in_flight release。
            let _guard = guard;
            let result = generate_summary(&cfg_c, &new_segments, &prev_entries).await;

            if current_session_id_c.load(Ordering::Acquire) != state_c.session_id {
                return;
            }

            match result {
                Ok(text) => {
                    let entry = TimelineEntry { generation, range_start, range_end, text };
                    state_c.entries.lock().unwrap().push(entry.clone());
                    state_c.last_committed_end_index.store(end_index, Ordering::Release);
                    emitter_c.emit_entry(state_c.session_id, &entry);
                }
                Err(e) => {
                    emitter_c.emit_error(state_c.session_id, generation, &e.to_string());
                }
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::{MockServer, Mock, ResponseTemplate};
    use wiremock::matchers::{method, path};

    // ---------------------------------------------------------------------------
    // MockTimelineEmitter for testing
    // ---------------------------------------------------------------------------

    #[derive(Debug, Clone)]
    pub enum EmittedTimelineEvent {
        Generating { session_id: u64, generation: u64 },
        Entry { session_id: u64, entry: TimelineEntry },
        Error { session_id: u64, generation: u64, message: String },
    }

    #[derive(Default)]
    pub struct MockTimelineEmitter {
        pub calls: Mutex<Vec<EmittedTimelineEvent>>,
    }

    impl TimelineEmitter for MockTimelineEmitter {
        fn emit_generating(&self, session_id: u64, generation: u64) {
            self.calls.lock().unwrap().push(EmittedTimelineEvent::Generating { session_id, generation });
        }
        fn emit_entry(&self, session_id: u64, entry: &TimelineEntry) {
            self.calls.lock().unwrap().push(EmittedTimelineEvent::Entry { session_id, entry: entry.clone() });
        }
        fn emit_error(&self, session_id: u64, generation: u64, message: &str) {
            self.calls.lock().unwrap().push(EmittedTimelineEvent::Error { session_id, generation, message: message.to_string() });
        }
    }

    // ---------------------------------------------------------------------------
    // SummaryError
    // ---------------------------------------------------------------------------

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

    // ---------------------------------------------------------------------------
    // escape_xml
    // ---------------------------------------------------------------------------

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

    // ---------------------------------------------------------------------------
    // build_entry_prompt
    // ---------------------------------------------------------------------------

    #[test]
    fn build_entry_prompt_without_previous_entries_omits_tag() {
        let segments = vec![
            Segment { timestamp: "2026-04-24T10:00:00.000+09:00".into(), source: Source::Mic, text: "よろしく".into() },
        ];
        let (system, user) = build_entry_prompt(&[], &segments);
        assert!(system.contains("<transcript>"), "system prompt must describe <transcript>");
        assert_eq!(
            user,
            "<transcript>\n[自分] よろしく\n</transcript>"
        );
    }

    #[test]
    fn build_entry_prompt_with_previous_entries_includes_them_in_order() {
        let prev = vec![
            TimelineEntry {
                generation: 1,
                range_start: "2026-04-24T10:00:00.000+09:00".into(),
                range_end: "2026-04-24T10:00:30.000+09:00".into(),
                text: "最初の話題について軽く触れた。".into(),
            },
            TimelineEntry {
                generation: 2,
                range_start: "2026-04-24T10:00:30.000+09:00".into(),
                range_end: "2026-04-24T10:01:00.000+09:00".into(),
                text: "次の話題に移り議論を深めた。".into(),
            },
        ];
        let segments = vec![
            Segment { timestamp: "2026-04-24T10:01:00.000+09:00".into(), source: Source::System, text: "続き<とか>".into() },
        ];
        let (_, user) = build_entry_prompt(&prev, &segments);

        assert_eq!(
            user,
            "<previous_entries>\n[10:00:00] 最初の話題について軽く触れた。\n[10:00:30] 次の話題に移り議論を深めた。\n</previous_entries>\n\n<transcript>\n[他者] 続き&lt;とか&gt;\n</transcript>"
        );
    }

    #[test]
    fn build_entry_prompt_escapes_previous_entry_text() {
        let prev = vec![
            TimelineEntry {
                generation: 1,
                range_start: "2026-04-24T10:00:00.000+09:00".into(),
                range_end: "2026-04-24T10:00:30.000+09:00".into(),
                text: "A<B>&C".into(),
            },
        ];
        let (_, user) = build_entry_prompt(&prev, &[]);
        assert!(user.contains("A&lt;B&gt;&amp;C"), "previous entry text must be xml-escaped, got: {user}");
    }

    // ---------------------------------------------------------------------------
    // generate_summary
    // ---------------------------------------------------------------------------

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
        let segments = vec![Segment { timestamp: "2026-04-24T10:00:00.000+09:00".into(), source: Source::Mic, text: "はい".into() }];
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
        let segments = vec![Segment { timestamp: "2026-04-24T10:00:30.000+09:00".into(), source: Source::Mic, text: "こんかい".into() }];
        let _ = generate_summary(&cfg, &segments, &prev).await.unwrap();

        let received = server.received_requests().await.unwrap();
        assert_eq!(received.len(), 1);
        let body: serde_json::Value = serde_json::from_slice(&received[0].body).unwrap();
        let user_msg = body["messages"][1]["content"].as_str().unwrap();
        assert!(user_msg.contains("<previous_entries>"), "user msg: {user_msg}");
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
        let cfg = SummarizerConfig::new(reqwest::Client::new(), "http://127.0.0.1:1".into(), "x".into());
        let err = generate_summary(&cfg, &[], &[]).await.unwrap_err();
        assert!(
            matches!(err, SummaryError::Transport(_) | SummaryError::Timeout(_)),
            "got {err:?}"
        );
    }

    // ---------------------------------------------------------------------------
    // health_check
    // ---------------------------------------------------------------------------

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
        let cfg = SummarizerConfig::new(reqwest::Client::new(), "http://127.0.0.1:1".into(), "x".into());
        let err = health_check(&cfg).await.unwrap_err();
        assert!(err.contains("接続できない"));
    }

    // ---------------------------------------------------------------------------
    // TimelineState
    // ---------------------------------------------------------------------------

    #[test]
    fn timeline_state_new_initializes_defaults() {
        let s = TimelineState::new(42);
        assert_eq!(s.session_id, 42);
        assert_eq!(s.current_generation.load(Ordering::Acquire), 0);
        assert_eq!(s.last_committed_end_index.load(Ordering::Acquire), 0);
        assert!(!s.in_flight.load(Ordering::Acquire));
        assert!(s.entries.lock().unwrap().is_empty());
    }

    // ---------------------------------------------------------------------------
    // TimelineEventPayload serialization
    // ---------------------------------------------------------------------------

    #[test]
    fn timeline_event_payloads_serialize_as_discriminated_union() {
        let gen_json = serde_json::to_value(timeline_event_generating(100, 5, "2026-04-24T10:00:00.000+09:00")).unwrap();
        assert_eq!(gen_json["type"], "generating");
        assert_eq!(gen_json["session_id"], 100);
        assert_eq!(gen_json["generation"], 5);
        assert_eq!(gen_json["timestamp"], "2026-04-24T10:00:00.000+09:00");

        let entry = TimelineEntry {
            generation: 5,
            range_start: "2026-04-24T10:00:00.000+09:00".into(),
            range_end: "2026-04-24T10:00:30.000+09:00".into(),
            text: "本文".into(),
        };
        let entry_json = serde_json::to_value(timeline_event_entry(100, &entry)).unwrap();
        assert_eq!(entry_json["type"], "entry");
        assert_eq!(entry_json["session_id"], 100);
        assert_eq!(entry_json["generation"], 5);
        assert_eq!(entry_json["entry"]["text"], "本文");
        assert_eq!(entry_json["entry"]["range_start"], "2026-04-24T10:00:00.000+09:00");

        let err_json = serde_json::to_value(timeline_event_error(100, 5, "2026-04-24T10:00:00.000+09:00", "爆発")).unwrap();
        assert_eq!(err_json["type"], "error");
        assert_eq!(err_json["message"], "爆発");
    }

    // ---------------------------------------------------------------------------
    // MockTimelineEmitter
    // ---------------------------------------------------------------------------

    #[test]
    fn mock_timeline_emitter_records_calls_in_order() {
        let m = Arc::new(MockTimelineEmitter::default());
        m.emit_generating(10, 1);
        let e = TimelineEntry {
            generation: 1,
            range_start: "t0".into(),
            range_end: "t1".into(),
            text: "hello".into(),
        };
        m.emit_entry(10, &e);
        m.emit_error(10, 2, "err");

        let calls = m.calls.lock().unwrap().clone();
        assert_eq!(calls.len(), 3);
        assert!(matches!(calls[0], EmittedTimelineEvent::Generating { session_id: 10, generation: 1 }));
        assert!(matches!(&calls[1], EmittedTimelineEvent::Entry { session_id: 10, entry } if entry.text == "hello"));
        assert!(matches!(&calls[2], EmittedTimelineEvent::Error { session_id: 10, generation: 2, message } if message == "err"));
    }

    // ---------------------------------------------------------------------------
    // wait_for_cancel
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
    // timeline_loop
    // ---------------------------------------------------------------------------

    #[tokio::test]
    async fn timeline_loop_exits_on_cancel() {
        let segments = Arc::new(Mutex::new(Vec::<Segment>::new()));
        let state = Arc::new(TimelineState::new(1));
        let emitter: Arc<dyn TimelineEmitter> = Arc::new(MockTimelineEmitter::default());
        let cancel = Arc::new(AtomicBool::new(false));
        let current_session_id = Arc::new(AtomicU64::new(1));
        let cfg = SummarizerConfig::new(reqwest::Client::new(), "http://unused".into(), "x".into());

        let cancel_c = cancel.clone();
        let handle = tokio::spawn(timeline_loop(
            segments, state, emitter, cancel, current_session_id, cfg,
            Duration::from_millis(50), 5,
        ));

        tokio::time::sleep(Duration::from_millis(150)).await;
        cancel_c.store(true, Ordering::Release);

        let joined = tokio::time::timeout(Duration::from_secs(2), handle).await;
        assert!(joined.is_ok(), "timeline_loop should exit within 2s after cancel");
    }

    #[tokio::test]
    async fn timeline_loop_emits_entries_for_new_segments() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "message": { "role": "assistant", "content": "まとめ" }
            })))
            .mount(&server)
            .await;

        let segments = Arc::new(Mutex::new(vec![
            Segment { timestamp: "2026-04-24T10:00:00.000+09:00".into(), source: Source::Mic, text: "hi".into() },
        ]));
        let state = Arc::new(TimelineState::new(100));
        let state_c = state.clone();
        let emitter_inner = Arc::new(MockTimelineEmitter::default());
        let emitter: Arc<dyn TimelineEmitter> = emitter_inner.clone();
        let cancel = Arc::new(AtomicBool::new(false));
        let current_session_id = Arc::new(AtomicU64::new(100));
        let cfg = SummarizerConfig::new(reqwest::Client::new(), server.uri(), "qwen3:4b".into());

        let cancel_c = cancel.clone();
        let handle = tokio::spawn(timeline_loop(
            segments, state, emitter, cancel, current_session_id, cfg,
            Duration::from_millis(50), 5,
        ));

        tokio::time::sleep(Duration::from_millis(400)).await;
        cancel_c.store(true, Ordering::Release);
        let _ = tokio::time::timeout(Duration::from_secs(2), handle).await;

        let calls = emitter_inner.calls.lock().unwrap().clone();
        let entry_count = calls.iter().filter(|e| matches!(e, EmittedTimelineEvent::Entry { .. })).count();
        let gen_count = calls.iter().filter(|e| matches!(e, EmittedTimelineEvent::Generating { .. })).count();
        assert!(entry_count >= 1, "expected >= 1 entry emit, got: {calls:?}");
        assert_eq!(gen_count, entry_count, "each entry should be preceded by a generating event");
        assert_eq!(state_c.entries.lock().unwrap().len(), entry_count);
        // 成功した tick のぶんだけ pointer が進んでいる (segments.len() == 1 なので上限は 1)
        assert_eq!(
            state_c.last_committed_end_index.load(Ordering::Acquire),
            1,
            "last_committed_end_index should advance to segments.len() on success"
        );
    }

    #[tokio::test]
    async fn timeline_loop_skips_when_no_new_segments() {
        let server = MockServer::start().await;
        let segments = Arc::new(Mutex::new(Vec::<Segment>::new()));
        let state = Arc::new(TimelineState::new(1));
        let state_c = state.clone();
        let emitter_inner = Arc::new(MockTimelineEmitter::default());
        let emitter: Arc<dyn TimelineEmitter> = emitter_inner.clone();
        let cancel = Arc::new(AtomicBool::new(false));
        let current_session_id = Arc::new(AtomicU64::new(1));
        let cfg = SummarizerConfig::new(reqwest::Client::new(), server.uri(), "x".into());

        let cancel_c = cancel.clone();
        let handle = tokio::spawn(timeline_loop(
            segments, state, emitter, cancel, current_session_id, cfg,
            Duration::from_millis(50), 5,
        ));
        tokio::time::sleep(Duration::from_millis(300)).await;
        cancel_c.store(true, Ordering::Release);
        let _ = tokio::time::timeout(Duration::from_secs(2), handle).await;

        let calls = emitter_inner.calls.lock().unwrap().clone();
        assert!(calls.is_empty(), "no segments → no emit, got {calls:?}");
        // empty-segments の tick で in_flight が残留しないこと
        assert!(!state_c.in_flight.load(Ordering::Acquire), "in_flight must be false after empty ticks");
    }

    #[tokio::test]
    async fn timeline_loop_serializes_overlapping_ticks_and_merges_segments() {
        let server = MockServer::start().await;
        let call_count = Arc::new(AtomicUsize::new(0));
        let cc = call_count.clone();

        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(move |_: &wiremock::Request| {
                let n = cc.fetch_add(1, Ordering::AcqRel);
                let delay = if n == 0 { Duration::from_millis(300) } else { Duration::from_millis(20) };
                ResponseTemplate::new(200)
                    .set_delay(delay)
                    .set_body_json(serde_json::json!({
                        "message": { "role": "assistant", "content": format!("CALL{n}") }
                    }))
            })
            .mount(&server)
            .await;

        let segments = Arc::new(Mutex::new(vec![
            Segment { timestamp: "2026-04-24T10:00:00.000+09:00".into(), source: Source::Mic, text: "a".into() },
        ]));
        let segments_c = segments.clone();

        let state = Arc::new(TimelineState::new(1));
        let state_c = state.clone();
        let emitter_inner = Arc::new(MockTimelineEmitter::default());
        let emitter: Arc<dyn TimelineEmitter> = emitter_inner.clone();
        let cancel = Arc::new(AtomicBool::new(false));
        let current_session_id = Arc::new(AtomicU64::new(1));
        let cfg = SummarizerConfig::new(reqwest::Client::new(), server.uri(), "x".into());

        let cancel_c = cancel.clone();
        let handle = tokio::spawn(timeline_loop(
            segments, state, emitter, cancel, current_session_id, cfg,
            Duration::from_millis(80), 5,
        ));

        tokio::time::sleep(Duration::from_millis(180)).await;
        segments_c.lock().unwrap().push(
            Segment { timestamp: "2026-04-24T10:00:30.000+09:00".into(), source: Source::Mic, text: "b".into() }
        );
        tokio::time::sleep(Duration::from_millis(600)).await;
        cancel_c.store(true, Ordering::Release);
        let _ = tokio::time::timeout(Duration::from_secs(2), handle).await;

        let calls = emitter_inner.calls.lock().unwrap().clone();
        let entries: Vec<_> = calls.iter().filter_map(|e| {
            if let EmittedTimelineEvent::Entry { entry, .. } = e { Some(entry.clone()) } else { None }
        }).collect();

        assert!(entries.len() >= 2, "expected at least 2 entries (1st + merged), got: {entries:?}");
        assert!(
            entries.iter().any(|e| e.range_end.contains("10:00:30")),
            "segment b should appear in a later entry range: {entries:?}"
        );
        assert_eq!(state_c.entries.lock().unwrap().len(), entries.len());
    }

    #[tokio::test]
    async fn timeline_loop_carries_segments_over_on_error() {
        let server = MockServer::start().await;
        let call_count = Arc::new(AtomicUsize::new(0));
        let cc = call_count.clone();

        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(move |_: &wiremock::Request| {
                let n = cc.fetch_add(1, Ordering::AcqRel);
                if n == 0 {
                    ResponseTemplate::new(500)
                } else {
                    ResponseTemplate::new(200).set_body_json(serde_json::json!({
                        "message": { "role": "assistant", "content": "OK" }
                    }))
                }
            })
            .mount(&server)
            .await;

        let segments = Arc::new(Mutex::new(vec![
            Segment { timestamp: "2026-04-24T10:00:00.000+09:00".into(), source: Source::Mic, text: "a".into() },
        ]));
        let segments_c = segments.clone();

        let state = Arc::new(TimelineState::new(1));
        let state_c = state.clone();
        let emitter_inner = Arc::new(MockTimelineEmitter::default());
        let emitter: Arc<dyn TimelineEmitter> = emitter_inner.clone();
        let cancel = Arc::new(AtomicBool::new(false));
        let current_session_id = Arc::new(AtomicU64::new(1));
        let cfg = SummarizerConfig::new(reqwest::Client::new(), server.uri(), "x".into());

        let cancel_c = cancel.clone();
        let handle = tokio::spawn(timeline_loop(
            segments, state, emitter, cancel, current_session_id, cfg,
            Duration::from_millis(80), 5,
        ));

        tokio::time::sleep(Duration::from_millis(120)).await;
        segments_c.lock().unwrap().push(
            Segment { timestamp: "2026-04-24T10:00:30.000+09:00".into(), source: Source::Mic, text: "b".into() }
        );
        tokio::time::sleep(Duration::from_millis(400)).await;
        cancel_c.store(true, Ordering::Release);
        let _ = tokio::time::timeout(Duration::from_secs(2), handle).await;

        let calls = emitter_inner.calls.lock().unwrap().clone();
        let entries: Vec<_> = calls.iter().filter_map(|e| {
            if let EmittedTimelineEvent::Entry { entry, .. } = e { Some(entry.clone()) } else { None }
        }).collect();
        let errors: Vec<_> = calls.iter().filter_map(|e| {
            if let EmittedTimelineEvent::Error { message, .. } = e { Some(message.clone()) } else { None }
        }).collect();

        assert_eq!(errors.len(), 1, "expected exactly 1 error (only call 0 returns 500): {calls:?}");
        assert_eq!(entries.len(), 1, "expected exactly 1 entry (carry-over merged a+b into one): {entries:?}");
        let first_entry = entries.first().unwrap();
        assert_eq!(first_entry.range_start, "2026-04-24T10:00:00.000+09:00",
            "range_start should cover the carried-over segment a: {first_entry:?}");
        assert_eq!(first_entry.range_end, "2026-04-24T10:00:30.000+09:00",
            "range_end should cover segment b (proves a and b were merged): {first_entry:?}");
        assert_eq!(state_c.entries.lock().unwrap().len(), 1);
        // pointer は成功後の segments.len() (= 2) まで進む
        assert_eq!(
            state_c.last_committed_end_index.load(Ordering::Acquire),
            2,
            "pointer advances only after the successful carry-over tick"
        );
    }

    #[tokio::test]
    async fn timeline_loop_does_not_emit_when_session_id_changed() {
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
            Segment { timestamp: "2026-04-24T10:00:00.000+09:00".into(), source: Source::Mic, text: "a".into() },
        ]));
        let state = Arc::new(TimelineState::new(1));
        let emitter_inner = Arc::new(MockTimelineEmitter::default());
        let emitter: Arc<dyn TimelineEmitter> = emitter_inner.clone();
        let cancel = Arc::new(AtomicBool::new(false));
        let current_session_id = Arc::new(AtomicU64::new(1));
        let cfg = SummarizerConfig::new(reqwest::Client::new(), server.uri(), "x".into());

        let current_session_id_c = current_session_id.clone();
        let cancel_c = cancel.clone();
        let handle = tokio::spawn(timeline_loop(
            segments, state, emitter, cancel, current_session_id, cfg,
            Duration::from_millis(80), 5,
        ));

        tokio::time::sleep(Duration::from_millis(150)).await;
        current_session_id_c.store(999, Ordering::Release);
        tokio::time::sleep(Duration::from_millis(400)).await;
        cancel_c.store(true, Ordering::Release);
        let _ = tokio::time::timeout(Duration::from_secs(2), handle).await;

        let calls = emitter_inner.calls.lock().unwrap().clone();
        assert!(
            !calls.iter().any(|e| matches!(e, EmittedTimelineEvent::Entry { .. })),
            "entry must not be emitted for stale session: {calls:?}"
        );
    }

    #[tokio::test]
    async fn timeline_loop_passes_only_last_n_entries_as_context() {
        use std::sync::Mutex as StdMutex;
        let server = MockServer::start().await;
        let bodies = Arc::new(StdMutex::new(Vec::<String>::new()));
        let bodies_c = bodies.clone();
        let counter = Arc::new(AtomicUsize::new(0));
        let counter_c = counter.clone();

        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(move |req: &wiremock::Request| {
                let body_str = String::from_utf8_lossy(&req.body).to_string();
                bodies_c.lock().unwrap().push(body_str);
                let n = counter_c.fetch_add(1, Ordering::AcqRel);
                ResponseTemplate::new(200).set_body_json(serde_json::json!({
                    "message": { "role": "assistant", "content": format!("E{n}") }
                }))
            })
            .mount(&server)
            .await;

        // 事前に 3 つのダミー entry を state に入れておく。
        // generation は 100 以降にして、tick 由来の generation (1 始まり) と衝突しないようにする。
        let state = Arc::new(TimelineState::new(1));
        {
            let mut lock = state.entries.lock().unwrap();
            for i in 0..3 {
                lock.push(TimelineEntry {
                    generation: 100 + i,
                    range_start: format!("2026-04-24T10:0{i}:00.000+09:00"),
                    range_end: format!("2026-04-24T10:0{i}:30.000+09:00"),
                    text: format!("OLD{i}"),
                });
            }
        }

        let segments = Arc::new(Mutex::new(vec![
            Segment { timestamp: "2026-04-24T10:10:00.000+09:00".into(), source: Source::Mic, text: "new".into() },
        ]));
        let emitter_inner = Arc::new(MockTimelineEmitter::default());
        let emitter: Arc<dyn TimelineEmitter> = emitter_inner.clone();
        let cancel = Arc::new(AtomicBool::new(false));
        let current_session_id = Arc::new(AtomicU64::new(1));
        let cfg = SummarizerConfig::new(reqwest::Client::new(), server.uri(), "x".into());

        let cancel_c = cancel.clone();
        let handle = tokio::spawn(timeline_loop(
            segments, state, emitter, cancel, current_session_id, cfg,
            Duration::from_millis(80),
            2, // context_window N = 2
        ));

        tokio::time::sleep(Duration::from_millis(200)).await;
        cancel_c.store(true, Ordering::Release);
        let _ = tokio::time::timeout(Duration::from_secs(2), handle).await;

        let captured = bodies.lock().unwrap().clone();
        assert!(!captured.is_empty(), "expected at least 1 request");
        let first = &captured[0];
        // N=2 なので OLD1, OLD2 だけが含まれ、OLD0 は含まれない
        assert!(first.contains("OLD1"), "should include OLD1: {first}");
        assert!(first.contains("OLD2"), "should include OLD2: {first}");
        assert!(!first.contains("OLD0"), "should NOT include OLD0: {first}");
    }
}
