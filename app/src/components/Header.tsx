import { Mic, MicOff } from "lucide-react";
import { formatElapsed } from "../format";

type Props = {
  recording: boolean;
  elapsed: number;
  daemonReady: boolean;
  daemonFatal: boolean;
  busy: boolean;
  onToggle: () => void;
  micEnabled: boolean;
  onToggleMic: () => void;
};

export function Header({
  recording,
  elapsed,
  daemonReady,
  daemonFatal,
  busy,
  onToggle,
  micEnabled,
  onToggleMic,
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
        <div className="flex items-center gap-3">
          <button
            type="button"
            onClick={onToggleMic}
            disabled={daemonFatal}
            aria-label={micEnabled ? "マイクをオフにする" : "マイクをオンにする"}
            title={micEnabled ? "マイク オン" : "マイク オフ"}
            className="cursor-pointer rounded-md p-1.5 transition-colors duration-150 hover:bg-text/5 disabled:cursor-not-allowed disabled:opacity-50 disabled:hover:bg-transparent"
          >
            {micEnabled ? (
              <Mic
                key="on"
                size={18}
                strokeWidth={1.5}
                className="animate-mic-toggle text-text"
              />
            ) : (
              <MicOff
                key="off"
                size={18}
                strokeWidth={1.5}
                className="animate-mic-toggle text-muted"
              />
            )}
          </button>
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
      </div>
    </header>
  );
}
