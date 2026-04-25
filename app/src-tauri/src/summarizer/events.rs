//! Event emission: TimelineEmitter trait, Tauri implementation, payload types.

use serde::Serialize;
use tauri::{AppHandle, Emitter};

use super::prompt::TimelineEntry;

pub(crate) const EVENT_TIMELINE: &str = "timeline://event";

// ---------------------------------------------------------------------------
// TimelineEmitter — event emission trait
// ---------------------------------------------------------------------------

pub(crate) trait TimelineEmitter: Send + Sync + 'static {
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
    Generating {
        session_id: u64,
        generation: u64,
        timestamp: &'a str,
    },
    Entry {
        session_id: u64,
        generation: u64,
        entry: &'a TimelineEntry,
    },
    Error {
        session_id: u64,
        generation: u64,
        timestamp: &'a str,
        message: &'a str,
    },
}

fn timeline_event_generating(
    session_id: u64,
    generation: u64,
    ts: &str,
) -> TimelineEventPayload<'_> {
    TimelineEventPayload::Generating {
        session_id,
        generation,
        timestamp: ts,
    }
}
fn timeline_event_entry<'a>(session_id: u64, entry: &'a TimelineEntry) -> TimelineEventPayload<'a> {
    TimelineEventPayload::Entry {
        session_id,
        generation: entry.generation,
        entry,
    }
}
fn timeline_event_error<'a>(
    session_id: u64,
    generation: u64,
    ts: &'a str,
    message: &'a str,
) -> TimelineEventPayload<'a> {
    TimelineEventPayload::Error {
        session_id,
        generation,
        timestamp: ts,
        message,
    }
}

// ---------------------------------------------------------------------------
// TauriTimelineEmitter — emits timeline events to the Tauri frontend
// ---------------------------------------------------------------------------

pub(crate) struct TauriTimelineEmitter {
    pub(crate) app: AppHandle,
}

impl TauriTimelineEmitter {
    fn now_iso() -> String {
        use chrono::{DateTime, Local, Utc};
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default();
        let millis = now.as_millis() as i64;
        DateTime::<Utc>::from_timestamp_millis(millis)
            .map(|dt| {
                dt.with_timezone(&Local)
                    .to_rfc3339_opts(chrono::SecondsFormat::Millis, false)
            })
            .unwrap_or_else(|| "1970-01-01T00:00:00.000+00:00".to_string())
    }
}

impl TimelineEmitter for TauriTimelineEmitter {
    fn emit_generating(&self, session_id: u64, generation: u64) {
        let ts = Self::now_iso();
        if let Err(e) = self.app.emit(
            EVENT_TIMELINE,
            timeline_event_generating(session_id, generation, &ts),
        ) {
            eprintln!("[timeline] emit generating failed (gen={generation}): {e}");
        }
    }
    fn emit_entry(&self, session_id: u64, entry: &TimelineEntry) {
        if let Err(e) = self
            .app
            .emit(EVENT_TIMELINE, timeline_event_entry(session_id, entry))
        {
            eprintln!(
                "[timeline] emit entry failed (gen={}): {e}",
                entry.generation
            );
        }
    }
    fn emit_error(&self, session_id: u64, generation: u64, message: &str) {
        let ts = Self::now_iso();
        if let Err(e) = self.app.emit(
            EVENT_TIMELINE,
            timeline_event_error(session_id, generation, &ts, message),
        ) {
            eprintln!("[timeline] emit error failed (gen={generation}, message={message:?}): {e}");
        }
    }
}

#[cfg(test)]
pub(super) mod test_support {
    use super::*;
    use std::sync::Mutex;

    #[derive(Debug, Clone)]
    pub(crate) enum EmittedTimelineEvent {
        Generating {
            session_id: u64,
            generation: u64,
        },
        Entry {
            session_id: u64,
            entry: TimelineEntry,
        },
        Error {
            session_id: u64,
            generation: u64,
            message: String,
        },
    }

    #[derive(Default)]
    pub(crate) struct MockTimelineEmitter {
        pub(crate) calls: Mutex<Vec<EmittedTimelineEvent>>,
    }

    impl TimelineEmitter for MockTimelineEmitter {
        fn emit_generating(&self, session_id: u64, generation: u64) {
            self.calls
                .lock()
                .unwrap()
                .push(EmittedTimelineEvent::Generating {
                    session_id,
                    generation,
                });
        }
        fn emit_entry(&self, session_id: u64, entry: &TimelineEntry) {
            self.calls
                .lock()
                .unwrap()
                .push(EmittedTimelineEvent::Entry {
                    session_id,
                    entry: entry.clone(),
                });
        }
        fn emit_error(&self, session_id: u64, generation: u64, message: &str) {
            self.calls
                .lock()
                .unwrap()
                .push(EmittedTimelineEvent::Error {
                    session_id,
                    generation,
                    message: message.to_string(),
                });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::{EmittedTimelineEvent, MockTimelineEmitter};
    use super::*;
    use std::sync::Arc;

    #[test]
    fn timeline_event_payloads_serialize_as_discriminated_union() {
        let gen_json = serde_json::to_value(timeline_event_generating(
            100,
            5,
            "2026-04-24T10:00:00.000+09:00",
        ))
        .unwrap();
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
        assert_eq!(
            entry_json["entry"]["range_start"],
            "2026-04-24T10:00:00.000+09:00"
        );

        let err_json = serde_json::to_value(timeline_event_error(
            100,
            5,
            "2026-04-24T10:00:00.000+09:00",
            "爆発",
        ))
        .unwrap();
        assert_eq!(err_json["type"], "error");
        assert_eq!(err_json["message"], "爆発");
    }

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
        assert!(matches!(
            calls[0],
            EmittedTimelineEvent::Generating {
                session_id: 10,
                generation: 1
            }
        ));
        assert!(
            matches!(&calls[1], EmittedTimelineEvent::Entry { session_id: 10, entry } if entry.text == "hello")
        );
        assert!(
            matches!(&calls[2], EmittedTimelineEvent::Error { session_id: 10, generation: 2, message } if message == "err")
        );
    }
}
