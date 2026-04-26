import type { Segment } from "../types";

type Props = {
  segments: Segment[];
};

export function LiveTicker({ segments }: Props) {
  return (
    <div className="mx-auto max-w-3xl px-6 py-3">
      <ul className="space-y-1">
        {segments.slice(0, 3).map((s) => (
          <li
            key={`${s.timestamp}-${s.source}`}
            className="animate-fade-down truncate text-sm text-faint"
          >
            {s.text}
          </li>
        ))}
      </ul>
    </div>
  );
}
