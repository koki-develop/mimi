use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::Value;
use tauri::{AppHandle, Emitter};
use tokio::io::AsyncReadExt;

use crate::summarizer::{Segment, Source};

pub(crate) const EVENT_TRANSCRIBE: &str = "transcribe://event";

/// Drain every complete `\n`-terminated line from `partial`, trimming trailing
/// `\r` and `\n` bytes. Incomplete bytes (no newline yet) stay in `partial`.
/// Empty lines are skipped so callers don't have to filter.
fn drain_complete_lines(partial: &mut Vec<u8>) -> Vec<Vec<u8>> {
    let mut out = Vec::new();
    while let Some(idx) = partial.iter().position(|&b| b == b'\n') {
        let drained: Vec<u8> = partial.drain(..=idx).collect();
        let trimmed_end = drained
            .iter()
            .rposition(|&b| b != b'\n' && b != b'\r')
            .map(|i| i + 1)
            .unwrap_or(0);
        let line_bytes = &drained[..trimmed_end];
        if line_bytes.is_empty() {
            continue;
        }
        out.push(line_bytes.to_vec());
    }
    out
}

/// Extract a `Segment` from a parsed JSONL value. Returns `None` if the value
/// is not of type `"segment"` or if any required field is missing/invalid.
fn parse_jsonl_segment(value: &Value) -> Option<Segment> {
    if value.get("type").and_then(|t| t.as_str()) != Some("segment") {
        return None;
    }
    let data = value.get("data")?;
    let source = match data.get("source").and_then(|s| s.as_str())? {
        "mic" => Source::Mic,
        "system" => Source::System,
        _ => return None,
    };
    let text = data.get("text").and_then(|t| t.as_str())?.to_string();
    let timestamp = value.get("timestamp").and_then(|t| t.as_str())?.to_string();
    Some(Segment {
        timestamp,
        source,
        text,
    })
}

/// Poll `path.exists()` until it does. Returns `false` if `cancel` flipped
/// before the file appeared, `true` once the file exists.
async fn wait_for_file(path: &Path, cancel: &AtomicBool) -> bool {
    loop {
        if cancel.load(Ordering::Acquire) {
            return false;
        }
        if path.exists() {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

pub(crate) async fn tail_file(
    path: PathBuf,
    app: AppHandle,
    cancel: Arc<AtomicBool>,
    segments: Arc<Mutex<Vec<Segment>>>,
) {
    if !wait_for_file(&path, &cancel).await {
        return;
    }

    let mut file = match tokio::fs::File::open(&path).await {
        Ok(f) => f,
        Err(e) => {
            eprintln!("[tail] open failed: {e}");
            return;
        }
    };

    let mut partial: Vec<u8> = Vec::new();
    let mut buf = vec![0u8; 8192];

    loop {
        let n = match file.read(&mut buf).await {
            Ok(n) => n,
            Err(e) => {
                eprintln!("[tail] read error: {e}");
                return;
            }
        };

        if n == 0 {
            if cancel.load(Ordering::Acquire) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
            continue;
        }

        partial.extend_from_slice(&buf[..n]);
        for line_bytes in drain_complete_lines(&mut partial) {
            match std::str::from_utf8(&line_bytes) {
                Ok(s) => match serde_json::from_str::<Value>(s) {
                    Ok(value) => {
                        let _ = app.emit(EVENT_TRANSCRIBE, value.clone());
                        if let Some(seg) = parse_jsonl_segment(&value) {
                            segments.lock().unwrap().push(seg);
                        }
                    }
                    Err(e) => {
                        eprintln!("[tail] json parse error: {e} line={s}");
                    }
                },
                Err(e) => {
                    eprintln!("[tail] invalid utf-8 line: {e}");
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // ---- drain_complete_lines ----

    #[test]
    fn drain_complete_lines_returns_empty_when_no_newline() {
        let mut buf = b"partial no newline".to_vec();
        let lines = drain_complete_lines(&mut buf);
        assert!(lines.is_empty());
        assert_eq!(buf, b"partial no newline");
    }

    #[test]
    fn drain_complete_lines_drains_single_complete_line() {
        let mut buf = b"first\nleftover".to_vec();
        let lines = drain_complete_lines(&mut buf);
        assert_eq!(lines, vec![b"first".to_vec()]);
        assert_eq!(buf, b"leftover");
    }

    #[test]
    fn drain_complete_lines_drains_multiple_lines() {
        let mut buf = b"a\nb\nc\n".to_vec();
        let lines = drain_complete_lines(&mut buf);
        assert_eq!(lines, vec![b"a".to_vec(), b"b".to_vec(), b"c".to_vec()]);
        assert!(buf.is_empty());
    }

    #[test]
    fn drain_complete_lines_trims_crlf() {
        let mut buf = b"with-cr\r\ntail".to_vec();
        let lines = drain_complete_lines(&mut buf);
        assert_eq!(lines, vec![b"with-cr".to_vec()]);
        assert_eq!(buf, b"tail");
    }

    #[test]
    fn drain_complete_lines_skips_empty_lines() {
        let mut buf = b"a\n\nb\n".to_vec();
        let lines = drain_complete_lines(&mut buf);
        assert_eq!(lines, vec![b"a".to_vec(), b"b".to_vec()]);
        assert!(buf.is_empty());
    }

    #[test]
    fn drain_complete_lines_preserves_multibyte_across_chunks() {
        let full = "日本語\n".as_bytes();
        let (first_half, second_half) = full.split_at(4);

        let mut buf = Vec::from(first_half);
        let lines1 = drain_complete_lines(&mut buf);
        assert!(
            lines1.is_empty(),
            "incomplete multibyte prefix should not yield a line"
        );

        buf.extend_from_slice(second_half);
        let lines2 = drain_complete_lines(&mut buf);
        assert_eq!(lines2.len(), 1);
        assert_eq!(std::str::from_utf8(&lines2[0]).unwrap(), "日本語");
        assert!(buf.is_empty());
    }

    // ---- parse_jsonl_segment ----

    #[test]
    fn parse_jsonl_segment_returns_mic_segment() {
        let v = json!({
            "type": "segment",
            "timestamp": "2026-04-25T10:00:00.000+09:00",
            "data": { "source": "mic", "text": "こんにちは" }
        });
        let seg = parse_jsonl_segment(&v).unwrap();
        assert_eq!(seg.timestamp, "2026-04-25T10:00:00.000+09:00");
        assert_eq!(seg.source, Source::Mic);
        assert_eq!(seg.text, "こんにちは");
    }

    #[test]
    fn parse_jsonl_segment_returns_system_segment() {
        let v = json!({
            "type": "segment",
            "timestamp": "2026-04-25T10:00:00.000+09:00",
            "data": { "source": "system", "text": "hello" }
        });
        let seg = parse_jsonl_segment(&v).unwrap();
        assert_eq!(seg.source, Source::System);
    }

    #[test]
    fn parse_jsonl_segment_rejects_unknown_source() {
        let v = json!({
            "type": "segment",
            "timestamp": "t",
            "data": { "source": "other", "text": "x" }
        });
        assert!(parse_jsonl_segment(&v).is_none());
    }

    #[test]
    fn parse_jsonl_segment_rejects_missing_text() {
        let v = json!({
            "type": "segment",
            "timestamp": "t",
            "data": { "source": "mic" }
        });
        assert!(parse_jsonl_segment(&v).is_none());
    }

    #[test]
    fn parse_jsonl_segment_rejects_missing_timestamp() {
        let v = json!({
            "type": "segment",
            "data": { "source": "mic", "text": "x" }
        });
        assert!(parse_jsonl_segment(&v).is_none());
    }

    #[test]
    fn parse_jsonl_segment_rejects_non_segment_type() {
        let v = json!({
            "type": "partial",
            "timestamp": "t",
            "data": { "source": "mic", "text": "x" }
        });
        assert!(parse_jsonl_segment(&v).is_none());
    }

    #[test]
    fn parse_jsonl_segment_rejects_missing_data_field() {
        let v = json!({
            "type": "segment",
            "timestamp": "t"
        });
        assert!(parse_jsonl_segment(&v).is_none());
    }
}
