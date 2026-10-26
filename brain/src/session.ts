import { query, type Query, type SDKMessage, type SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { AsyncQueue } from "./asyncQueue.js";
import { SayFieldExtractor } from "./sayStream.js";
import { buildSystemPrompt, studyNotesPrompt } from "./prompt.js";
import type { AskRequest, BrainToAppMessage, ConfigureRequest, ScreenImage, ToolResultMessage } from "./protocol.js";
import { allowedPointwiseToolIds, createPointwiseToolServer, POINTWISE_MCP_SERVER_NAME, type AppToolResult } from "./tools.js";

export const DEFAULT_MODEL = "claude-opus-5-5";
const BUILT_IN_TOOLS = ["WebSearch", "WebFetch"];
const INTERRUPT_GRACE_PERIOD_MS = 6000;

type SendToApp = (message: BrainToAppMessage) => void;

interface PendingToolCall {
  turnId: string;
  resolve: (result: AppToolResult) => void;
}

interface ActiveTurn {
  turnId: string;
  spokenText: string;
  wasCancelled: boolean;
  finished: Promise<void>;
  markFinished: () => void;
}

/** Finds the user's installed Claude Code CLI so the SDK reuses its login. */
export function resolveClaudeExecutablePath(preferredPath?: string): string | undefined {
  const candidatePaths = [
    preferredPath,
    process.env.POINTWISE_CLAUDE_PATH,
    path.join(os.homedir(), ".local/bin/claude"),
    path.join(os.homedir(), ".claude/local/claude"),
    "/opt/homebrew/bin/claude",
    "/usr/local/bin/claude",
    ...(process.env.PATH ?? "").split(":").map((directory) => path.join(directory, "claude")),
  ];
  return candidatePaths.find((candidatePath) => candidatePath && fs.existsSync(candidatePath)) ?? undefined;
}

/** Builds one Agent SDK user message with labeled screenshots, then the learner's words. */
export function buildUserMessage(request: AskRequest): SDKUserMessage {
  const content: Array<Record<string, unknown>> = [];
  for (const screen of request.screens) {
    content.push({ type: "text", text: `${screen.label} (image size: ${screen.widthInPixels}x${screen.heightInPixels} pixels)` });
    content.push({ type: "image", source: { type: "base64", media_type: "image/jpeg", data: screen.jpegBase64 } });
  }
  const contextBlock = request.context?.trim() ? `Context from the app:\n${request.context.trim()}\n\n` : "";
  const inputDescription = request.inputMode === "typed" ? "The learner typed" : "The learner said";
  content.push({ type: "text", text: `${contextBlock}${inputDescription}: ${request.text}` });
  return {
    type: "user",
    parent_tool_use_id: null,
    message: { role: "user", content: content as never },
  };
}

/** Environment for the Claude Code process: inherit, but never use an API key, so the Claude Code login is used. */
function claudeCodeEnvironment(): Record<string, string | undefined> {
  const environment: Record<string, string | undefined> = { ...process.env, CLAUDE_AGENT_SDK_CLIENT_APP: "pointwise/0.1.0" };
  delete environment.ANTHROPIC_API_KEY;
  delete environment.ANTHROPIC_AUTH_TOKEN;
  return environment;
}

function workingDirectory(): string {
  const directory = process.env.POINTWISE_WORKDIR ?? path.join(os.homedir(), "Library/Application Support/Pointwise/brain");
  fs.mkdirSync(directory, { recursive: true });
  return directory;
}

export class TutorSession {
  private settings: ConfigureRequest = { type: "configure", model: DEFAULT_MODEL, effort: "low" };
  private inputQueue?: AsyncQueue<SDKUserMessage>;
  private activeQuery?: Query;
  private sessionNeedsRestart = true;
  private activeTurn?: ActiveTurn;
  private readonly pendingToolCalls = new Map<string, PendingToolCall>();
  private nextToolCallNumber = 1;
  private textBlockIndexes = new Set<number>();
  /** Pointwise tool calls being written right now, by content block index, with their streamed "say" text. */
  private toolSayStreams = new Map<number, { extractor: SayFieldExtractor; streamedText: string }>();
  /** "say" texts already spoken while streaming, so the app does not speak them twice. */
  private streamedSayTexts: string[] = [];
  /** Pointwise tool calls started in the current assistant message. */
  private pointwiseToolCallsInMessage = 0;

  constructor(private readonly sendToApp: SendToApp) {}

  configure(request: ConfigureRequest): void {
    const promptChanged =
      request.learnerProfile !== undefined && request.learnerProfile !== this.settings.learnerProfile ||
      request.language !== undefined && request.language !== this.settings.language ||
      request.actionsEnabled !== undefined && request.actionsEnabled !== this.settings.actionsEnabled ||
      request.claudeExecutablePath !== undefined && request.claudeExecutablePath !== this.settings.claudeExecutablePath ||
      request.effort !== undefined && request.effort !== this.settings.effort ||
      request.thinking !== undefined && request.thinking !== this.settings.thinking;
    // Memory changes (from the remember tool) are already in the conversation,
    // so they reach the system prompt at the next session instead of restarting this one.
    const modelChanged = request.model !== undefined && request.model !== this.settings.model;
    this.settings = { ...this.settings, ...Object.fromEntries(Object.entries(request).filter(([, value]) => value !== undefined)) };

    if (promptChanged) {
      // A new system prompt needs a new session. Start it now if idle so the next question is fast.
      this.sessionNeedsRestart = true;
      if (!this.activeTurn) this.startSession();
    } else if (modelChanged && this.activeQuery) {
      void this.activeQuery.setModel(this.settings.model).catch(() => {
        this.sessionNeedsRestart = true;
      });
    } else if (!this.activeQuery) {
      this.startSession();
    }
  }

  async ask(request: AskRequest): Promise<void> {
    if (this.activeTurn) {
      await this.cancel();
    }
    if (!this.activeQuery || this.sessionNeedsRestart) {
      this.startSession();
    }
    let markFinished: () => void = () => {};
    const finished = new Promise<void>((resolve) => (markFinished = resolve));
    this.activeTurn = { turnId: request.turnId, spokenText: "", wasCancelled: false, finished, markFinished };
    this.streamedSayTexts = [];
    this.inputQueue!.push(buildUserMessage(request));
  }

  async cancel(): Promise<void> {
    const turn = this.activeTurn;
    if (!turn) return;
    turn.wasCancelled = true;
    this.resolveAllPendingToolCalls("The learner interrupted. Stop this step and wait for their next question.");
    try {
      await Promise.race([
        this.activeQuery?.interrupt(),
        new Promise((resolve) => setTimeout(resolve, INTERRUPT_GRACE_PERIOD_MS)),
      ]);
    } catch {
      // Interrupt failures are handled by the restart below.
    }
    const finishedInTime = await Promise.race([
      turn.finished.then(() => true),
      new Promise<boolean>((resolve) => setTimeout(() => resolve(false), INTERRUPT_GRACE_PERIOD_MS)),
    ]);
    if (!finishedInTime) {
      this.log("warn", "Interrupt did not finish in time; restarting the session.");
      this.finishActiveTurn({ cancelled: true });
      this.sessionNeedsRestart = true;
    }
  }

  reset(): void {
    this.resolveAllPendingToolCalls("The session was reset.");
    this.finishActiveTurn({ cancelled: true });
    this.closeSession();
    this.startSession();
  }

  handleToolResult(message: ToolResultMessage): void {
    const pendingToolCall = this.pendingToolCalls.get(message.callId);
    if (!pendingToolCall) return;
    this.pendingToolCalls.delete(message.callId);
    pendingToolCall.resolve({ text: message.text, screens: message.screens, isError: message.isError });
  }

  async summarize(requestId: string, transcript: string): Promise<void> {
    let markdown = "";
    try {
      const notesQuery = query({
        prompt: `Here is the tutoring conversation:\n\n${transcript}`,
        options: {
          ...this.baseOptions(),
          systemPrompt: studyNotesPrompt,
          tools: [],
          mcpServers: {},
          allowedTools: [],
          includePartialMessages: false,
        },
      });
      for await (const message of notesQuery) {
        if (message.type === "result" && message.subtype === "success") markdown = message.result;
      }
    } catch (error) {
      markdown = `Could not make notes: ${String(error)}`;
    }
    this.sendToApp({ type: "summary", requestId, markdown });
  }

  shutdown(): void {
    this.resolveAllPendingToolCalls("Pointwise is closing.");
    this.closeSession();
  }

  // MARK: - Session lifecycle

  private baseOptions() {
    return {
      model: this.settings.model ?? DEFAULT_MODEL,
      effort: this.settings.effort ?? "low",
      // Thinking before the first word adds seconds of silence; a spoken tutor
      // answers better fast than perfect, so it is off unless asked for.
      thinking: (process.env.POINTWISE_THINKING ?? this.settings.thinking) === "adaptive"
        ? { type: "adaptive" as const }
        : { type: "disabled" as const },
      pathToClaudeCodeExecutable: resolveClaudeExecutablePath(this.settings.claudeExecutablePath),
      cwd: workingDirectory(),
      env: claudeCodeEnvironment(),
      settingSources: [],
      persistSession: false,
      permissionMode: "dontAsk" as const,
      stderr: (data: string) => this.log("info", `claude: ${data.trim()}`),
    };
  }

  private startSession(): void {
    this.closeSession();
    this.sessionNeedsRestart = false;
    this.inputQueue = new AsyncQueue<SDKUserMessage>();
    const toolServer = createPointwiseToolServer((toolName, input) => this.callApp(toolName, input));
    const sessionQuery = query({
      prompt: this.inputQueue,
      options: {
        ...this.baseOptions(),
        systemPrompt: buildSystemPrompt(this.settings),
        tools: BUILT_IN_TOOLS,
        mcpServers: { [POINTWISE_MCP_SERVER_NAME]: toolServer },
        allowedTools: [...BUILT_IN_TOOLS, ...allowedPointwiseToolIds],
        includePartialMessages: true,
      },
    });
    this.activeQuery = sessionQuery;
    void this.consume(sessionQuery);
    // In streaming-input mode the CLI's init message waits for the first
    // question, so confirm the login now and report ready early.
    void sessionQuery.accountInfo().then(
      (accountInfo) => {
        if (sessionQuery !== this.activeQuery) return;
        this.sendToApp({
          type: "ready",
          model: this.settings.model ?? DEFAULT_MODEL,
          authSource: accountInfo.apiKeySource ?? "none",
          subscription: accountInfo.subscriptionType,
        });
      },
      (error) => this.log("warn", `Could not read Claude account info: ${String(error)}`),
    );
  }

  private closeSession(): void {
    this.inputQueue?.close();
    this.inputQueue = undefined;
    const closingQuery = this.activeQuery;
    this.activeQuery = undefined;
    try {
      closingQuery?.close();
    } catch {
      // Already closed.
    }
  }

  private async consume(sessionQuery: Query): Promise<void> {
    try {
      for await (const message of sessionQuery) {
        if (sessionQuery !== this.activeQuery) return;
        this.handleSdkMessage(message);
      }
    } catch (error) {
      if (sessionQuery !== this.activeQuery) return;
      const turn = this.activeTurn;
      this.log("error", `Session ended with error: ${String(error)}`);
      if (turn) this.sendToApp({ type: "turn_error", turnId: turn.turnId, message: describeError(error) });
      this.finishActiveTurn({ cancelled: true, silent: true });
      this.sessionNeedsRestart = true;
    }
  }

  private handleSdkMessage(message: SDKMessage): void {
    const turn = this.activeTurn;
    switch (message.type) {
      case "system":
        if (message.subtype === "init") {
          this.sendToApp({ type: "ready", model: message.model, authSource: message.apiKeySource });
        }
        return;
      case "stream_event": {
        if (!turn || turn.wasCancelled || message.parent_tool_use_id) return;
        const event = message.event;
        if (event.type === "content_block_start") {
          if (event.content_block.type === "text") this.textBlockIndexes.add(event.index);
          if (event.content_block.type === "server_tool_use" || event.content_block.type === "tool_use") {
            const activity = describeToolActivity(event.content_block.name);
            if (activity) this.sendToApp({ type: "activity", turnId: turn.turnId, text: activity });
          }
          if (event.content_block.type === "tool_use" && event.content_block.name.startsWith(`mcp__${POINTWISE_MCP_SERVER_NAME}__`)) {
            // Only the first tool of a message speaks early. Later tools in the same message
            // (click, then type, then press Return) speak when they run, so words match actions.
            if (this.pointwiseToolCallsInMessage === 0) {
              this.toolSayStreams.set(event.index, { extractor: new SayFieldExtractor(), streamedText: "" });
            }
            this.pointwiseToolCallsInMessage += 1;
          }
        } else if (event.type === "content_block_delta" && event.delta.type === "text_delta") {
          turn.spokenText += event.delta.text;
          this.sendToApp({ type: "text_delta", turnId: turn.turnId, text: event.delta.text });
        } else if (event.type === "content_block_delta" && event.delta.type === "input_json_delta") {
          // Speak a tool's "say" while the rest of the tool call is still being written.
          const sayStream = this.toolSayStreams.get(event.index);
          const newSayText = sayStream?.extractor.append(event.delta.partial_json) ?? "";
          if (sayStream && newSayText) {
            sayStream.streamedText += newSayText;
            turn.spokenText += newSayText;
            this.sendToApp({ type: "text_delta", turnId: turn.turnId, text: newSayText });
          }
        } else if (event.type === "content_block_stop" && this.textBlockIndexes.has(event.index)) {
          this.textBlockIndexes.delete(event.index);
          turn.spokenText += "\n";
          this.sendToApp({ type: "text_block_end", turnId: turn.turnId });
        } else if (event.type === "content_block_stop" && this.toolSayStreams.has(event.index)) {
          const sayStream = this.toolSayStreams.get(event.index)!;
          this.toolSayStreams.delete(event.index);
          if (sayStream.streamedText) {
            this.streamedSayTexts.push(sayStream.streamedText.trim());
            turn.spokenText += "\n";
            this.sendToApp({ type: "text_block_end", turnId: turn.turnId });
          }
        } else if (event.type === "message_start") {
          this.textBlockIndexes.clear();
          this.toolSayStreams.clear();
          this.pointwiseToolCallsInMessage = 0;
        }
        return;
      }
      case "result": {
        if (!turn) return;
        if (message.subtype !== "success" && !turn.wasCancelled) {
          const errorText = "errors" in message && Array.isArray(message.errors) ? message.errors.join("; ") : message.subtype;
          this.sendToApp({ type: "turn_error", turnId: turn.turnId, message: errorText });
        } else if (message.subtype === "success" && message.is_error && !turn.wasCancelled) {
          this.sendToApp({ type: "turn_error", turnId: turn.turnId, message: message.result });
        }
        this.finishActiveTurn({
          cancelled: turn.wasCancelled,
          costUsd: message.total_cost_usd,
          durationMs: message.duration_ms,
        });
        return;
      }
      default:
        return;
    }
  }

  private finishActiveTurn(details: { cancelled: boolean; costUsd?: number; durationMs?: number; silent?: boolean }): void {
    const turn = this.activeTurn;
    if (!turn) return;
    this.activeTurn = undefined;
    if (!details.silent) {
      this.sendToApp({
        type: "turn_done",
        turnId: turn.turnId,
        text: turn.spokenText.trim(),
        costUsd: details.costUsd,
        durationMs: details.durationMs,
        cancelled: details.cancelled || undefined,
      });
    }
    turn.markFinished();
  }

  // MARK: - Tool bridge

  private callApp(toolName: string, input: Record<string, unknown>): Promise<AppToolResult> {
    const turn = this.activeTurn;
    if (!turn || turn.wasCancelled) {
      return Promise.resolve({ text: "The learner interrupted. Wait for their next question.", isError: true });
    }
    const callId = `call-${this.nextToolCallNumber++}`;
    const sayText = typeof input.say === "string" ? input.say.trim() : "";
    const streamedSayIndex = sayText ? this.streamedSayTexts.indexOf(sayText) : -1;
    if (streamedSayIndex >= 0) {
      this.streamedSayTexts.splice(streamedSayIndex, 1);
      input = { ...input, say_streamed: true };
    }
    return new Promise((resolve) => {
      this.pendingToolCalls.set(callId, { turnId: turn.turnId, resolve });
      this.sendToApp({ type: "tool_call", turnId: turn.turnId, callId, name: toolName, input });
    });
  }

  private resolveAllPendingToolCalls(reason: string): void {
    for (const [callId, pendingToolCall] of this.pendingToolCalls) {
      pendingToolCall.resolve({ text: reason, isError: true });
      this.pendingToolCalls.delete(callId);
    }
  }

  private log(level: "info" | "warn" | "error", message: string): void {
    this.sendToApp({ type: "log", level, message });
  }
}

function describeToolActivity(toolName: string): string | undefined {
  if (toolName === "WebSearch" || toolName === "web_search") return "Searching the web";
  if (toolName === "WebFetch" || toolName === "web_fetch") return "Reading the page";
  return undefined;
}

function describeError(error: unknown): string {
  const text = String(error instanceof Error ? error.message : error);
  if (/login|auth|401|credential/i.test(text)) {
    return "Pointwise could not sign in to Claude. Open Terminal and run: claude, then /login.";
  }
  if (/ENOENT|spawn/i.test(text)) {
    return "Pointwise could not find Claude Code. Install it from claude.com/code and sign in.";
  }
  return text;
}

export type { ScreenImage };
