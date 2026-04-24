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

type Segment = {
  timestamp: string;
  source: Source;
  text: string;
};

function App() {
  const [recording, setRecording] = useState(false);
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState("idle");
  const [segments, setSegments] = useState<Segment[]>([]);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);

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
