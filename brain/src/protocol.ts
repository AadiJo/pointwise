// Messages exchanged between the Swift app and the brain sidecar.
// Transport: one JSON object per line on stdin (app → brain) and stdout (brain → app).

export interface ScreenImage {
  /** Base64-encoded JPEG of one display. */
  jpegBase64: string;
  /** Human-readable label, for example "screen 1 of 2 (cursor is here)". */
  label: string;
  widthInPixels: number;
  heightInPixels: number;
}

export interface AskRequest {
  type: "ask";
  turnId: string;
  /** What the learner said or typed. */
  text: string;
  screens: ScreenImage[];
  /** Extra situational context gathered by the app (front app, cursor, drawn path, page URL). */
  context?: string;
  /** "voice" when spoken, "typed" when typed into the text box. */
  inputMode?: "voice" | "typed";
}

export interface ConfigureRequest {
  type: "configure";
  model?: string;
  effort?: "low" | "medium" | "high" | "xhigh" | "max";
  /** "disabled" answers fastest; "adaptive" lets Claude think first on hard questions. */
  thinking?: "adaptive" | "disabled";
  /** Markdown profile of the learner (name, grade, interests, needs). */
  learnerProfile?: string;
  /** Markdown list of facts Pointwise remembered in earlier sessions. */
  memory?: string;
  /** BCP-47 language code Pointwise should speak, for example "en-US" or "es-MX". */
  language?: string;
  /** True when the learner allowed Pointwise to click and type for them. */
  actionsEnabled?: boolean;
  claudeExecutablePath?: string;
}

export interface ToolResultMessage {
  type: "tool_result";
  callId: string;
  /** Text returned to the model. */
  text: string;
  /** Optional fresh screenshots returned to the model with the text. */
  screens?: ScreenImage[];
  isError?: boolean;
}

export interface CancelRequest {
  type: "cancel";
}

export interface ResetRequest {
  type: "reset";
}

export interface SummarizeRequest {
  type: "summarize";
  requestId: string;
  /** The conversation transcript to turn into study notes. */
  transcript: string;
}

export type AppToBrainMessage =
  | AskRequest
  | ConfigureRequest
  | ToolResultMessage
  | CancelRequest
  | ResetRequest
  | SummarizeRequest;

export type BrainToAppMessage =
  | { type: "ready"; model: string; authSource: string; subscription?: string }
  | { type: "text_delta"; turnId: string; text: string }
  | { type: "text_block_end"; turnId: string }
  | { type: "activity"; turnId: string; text: string }
  | { type: "tool_call"; turnId: string; callId: string; name: string; input: unknown }
  | { type: "turn_done"; turnId: string; text: string; costUsd?: number; durationMs?: number; cancelled?: boolean }
  | { type: "turn_error"; turnId: string; message: string }
  | { type: "summary"; requestId: string; markdown: string }
  | { type: "log"; level: "info" | "warn" | "error"; message: string };
