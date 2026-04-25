//! 録音中のタイムライン要約のパイプライン。
//! 設計: docs/superpowers/specs/2026-04-24-timeline-summarizer-design.md
//! リファクタ: docs/superpowers/specs/2026-04-25-rust-refactoring-design.md

mod client;
mod events;
mod prompt;
mod timeline;

// Re-exports of items consumed outside this module (currently `crate::app::*`).
pub(crate) use client::{health_check, SummarizerConfig};
pub(crate) use events::{TauriTimelineEmitter, TimelineEmitter};
pub(crate) use prompt::{Segment, Source};
pub(crate) use timeline::{timeline_loop, TimelineLoopParams, TimelineState};
