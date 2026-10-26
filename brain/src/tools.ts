import { createSdkMcpServer, tool } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";
import type { ScreenImage } from "./protocol.js";

/** The app's answer to a tool call. */
export interface AppToolResult {
  text: string;
  screens?: ScreenImage[];
  isError?: boolean;
}

/** Sends a tool call to the Swift app and resolves with its result. */
export type AppToolCaller = (name: string, input: Record<string, unknown>) => Promise<AppToolResult>;

export const POINTWISE_MCP_SERVER_NAME = "pointwise";

export const pointwiseToolNames = [
  "look_at_screen",
  "start_walkthrough",
  "wait_for_step",
  "finish_walkthrough",
  "show_whiteboard",
  "quiz",
  "click_quiz",
  "show_simulation",
  "remember",
  "open_url",
  "do_action",
] as const;

export const allowedPointwiseToolIds = pointwiseToolNames.map((toolName) => `mcp__${POINTWISE_MCP_SERVER_NAME}__${toolName}`);

type ToolContent =
  | { type: "text"; text: string }
  | { type: "image"; data: string; mimeType: string };

/** Converts the app's answer into MCP content, labeling each screenshot with its pixel size. */
export function toCallToolResult(appResult: AppToolResult) {
  const content: ToolContent[] = [{ type: "text", text: appResult.text }];
  for (const screen of appResult.screens ?? []) {
    content.push({ type: "text", text: `${screen.label} (image size: ${screen.widthInPixels}x${screen.heightInPixels} pixels)` });
    content.push({ type: "image", data: screen.jpegBase64, mimeType: "image/jpeg" });
  }
  return { content, isError: appResult.isError ?? false };
}

const OPTIONAL_SAY = "Optional words Pointwise says aloud right before this tool runs. Your words between tool calls are NOT heard, so use this. May include drawing tags.";

export function createPointwiseToolServer(callApp: AppToolCaller) {
  const forward = (toolName: string) => async (input: Record<string, unknown>) =>
    toCallToolResult(await callApp(toolName, input));

  return createSdkMcpServer({
    name: POINTWISE_MCP_SERVER_NAME,
    version: "0.2.0",
    // "say" is the first field of every tool: the brain streams it to the
    // speech queue while the rest of the tool call is still being written.
    tools: [
      tool(
        "look_at_screen",
        "Take a fresh screenshot of the learner's screens. Use it when you need to see the current state before you continue.",
        {},
        forward("look_at_screen"),
      ),
      tool(
        "start_walkthrough",
        "Begin a guided, step-by-step walkthrough. Shows a checklist card on screen. Call once at the start of a multi-step task.",
        {
          say: z.string().optional().describe(OPTIONAL_SAY),
          title: z.string().describe("Short title, for example 'Make a pie chart'"),
          steps: z.array(z.string()).min(1).max(15).describe("Short step names, in order"),
        },
        forward("start_walkthrough"),
      ),
      tool(
        "wait_for_step",
        "Wait until the learner finishes the current walkthrough step. Waits for your speech to finish, then for the learner to click the target, say or type 'continue', or for the screen to change. Returns what happened and a fresh screenshot.",
        {
          say: z.string().describe("The instruction for this step, spoken aloud before waiting: one or two short sentences telling the learner exactly what to do, with a [POINT:x,y:label] or [CIRCLE:...] tag on the target. Required: your words between tool calls are NOT heard."),
          step_index: z.number().int().min(0).describe("Zero-based index of the step the learner is doing"),
          target_x: z.number().optional().describe("x of the thing to click, in screenshot pixels"),
          target_y: z.number().optional().describe("y of the thing to click, in screenshot pixels"),
          target_screen: z.number().int().optional().describe("Screen number of the target, if not the cursor's screen"),
          expect: z.enum(["click_target", "continue", "screen_change"]).default("click_target")
            .describe("What counts as done: a click near the target, the learner saying continue, or any screen change"),
          timeout_seconds: z.number().int().min(5).max(300).default(90),
        },
        forward("wait_for_step"),
      ),
      tool(
        "finish_walkthrough",
        "End the current walkthrough and mark all steps done.",
        {
          say: z.string().optional().describe(OPTIONAL_SAY),
          recap: z.string().describe("One sentence recap shown on the checklist card"),
        },
        forward("finish_walkthrough"),
      ),
      tool(
        "show_whiteboard",
        "Show a visual explanation on a whiteboard panel next to the cursor. Markdown with LaTeX math ($...$, $$...$$) and Mermaid diagrams in ```mermaid fences. Replaces the previous whiteboard or simulation.",
        {
          say: z.string().describe("Your spoken explanation of the whiteboard, 3 to 5 short sentences, said while it appears and stays on screen. May include drawing tags for things on the learner's screen. Required: your words between tool calls are NOT heard."),
          title: z.string(),
          markdown: z.string().describe("Short, visual content. No long paragraphs."),
        },
        forward("show_whiteboard"),
      ),
      tool(
        "show_simulation",
        `Open a live, interactive simulation in a panel next to the cursor, so the learner can experiment instead of only listening. Replaces the whiteboard. While it is open, change its values in your speech with [SIM:name=value,name=value] tags: the sliders move on screen at the moment that sentence is spoken, and the learner can drag them too.
Built-in kinds and their values:
- pendulum: length (meters, 0.2 to 3), gravity (m/s squared, 1 to 25; Moon 1.6, Earth 9.8, Jupiter 24.8), angle (degrees, 5 to 80), mass (kg, 0.1 to 10). Shows the measured period.
- projectile: speed (m/s, 5 to 40), angle (degrees, 5 to 85), gravity (1 to 25), height (launch height in meters, 0 to 20). Shows range, peak height, and time in the air.
- wave: amplitude (0.1 to 2), wavelength (meters, 0.5 to 6), frequency (hertz, 0.2 to 3). Shows wave speed = frequency times wavelength.
- graph: plots "expression" in x with parameters a, b, c, d (each -10 to 10), for example "a*x^2 + b*x + c" or "a*sin(b*x)". Marks x-intercepts and the vertex of parabolas.
- circuit: voltage (volts, 0 to 24), resistance (ohms, 1 to 100). Shows current with moving charges and a bulb whose brightness is the power.
- orbit: star_mass (in suns, 0.2 to 3), distance (AU, 0.5 to 3), speed (fraction of circular speed, 0.5 to 1.6; above about 1.41 the planet escapes).
- custom: only when no built-in kind fits. Provide a complete, self-contained HTML page in "html" (inline CSS and JavaScript, canvas or SVG, no network). Give it labeled sliders and define window.pointwiseSim = { set(values) } so [SIM:...] tags can change it.`,
        {
          say: z.string().describe("Spoken while the simulation opens: what it shows and what to watch. Usually end by asking the learner to predict what will happen when you change one value. Required: your words between tool calls are NOT heard."),
          kind: z.enum(["pendulum", "projectile", "wave", "graph", "circuit", "orbit", "custom"]),
          title: z.string().describe("Short title, for example 'Pendulum lab'"),
          params: z.record(z.string(), z.number()).optional().describe("Starting values, for example {\"length\": 1, \"gravity\": 9.8}"),
          expression: z.string().optional().describe("For kind graph: the expression in x, using a, b, c, d as parameters"),
          html: z.string().optional().describe("For kind custom only: the full HTML page"),
        },
        forward("show_simulation"),
      ),
      tool(
        "quiz",
        "Show a multiple-choice question and wait for the learner's answer. Returns which choice they picked and whether it was right.",
        {
          say: z.string().optional().describe(OPTIONAL_SAY),
          question: z.string(),
          choices: z.array(z.string()).min(2).max(5),
          correct_index: z.number().int().min(0),
          explanation: z.string().describe("One or two sentences shown after they answer"),
        },
        forward("quiz"),
      ),
      tool(
        "click_quiz",
        "Turn anything on the learner's screen into a quiz: ask them to find and click something (a part of a diagram, a place on a map, a line of code with a bug, a word in a sentence, a button in an app). Waits for their click and reports whether it hit the target, with a fresh screenshot that marks where they clicked. The app shows a check mark or a cross at the click.",
        {
          say: z.string().describe("The spoken question, for example 'Can you click on the part of the cell that makes energy?' Never name its position, point at it, or draw on it."),
          prompt: z.string().describe("Short text on the quiz card, for example 'Click the mitochondria'"),
          target_x: z.number().describe("x of the center of the correct area, in screenshot pixels"),
          target_y: z.number().describe("y of the center of the correct area, in screenshot pixels"),
          target_radius: z.number().min(10).max(400).default(45).describe("How far from the center still counts as correct, in screenshot pixels"),
          target_screen: z.number().int().optional(),
          timeout_seconds: z.number().int().min(10).max(300).default(60),
        },
        forward("click_quiz"),
      ),
      tool(
        "remember",
        "Save one lasting fact about the learner for future sessions (goals, grade level, interests, what they find hard).",
        { fact: z.string().max(300) },
        forward("remember"),
      ),
      tool(
        "open_url",
        "Open a web page that helps you teach or demo something, such as Desmos, a PhET simulation, Wikipedia, or documentation.",
        {
          say: z.string().optional().describe(OPTIONAL_SAY),
          url: z.string().url(),
          reason: z.string().describe("Short reason shown to the learner"),
        },
        forward("open_url"),
      ),
      tool(
        "do_action",
        "Demonstrate by doing: click, type, press keys, or scroll on the learner's screen. Only works when the learner allowed it. Before each action, say in a few words what you are about to do (with a POINT tag on the target), so the learner can follow along. Never delete, send, buy, or post.",
        {
          say: z.string().describe("What you are about to do, spoken aloud before the action, like a teacher demonstrating. For example: 'First I'll click the search box up here. [POINT:400,60:search box]'"),
          action: z.enum(["click", "double_click", "type", "key", "scroll"]),
          x: z.number().optional().describe("Screenshot pixel x for click, double_click, or scroll"),
          y: z.number().optional().describe("Screenshot pixel y for click, double_click, or scroll"),
          screen: z.number().int().optional(),
          text: z.string().optional().describe("Text to type for 'type'"),
          keys: z.string().optional().describe("Key combo for 'key', for example 'cmd+c' or 'return'"),
          scroll_amount: z.number().int().optional().describe("Lines to scroll; negative scrolls up"),
          description: z.string().describe("What this action does, in a few words"),
        },
        forward("do_action"),
      ),
    ],
  });
}
