import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import type { Segment, TranscribeEvent } from "../types";

export type TranscribeDaemon = {
  recording: boolean;
  busy: boolean;
  daemonReady: boolean;
  daemonFatal: boolean;
  segments: Segment[];
  errorMsg: string | null;
  start: () => Promise<void>;
  stop: () => Promise<void>;
};

export function useTranscribeDaemon(): TranscribeDaemon {
  const [recording, setRecording] = useState(false);
  const [busy, setBusy] = useState(false);
  const [daemonReady, setDaemonReady] = useState(false);
  const [daemonFatal, setDaemonFatal] = useState(false);
  const [segments, setSegments] = useState<Segment[]>([]);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);

  useEffect(() => {
    const unlistenPromise = listen<TranscribeEvent>(
      "transcribe://event",
      (e) => {
        const event = e.payload;
        switch (event.type) {
          case "session_started":
            break;
          case "state_changed": {
            switch (event.data.state) {
              case "ready":
                setDaemonReady(true);
                break;
              case "fatal":
                setDaemonFatal(true);
                setDaemonReady(false);
                setRecording(false);
                break;
              case "loading_model":
              case "capturing":
              case "stopping":
                // no daemon-state side effects
                break;
              default: {
                // 新しい state が Swift 側で追加されたときに型エラーで気付けるようにする
                const _exhaustive: never = event.data.state;
                console.warn("[transcribe] unknown state", _exhaustive);
              }
            }
            break;
          }
          case "segment":
            setSegments((prev) => [
              {
                timestamp: event.timestamp,
                source: event.data.source,
                text: event.data.text,
              },
              ...prev,
            ]);
            break;
          case "warning":
            console.warn("[transcribe warning]", event.data.message);
            break;
          case "error":
            setErrorMsg(event.data.message);
            break;
          case "session_stopped":
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

  async function start(): Promise<void> {
    if (busy || !daemonReady || daemonFatal || recording) return;
    setBusy(true);
    setErrorMsg(null);
    setSegments([]);
    try {
      await invoke("start_recording");
      setRecording(true);
    } catch (e) {
      setErrorMsg(String(e));
    } finally {
      setBusy(false);
    }
  }

  async function stop(): Promise<void> {
    if (busy || !recording) return;
    setBusy(true);
    setErrorMsg(null);
    try {
      await invoke("stop_recording");
      setRecording(false);
    } catch (e) {
      setErrorMsg(String(e));
    } finally {
      setBusy(false);
    }
  }

  return {
    recording,
    busy,
    daemonReady,
    daemonFatal,
    segments,
    errorMsg,
    start,
    stop,
  };
}
