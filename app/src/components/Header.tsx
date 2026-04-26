import { formatElapsed } from "../format";

type Props = {
  recording: boolean;
  elapsed: number;
  daemonReady: boolean;
  daemonFatal: boolean;
  busy: boolean;
  onToggle: () => void;
};

export function Header({
  recording,
  elapsed,
  daemonReady,
  daemonFatal,
  busy,
  onToggle,
}: Props) {
  const buttonLabel = daemonFatal
    ? "デーモン停止 (アプリを再起動)"
    : !daemonReady
      ? "デーモン起動中…"
      : recording
        ? "録音停止"
        : "録音開始";

  return (
    <header className="border-b border-border">
      <div className="mx-auto flex h-14 max-w-3xl items-center justify-between px-6">
        <span className="font-mono text-sm text-muted tabular-nums">
          {recording ? formatElapsed(elapsed) : ""}
        </span>
        <button
          type="button"
          onClick={onToggle}
          disabled={busy || !daemonReady || daemonFatal}
          className="flex cursor-pointer items-center gap-2 rounded-md border border-text/15 bg-text/5 px-3 py-1.5 text-sm transition-colors duration-150 hover:border-text/30 hover:bg-text/10 disabled:cursor-not-allowed disabled:opacity-50"
        >
          {recording && (
            <span className="block size-1.5 rounded-full bg-accent animate-pulse-soft" />
          )}
          <span>{buttonLabel}</span>
        </button>
      </div>
    </header>
  );
}
