//! Periodic timeline-entry generation loop and per-session state.

use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use super::client::{generate_summary, SummarizerConfig};
use super::events::TimelineEmitter;
use super::prompt::{Segment, TimelineEntry};

const CANCEL_POLL_INTERVAL: Duration = Duration::from_millis(100);

// ---------------------------------------------------------------------------
// TimelineState — session scope + serial-execution gate (in_flight)
// ---------------------------------------------------------------------------

pub(crate) struct TimelineState {
    session_id: u64,
    current_generation: AtomicU64,
    /// 「ここまでの segments は成功裏に要約済み」を示すポインタ。
    /// **成功時のみ進める** (spec §4.1)。失敗時は進めず、次 tick で segments が合流する (carry-over)。
    last_committed_end_index: AtomicUsize,
    in_flight: AtomicBool,
    entries: Mutex<Vec<TimelineEntry>>,
}

impl TimelineState {
    pub(crate) fn new(session_id: u64) -> Self {
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
// wait_for_cancel — polls an AtomicBool until it flips to true
// ---------------------------------------------------------------------------

async fn wait_for_cancel(cancel: &Arc<AtomicBool>) {
    loop {
        if cancel.load(Ordering::Acquire) {
            return;
        }
        tokio::time::sleep(CANCEL_POLL_INTERVAL).await;
    }
}

// ---------------------------------------------------------------------------
// timeline_loop — main periodic timeline-entry generation loop
// ---------------------------------------------------------------------------

pub(crate) struct TimelineLoopParams {
    pub(crate) segments: Arc<Mutex<Vec<Segment>>>,
    pub(crate) state: Arc<TimelineState>,
    pub(crate) emitter: Arc<dyn TimelineEmitter>,
    pub(crate) cancel: Arc<AtomicBool>,
    pub(crate) current_session_id: Arc<AtomicU64>,
    pub(crate) config: SummarizerConfig,
    pub(crate) tick_interval: Duration,
    pub(crate) context_window: usize,
}

pub(crate) async fn timeline_loop(params: TimelineLoopParams) {
    let TimelineLoopParams {
        segments,
        state,
        emitter,
        cancel,
        current_session_id,
        config,
        tick_interval,
        context_window,
    } = params;

    let mut ticker = tokio::time::interval(tick_interval);
    ticker.tick().await; // 初回即時発火を捨てる

    loop {
        tokio::select! {
            _ = ticker.tick() => {}
            () = wait_for_cancel(&cancel) => return,
        }
        if cancel.load(Ordering::Acquire) {
            return;
        }

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
                    let entry = TimelineEntry {
                        generation,
                        range_start,
                        range_end,
                        text,
                    };
                    state_c.entries.lock().unwrap().push(entry.clone());
                    state_c
                        .last_committed_end_index
                        .store(end_index, Ordering::Release);
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
    use super::super::client::SummarizerConfig;
    use super::super::events::test_support::{EmittedTimelineEvent, MockTimelineEmitter};
    use super::super::prompt::{Segment, Source, TimelineEntry};
    use super::*;
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[test]
    fn timeline_state_new_initializes_defaults() {
        let s = TimelineState::new(42);
        assert_eq!(s.session_id, 42);
        assert_eq!(s.current_generation.load(Ordering::Acquire), 0);
        assert_eq!(s.last_committed_end_index.load(Ordering::Acquire), 0);
        assert!(!s.in_flight.load(Ordering::Acquire));
        assert!(s.entries.lock().unwrap().is_empty());
    }

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
        assert!(
            elapsed >= Duration::from_millis(200),
            "should wait at least 200ms"
        );
        assert!(
            elapsed < Duration::from_millis(1000),
            "should return shortly after flag flip, got {elapsed:?}"
        );
    }

    #[tokio::test]
    async fn wait_for_cancel_returns_immediately_if_already_true() {
        let flag = Arc::new(AtomicBool::new(true));
        let start = std::time::Instant::now();
        wait_for_cancel(&flag).await;
        assert!(start.elapsed() < Duration::from_millis(200));
    }

    #[tokio::test]
    async fn timeline_loop_exits_on_cancel() {
        let segments = Arc::new(Mutex::new(Vec::<Segment>::new()));
        let state = Arc::new(TimelineState::new(1));
        let emitter: Arc<dyn TimelineEmitter> = Arc::new(MockTimelineEmitter::default());
        let cancel = Arc::new(AtomicBool::new(false));
        let current_session_id = Arc::new(AtomicU64::new(1));
        let cfg = SummarizerConfig::new(reqwest::Client::new(), "http://unused".into(), "x".into());

        let cancel_c = cancel.clone();
        let handle = tokio::spawn(timeline_loop(TimelineLoopParams {
            segments,
            state,
            emitter,
            cancel,
            current_session_id,
            config: cfg,
            tick_interval: Duration::from_millis(50),
            context_window: 5,
        }));

        tokio::time::sleep(Duration::from_millis(150)).await;
        cancel_c.store(true, Ordering::Release);

        let joined = tokio::time::timeout(Duration::from_secs(2), handle).await;
        assert!(
            joined.is_ok(),
            "timeline_loop should exit within 2s after cancel"
        );
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

        let segments = Arc::new(Mutex::new(vec![Segment {
            timestamp: "2026-04-24T10:00:00.000+09:00".into(),
            source: Source::Mic,
            text: "hi".into(),
        }]));
        let state = Arc::new(TimelineState::new(100));
        let state_c = state.clone();
        let emitter_inner = Arc::new(MockTimelineEmitter::default());
        let emitter: Arc<dyn TimelineEmitter> = emitter_inner.clone();
        let cancel = Arc::new(AtomicBool::new(false));
        let current_session_id = Arc::new(AtomicU64::new(100));
        let cfg = SummarizerConfig::new(reqwest::Client::new(), server.uri(), "qwen3:4b".into());

        let cancel_c = cancel.clone();
        let handle = tokio::spawn(timeline_loop(TimelineLoopParams {
            segments,
            state,
            emitter,
            cancel,
            current_session_id,
            config: cfg,
            tick_interval: Duration::from_millis(50),
            context_window: 5,
        }));

        tokio::time::sleep(Duration::from_millis(400)).await;
        cancel_c.store(true, Ordering::Release);
        let _ = tokio::time::timeout(Duration::from_secs(2), handle).await;

        let calls = emitter_inner.calls.lock().unwrap().clone();
        let entry_count = calls
            .iter()
            .filter(|e| matches!(e, EmittedTimelineEvent::Entry { .. }))
            .count();
        let gen_count = calls
            .iter()
            .filter(|e| matches!(e, EmittedTimelineEvent::Generating { .. }))
            .count();
        assert!(entry_count >= 1, "expected >= 1 entry emit, got: {calls:?}");
        assert_eq!(
            gen_count, entry_count,
            "each entry should be preceded by a generating event"
        );
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
        let handle = tokio::spawn(timeline_loop(TimelineLoopParams {
            segments,
            state,
            emitter,
            cancel,
            current_session_id,
            config: cfg,
            tick_interval: Duration::from_millis(50),
            context_window: 5,
        }));
        tokio::time::sleep(Duration::from_millis(300)).await;
        cancel_c.store(true, Ordering::Release);
        let _ = tokio::time::timeout(Duration::from_secs(2), handle).await;

        let calls = emitter_inner.calls.lock().unwrap().clone();
        assert!(calls.is_empty(), "no segments → no emit, got {calls:?}");
        // empty-segments の tick で in_flight が残留しないこと
        assert!(
            !state_c.in_flight.load(Ordering::Acquire),
            "in_flight must be false after empty ticks"
        );
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
                let delay = if n == 0 {
                    Duration::from_millis(300)
                } else {
                    Duration::from_millis(20)
                };
                ResponseTemplate::new(200)
                    .set_delay(delay)
                    .set_body_json(serde_json::json!({
                        "message": { "role": "assistant", "content": format!("CALL{n}") }
                    }))
            })
            .mount(&server)
            .await;

        let segments = Arc::new(Mutex::new(vec![Segment {
            timestamp: "2026-04-24T10:00:00.000+09:00".into(),
            source: Source::Mic,
            text: "a".into(),
        }]));
        let segments_c = segments.clone();

        let state = Arc::new(TimelineState::new(1));
        let state_c = state.clone();
        let emitter_inner = Arc::new(MockTimelineEmitter::default());
        let emitter: Arc<dyn TimelineEmitter> = emitter_inner.clone();
        let cancel = Arc::new(AtomicBool::new(false));
        let current_session_id = Arc::new(AtomicU64::new(1));
        let cfg = SummarizerConfig::new(reqwest::Client::new(), server.uri(), "x".into());

        let cancel_c = cancel.clone();
        let handle = tokio::spawn(timeline_loop(TimelineLoopParams {
            segments,
            state,
            emitter,
            cancel,
            current_session_id,
            config: cfg,
            tick_interval: Duration::from_millis(80),
            context_window: 5,
        }));

        tokio::time::sleep(Duration::from_millis(180)).await;
        segments_c.lock().unwrap().push(Segment {
            timestamp: "2026-04-24T10:00:30.000+09:00".into(),
            source: Source::Mic,
            text: "b".into(),
        });
        tokio::time::sleep(Duration::from_millis(600)).await;
        cancel_c.store(true, Ordering::Release);
        let _ = tokio::time::timeout(Duration::from_secs(2), handle).await;

        let calls = emitter_inner.calls.lock().unwrap().clone();
        let entries: Vec<_> = calls
            .iter()
            .filter_map(|e| {
                if let EmittedTimelineEvent::Entry { entry, .. } = e {
                    Some(entry.clone())
                } else {
                    None
                }
            })
            .collect();

        assert!(
            entries.len() >= 2,
            "expected at least 2 entries (1st + merged), got: {entries:?}"
        );
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

        let segments = Arc::new(Mutex::new(vec![Segment {
            timestamp: "2026-04-24T10:00:00.000+09:00".into(),
            source: Source::Mic,
            text: "a".into(),
        }]));
        let segments_c = segments.clone();

        let state = Arc::new(TimelineState::new(1));
        let state_c = state.clone();
        let emitter_inner = Arc::new(MockTimelineEmitter::default());
        let emitter: Arc<dyn TimelineEmitter> = emitter_inner.clone();
        let cancel = Arc::new(AtomicBool::new(false));
        let current_session_id = Arc::new(AtomicU64::new(1));
        let cfg = SummarizerConfig::new(reqwest::Client::new(), server.uri(), "x".into());

        let cancel_c = cancel.clone();
        let handle = tokio::spawn(timeline_loop(TimelineLoopParams {
            segments,
            state,
            emitter,
            cancel,
            current_session_id,
            config: cfg,
            tick_interval: Duration::from_millis(80),
            context_window: 5,
        }));

        tokio::time::sleep(Duration::from_millis(120)).await;
        segments_c.lock().unwrap().push(Segment {
            timestamp: "2026-04-24T10:00:30.000+09:00".into(),
            source: Source::Mic,
            text: "b".into(),
        });
        tokio::time::sleep(Duration::from_millis(400)).await;
        cancel_c.store(true, Ordering::Release);
        let _ = tokio::time::timeout(Duration::from_secs(2), handle).await;

        let calls = emitter_inner.calls.lock().unwrap().clone();
        let entries: Vec<_> = calls
            .iter()
            .filter_map(|e| {
                if let EmittedTimelineEvent::Entry { entry, .. } = e {
                    Some(entry.clone())
                } else {
                    None
                }
            })
            .collect();
        let errors: Vec<_> = calls
            .iter()
            .filter_map(|e| {
                if let EmittedTimelineEvent::Error { message, .. } = e {
                    Some(message.clone())
                } else {
                    None
                }
            })
            .collect();

        assert_eq!(
            errors.len(),
            1,
            "expected exactly 1 error (only call 0 returns 500): {calls:?}"
        );
        assert_eq!(
            entries.len(),
            1,
            "expected exactly 1 entry (carry-over merged a+b into one): {entries:?}"
        );
        let first_entry = entries.first().unwrap();
        assert_eq!(
            first_entry.range_start, "2026-04-24T10:00:00.000+09:00",
            "range_start should cover the carried-over segment a: {first_entry:?}"
        );
        assert_eq!(
            first_entry.range_end, "2026-04-24T10:00:30.000+09:00",
            "range_end should cover segment b (proves a and b were merged): {first_entry:?}"
        );
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
            .respond_with(
                ResponseTemplate::new(200)
                    .set_delay(Duration::from_millis(300))
                    .set_body_json(serde_json::json!({
                        "message": { "role": "assistant", "content": "stale" }
                    })),
            )
            .mount(&server)
            .await;

        let segments = Arc::new(Mutex::new(vec![Segment {
            timestamp: "2026-04-24T10:00:00.000+09:00".into(),
            source: Source::Mic,
            text: "a".into(),
        }]));
        let state = Arc::new(TimelineState::new(1));
        let emitter_inner = Arc::new(MockTimelineEmitter::default());
        let emitter: Arc<dyn TimelineEmitter> = emitter_inner.clone();
        let cancel = Arc::new(AtomicBool::new(false));
        let current_session_id = Arc::new(AtomicU64::new(1));
        let cfg = SummarizerConfig::new(reqwest::Client::new(), server.uri(), "x".into());

        let current_session_id_c = current_session_id.clone();
        let cancel_c = cancel.clone();
        let handle = tokio::spawn(timeline_loop(TimelineLoopParams {
            segments,
            state,
            emitter,
            cancel,
            current_session_id,
            config: cfg,
            tick_interval: Duration::from_millis(80),
            context_window: 5,
        }));

        tokio::time::sleep(Duration::from_millis(150)).await;
        current_session_id_c.store(999, Ordering::Release);
        tokio::time::sleep(Duration::from_millis(400)).await;
        cancel_c.store(true, Ordering::Release);
        let _ = tokio::time::timeout(Duration::from_secs(2), handle).await;

        let calls = emitter_inner.calls.lock().unwrap().clone();
        assert!(
            !calls
                .iter()
                .any(|e| matches!(e, EmittedTimelineEvent::Entry { .. })),
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

        let segments = Arc::new(Mutex::new(vec![Segment {
            timestamp: "2026-04-24T10:10:00.000+09:00".into(),
            source: Source::Mic,
            text: "new".into(),
        }]));
        let emitter_inner = Arc::new(MockTimelineEmitter::default());
        let emitter: Arc<dyn TimelineEmitter> = emitter_inner.clone();
        let cancel = Arc::new(AtomicBool::new(false));
        let current_session_id = Arc::new(AtomicU64::new(1));
        let cfg = SummarizerConfig::new(reqwest::Client::new(), server.uri(), "x".into());

        let cancel_c = cancel.clone();
        let handle = tokio::spawn(timeline_loop(TimelineLoopParams {
            segments,
            state,
            emitter,
            cancel,
            current_session_id,
            config: cfg,
            tick_interval: Duration::from_millis(80),
            context_window: 2, // context_window N = 2
        }));

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
