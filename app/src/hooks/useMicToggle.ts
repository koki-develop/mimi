import { useCallback, useState } from "react";
import { invoke } from "@tauri-apps/api/core";

export type MicToggle = {
  enabled: boolean;
  toggle: () => Promise<void>;
};

/**
 * mic 入力を Whisper に通すかどうかの toggle。
 * Rust 側 `set_mic_enabled` Tauri command を呼んで daemon の state を更新する。
 * daemon からの応答イベントは無いので、invoke 成功後に楽観的に state 更新する。
 * 初期値は Rust/Swift 側の default と一致させて true。
 */
export function useMicToggle(): MicToggle {
  const [enabled, setEnabled] = useState(true);

  const toggle = useCallback(async () => {
    const next = !enabled;
    try {
      await invoke("set_mic_enabled", { enabled: next });
      setEnabled(next);
    } catch (e) {
      console.error("[mic] set_mic_enabled failed", e);
    }
  }, [enabled]);

  return { enabled, toggle };
}
