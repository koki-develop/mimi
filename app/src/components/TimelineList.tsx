import type { Segment, TimelineEntry } from "../types";
import { TimelineEntryItem } from "./TimelineEntryItem";

type Props = {
  entries: TimelineEntry[];
  segments: Segment[];
  expandedGen: Set<number>;
  onToggle: (gen: number) => void;
  errorMsg: string | null;
  timelineError: string | null;
};

export function TimelineList({
  entries,
  segments,
  expandedGen,
  onToggle,
  errorMsg,
  timelineError,
}: Props) {
  return (
    <section className="mx-auto max-w-3xl px-6 py-8">
      {errorMsg && <p className="mb-4 text-sm text-danger">エラー: {errorMsg}</p>}

      {entries.length > 0 && (
        <ul className="space-y-7">
          {entries.map((entry) => (
            <TimelineEntryItem
              key={entry.generation}
              entry={entry}
              segments={segments}
              expanded={expandedGen.has(entry.generation)}
              onToggle={() => onToggle(entry.generation)}
            />
          ))}
        </ul>
      )}

      {timelineError && (
        <div className="mt-6 text-xs text-danger">
          要約 1 回失敗（次のインターバルで合流）: {timelineError}
        </div>
      )}
    </section>
  );
}
