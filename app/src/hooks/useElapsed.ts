import { useEffect, useState } from "react";

export function useElapsed(recording: boolean): number {
  const [recordStartedAt, setRecordStartedAt] = useState<number | null>(null);
  const [elapsed, setElapsed] = useState(0);

  useEffect(() => {
    setRecordStartedAt(recording ? Date.now() : null);
  }, [recording]);

  useEffect(() => {
    if (recordStartedAt === null) {
      setElapsed(0);
      return;
    }
    const tick = () =>
      setElapsed(Math.floor((Date.now() - recordStartedAt) / 1000));
    tick();
    const id = setInterval(tick, 1000);
    return () => clearInterval(id);
  }, [recordStartedAt]);

  return elapsed;
}
