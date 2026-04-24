import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import "./App.css";

type Source = "mic" | "system";

type TranscribeEvent =
  | {
      type: "session_started";
      timestamp: string;
      data: { model: string };
    }
  | {
      type: "state_changed";
      timestamp: string;
      data: { state: "loading_model" | "capturing" | "stopping" };
    }
  | {
      type: "segment";
      timestamp: string;
      data: { source: Source; duration: number; text: string };
    }
  | {
      type: "warning";
      timestamp: string;
      data: { message: string };
    }
  | {
      type: "error";
      timestamp: string;
      data: { message: string };
    }
  | {
      type: "session_stopped";
      timestamp: string;
      data: { reason: "sigint" | "error" };
    };

type SummaryEvent =
  | { type: "summary"; session_id: number; generation: number; timestamp: string; text: string }
  | { type: "generating"; session_id: number; generation: number; timestamp: string }
  | { type: "error"; session_id: number; generation: number; timestamp: string; message: string };

type SummaryState = {
  text: string | null;
  generating: boolean;
  error: string | null;
  updatedAt: string | null;  // raw ISO8601; formatted at render time
};

const INITIAL_SUMMARY_STATE: SummaryState = {
  text: null,
  generating: false,
  error: null,
  updatedAt: null,
};

type Segment = {
  timestamp: string;
  source: Source;
  text: string;
};

function formatTime(iso: string): string {
  try {
    const d = new Date(iso);
    const hh = String(d.getHours()).padStart(2, "0");
    const mm = String(d.getMinutes()).padStart(2, "0");
    const ss = String(d.getSeconds()).padStart(2, "0");
    return `${hh}:${mm}:${ss}`;
  } catch {
    return iso;
  }
}

function App() {
  const [recording, setRecording] = useState(false);
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState("idle");
  const [segments, setSegments] = useState<Segment[]>([]);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const [summary, setSummary] = useState<SummaryState>(INITIAL_SUMMARY_STATE);

  useEffect(() => {
    const unlistenPromise = listen<TranscribeEvent>(
      "transcribe://event",
      (e) => {
        const event = e.payload;
        switch (event.type) {
          case "session_started":
            setStatus("session_started");
            break;
          case "state_changed":
            setStatus(event.data.state);
            break;
          case "segment":
            setSegments((prev) => [
              ...prev,
              {
                timestamp: event.timestamp,
                source: event.data.source,
                text: event.data.text,
              },
            ]);
            break;
          case "warning":
            console.warn("[transcribe warning]", event.data.message);
            break;
          case "error":
            setErrorMsg(event.data.message);
            break;
          case "session_stopped":
            setStatus(`stopped (${event.data.reason})`);
            setRecording(false);
            break;
          default: {
            // 新しい event type が Swift 側で追加されたときに型エラーで気付けるようにする
            const _exhaustive: never = event;
            console.warn("[transcribe] unknown event", _exhaustive);
          }
        }
      },
    );
    return () => {
      unlistenPromise.then((fn) => fn());
    };
  }, []);

  useEffect(() => {
    const unlistenPromise = listen<SummaryEvent>("summary://event", (e) => {
      const event = e.payload;
      switch (event.type) {
        case "generating":
          setSummary((prev) => ({ ...prev, generating: true, error: null }));
          break;
        case "summary":
          setSummary({
            text: event.text,
            generating: false,
            error: null,
            updatedAt: event.timestamp,
          });
          break;
        case "error":
          setSummary((prev) => ({
            ...prev,
            generating: false,
            error: event.message,
          }));
          break;
        default: {
          // 新しい event type が Rust 側で追加されたときに型エラーで気付けるようにする
          const _exhaustive: never = event;
          console.warn("[summary] unknown event", _exhaustive);
        }
      }
    });
    return () => {
      unlistenPromise.then((fn) => fn());
    };
  }, []);

  async function toggle() {
    if (busy) return;
    setBusy(true);
    setErrorMsg(null);
    try {
      if (recording) {
        await invoke("stop_recording");
        setRecording(false);
      } else {
        setSegments([]);
        setSummary(INITIAL_SUMMARY_STATE);
        setStatus("starting");
        await invoke("start_recording");
        setRecording(true);
      }
    } catch (e) {
      setErrorMsg(String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="container">
      <h1>mimi</h1>

      <div className="row">
        <button type="button" onClick={toggle} disabled={busy}>
          {recording ? "録音停止" : "録音開始"}
        </button>
        <span style={{ marginLeft: "1em" }}>status: {status}</span>
      </div>

      {errorMsg && (
        <p style={{ color: "crimson" }}>error: {errorMsg}</p>
      )}

      <section
        style={{
          maxWidth: "640px",
          margin: "1em auto",
          padding: "0.75em 1em",
          border: "1px solid rgba(127,127,127,0.3)",
          borderRadius: "6px",
          textAlign: "left",
          background: "rgba(127,127,127,0.05)",
          minHeight: "4em",
        }}
      >
        <div style={{ fontSize: "0.75em", opacity: 0.6, marginBottom: "0.25em" }}>
          要約
          {summary.generating && " (生成中…)"}
        </div>
        {summary.text ? (
          <div style={{ whiteSpace: "pre-wrap", fontSize: "0.95em" }}>
            {summary.text}
          </div>
        ) : (
          <div style={{ opacity: 0.5, fontSize: "0.85em" }}>
            録音を開始すると要約が表示されます
          </div>
        )}
        {summary.updatedAt && (
          <div style={{ fontSize: "0.7em", opacity: 0.5, marginTop: "0.5em" }}>
            最終更新: {formatTime(summary.updatedAt)}
          </div>
        )}
        {summary.error && (
          <div style={{ fontSize: "0.75em", color: "crimson", marginTop: "0.5em" }}>
            要約エラー（次のインターバルで再試行）: {summary.error}
          </div>
        )}
      </section>

      <ul
        style={{
          listStyle: "none",
          padding: 0,
          textAlign: "left",
          maxWidth: "640px",
          margin: "1em auto",
        }}
      >
        {segments.map((s, i) => (
          <li
            key={i}
            style={{
              padding: "0.25em 0.5em",
              borderBottom: "1px solid rgba(127,127,127,0.2)",
            }}
          >
            <span
              style={{
                display: "inline-block",
                minWidth: "4em",
                fontSize: "0.75em",
                opacity: 0.7,
              }}
            >
              [{s.source}]
            </span>
            {s.text}
          </li>
        ))}
      </ul>
    </main>
  );
}

export default App;
