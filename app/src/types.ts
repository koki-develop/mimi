export type Source = "mic" | "system";

export type TranscribeEvent =
  | {
      type: "session_started";
      timestamp: string;
      data: { model: string };
    }
  | {
      type: "state_changed";
      timestamp: string;
      data: {
        state: "loading_model" | "ready" | "capturing" | "stopping" | "fatal";
      };
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
      data: { reason: "stop" | "error" };
    };

export type TimelineEntry = {
  generation: number;
  range_start: string; // ISO8601
  range_end: string;
  text: string;
};

export type TimelineEvent =
  | {
      type: "generating";
      session_id: number;
      generation: number;
      timestamp: string;
    }
  | {
      type: "entry";
      session_id: number;
      generation: number;
      entry: TimelineEntry;
    }
  | {
      type: "error";
      session_id: number;
      generation: number;
      timestamp: string;
      message: string;
    };

export type Segment = {
  timestamp: string;
  source: Source;
  text: string;
};
