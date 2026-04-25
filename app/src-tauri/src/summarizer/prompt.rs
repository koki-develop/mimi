//! Domain types and prompt assembly helpers for timeline summarization.

use serde::Serialize;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Source {
    Mic,
    System,
}

/// A transcription segment emitted by the Swift sidecar.
///
/// The field names happen to correspond to the Swift-side JSONL keys
/// (`timestamp`, `source`, `text`), but `app::tail::parse_jsonl_segment`
/// constructs `Segment` manually rather than serde-deserializing — the JSONL
/// has wrapper fields (`type`, `data`) that don't map cleanly to a flat struct.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Segment {
    pub(crate) timestamp: String, // ISO8601
    pub(crate) source: Source,
    pub(crate) text: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct TimelineEntry {
    pub(crate) generation: u64,
    /// 対象 segments の最初の timestamp (ISO8601)。
    /// carry-over 発生時は前回失敗分の最古 segment の timestamp が入る (spec §4.1)。
    pub(crate) range_start: String,
    /// 対象 segments の最後の timestamp (ISO8601)。
    pub(crate) range_end: String,
    pub(crate) text: String,
}

fn escape_xml(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

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

pub(super) fn build_entry_prompt(
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

#[cfg(test)]
mod tests {
    use super::*;

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
    fn build_entry_prompt_without_previous_entries_omits_tag() {
        let segments = vec![Segment {
            timestamp: "2026-04-24T10:00:00.000+09:00".into(),
            source: Source::Mic,
            text: "よろしく".into(),
        }];
        let (system, user) = build_entry_prompt(&[], &segments);
        assert!(
            system.contains("<transcript>"),
            "system prompt must describe <transcript>"
        );
        assert_eq!(user, "<transcript>\n[自分] よろしく\n</transcript>");
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
        let segments = vec![Segment {
            timestamp: "2026-04-24T10:01:00.000+09:00".into(),
            source: Source::System,
            text: "続き<とか>".into(),
        }];
        let (_, user) = build_entry_prompt(&prev, &segments);

        assert_eq!(
            user,
            "<previous_entries>\n[10:00:00] 最初の話題について軽く触れた。\n[10:00:30] 次の話題に移り議論を深めた。\n</previous_entries>\n\n<transcript>\n[他者] 続き&lt;とか&gt;\n</transcript>"
        );
    }

    #[test]
    fn build_entry_prompt_escapes_previous_entry_text() {
        let prev = vec![TimelineEntry {
            generation: 1,
            range_start: "2026-04-24T10:00:00.000+09:00".into(),
            range_end: "2026-04-24T10:00:30.000+09:00".into(),
            text: "A<B>&C".into(),
        }];
        let (_, user) = build_entry_prompt(&prev, &[]);
        assert!(
            user.contains("A&lt;B&gt;&amp;C"),
            "previous entry text must be xml-escaped, got: {user}"
        );
    }
}
