import { useEffect, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import type { TimelineEntry, TimelineEvent } from "../types";

export type Timeline = {
  entries: TimelineEntry[];
  timelineError: string | null;
  expandedGen: Set<number>;
  toggleExpanded: (gen: number) => void;
  reset: () => void;
  clearError: () => void;
};

export function useTimeline(): Timeline {
  const [entries, setEntries] = useState<TimelineEntry[]>([]);
  const [timelineError, setTimelineError] = useState<string | null>(null);
  const [expandedGen, setExpandedGen] = useState<Set<number>>(new Set());

  useEffect(() => {
    const unlistenPromise = listen<TimelineEvent>("timeline://event", (e) => {
      const event = e.payload;
      switch (event.type) {
        case "generating":
          // UI には生成中表示を出さない（裏で進行）。
          // 直前の失敗表示は次の生成サイクルに入った時点でクリア。
          setTimelineError(null);
          break;
        case "entry":
          setEntries((prev) => [event.entry, ...prev]);
          break;
        case "error":
          setTimelineError(event.message);
          break;
        default: {
          // 新しい event type が Rust 側で追加されたときに型エラーで気付けるようにする
          const _exhaustive: never = event;
          console.warn("[timeline] unknown event", _exhaustive);
        }
      }
    });
    return () => {
      unlistenPromise.then((fn) => fn());
    };
  }, []);

  function toggleExpanded(gen: number) {
    setExpandedGen((prev) => {
      const next = new Set(prev);
      if (next.has(gen)) next.delete(gen);
      else next.add(gen);
      return next;
    });
  }

  function reset() {
    setEntries([]);
    setExpandedGen(new Set());
    setTimelineError(null);
  }

  function clearError() {
    setTimelineError(null);
  }

  return {
    entries,
    timelineError,
    expandedGen,
    toggleExpanded,
    reset,
    clearError,
  };
}
