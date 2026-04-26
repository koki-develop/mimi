import "./App.css";
import { Header } from "./components/Header";
import { LiveTicker } from "./components/LiveTicker";
import { TimelineList } from "./components/TimelineList";
import { useElapsed } from "./hooks/useElapsed";
import { useMicToggle } from "./hooks/useMicToggle";
import { useTimeline } from "./hooks/useTimeline";
import { useTranscribeDaemon } from "./hooks/useTranscribeDaemon";

function App() {
  const daemon = useTranscribeDaemon();
  const timeline = useTimeline();
  const mic = useMicToggle();
  const elapsed = useElapsed(daemon.recording);

  async function toggle() {
    if (daemon.busy || !daemon.daemonReady || daemon.daemonFatal) return;
    if (daemon.recording) {
      await daemon.stop();
      // Rust 側 session_id guard で entry/error emit が抑制されるので、
      // 生成中に停止すると失敗表示が残留する。明示的にクリア。
      timeline.clearError();
    } else {
      timeline.reset();
      await daemon.start();
    }
  }

  return (
    <main className="min-h-screen">
      <Header
        recording={daemon.recording}
        elapsed={elapsed}
        daemonReady={daemon.daemonReady}
        daemonFatal={daemon.daemonFatal}
        busy={daemon.busy}
        onToggle={toggle}
        micEnabled={mic.enabled}
        onToggleMic={mic.toggle}
      />
      {daemon.recording && <LiveTicker segments={daemon.segments} />}
      <TimelineList
        entries={timeline.entries}
        segments={daemon.segments}
        expandedGen={timeline.expandedGen}
        onToggle={timeline.toggleExpanded}
        errorMsg={daemon.errorMsg}
        timelineError={timeline.timelineError}
      />
    </main>
  );
}

export default App;
