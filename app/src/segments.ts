import type { Segment } from "./types";

export function segmentsInRange(
  all: Segment[],
  start: string,
  end: string,
): Segment[] {
  const s = new Date(start).getTime();
  const e = new Date(end).getTime();
  if (Number.isNaN(s) || Number.isNaN(e)) return [];
  return all.filter((seg) => {
    const t = new Date(seg.timestamp).getTime();
    return t >= s && t <= e;
  });
}
