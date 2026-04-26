import { formatTime } from "../format";
import { segmentsInRange } from "../segments";
import type { Segment, TimelineEntry } from "../types";

type Props = {
  entry: TimelineEntry;
  segments: Segment[];
  expanded: boolean;
  onToggle: () => void;
};

export function TimelineEntryItem({
  entry,
  segments,
  expanded,
  onToggle,
}: Props) {
  const inRange = segmentsInRange(segments, entry.range_start, entry.range_end);
  return (
    <li className="animate-fade-down">
      <div className="font-mono text-xs text-muted">
        {formatTime(entry.range_start)}
      </div>
      <div className="mt-2 text-[15px] leading-relaxed whitespace-pre-wrap">
        {entry.text}
      </div>
      <button
        type="button"
        onClick={onToggle}
        className="mt-3 inline-flex cursor-pointer items-center gap-1 font-mono text-xs text-faint transition-colors duration-150 hover:text-muted"
      >
        <span>{expanded ? "▾" : "▸"}</span>
        <span>元の発話 ({inRange.length})</span>
      </button>
      {expanded && inRange.length > 0 && (
        <ul className="mt-3 space-y-1.5 border-l border-border pl-3">
          {inRange.map((s, i) => (
            <li key={i} className="text-sm leading-relaxed">
              <span className="mr-2 font-mono text-xs text-faint">
                [{s.source}]
              </span>
              <span>{s.text}</span>
            </li>
          ))}
        </ul>
      )}
      {expanded && inRange.length === 0 && (
        <div className="mt-3 text-xs text-faint">
          この区間の生発話は記録されていません。
        </div>
      )}
    </li>
  );
}
