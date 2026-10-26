// End-to-end smoke test: starts the bundled brain, asks one question with a
// screenshot, and answers tool calls like the app would. Uses real Claude
// through the local Claude Code login, so it is not part of `npm test`.
// Usage: node test/smoke.mjs <screenshot.jpg> "<question>"
import { spawn } from "node:child_process";
import fs from "node:fs";
import readline from "node:readline";

const [screenshotPath, question = "What is on my screen? Point at the most important button."] = process.argv.slice(2);
const jpegBase64 = fs.readFileSync(screenshotPath).toString("base64");
const startTime = Date.now();
const elapsed = () => `${((Date.now() - startTime) / 1000).toFixed(1)}s`;
const brain = spawn("node", [new URL("../dist/brain.mjs", import.meta.url).pathname], { stdio: ["pipe", "pipe", "inherit"] });
const send = (message) => brain.stdin.write(JSON.stringify(message) + "\n");
const screens = [{ jpegBase64, label: "user's screen (cursor is here)", widthInPixels: 1280, heightInPixels: 720 }];

send({ type: "configure", model: process.env.MODEL ?? "claude-opus-5-5", effort: "low", learnerProfile: "Name: Sam. Grade 9." });
send({ type: "ask", turnId: "t1", text: question, screens, inputMode: "voice" });

readline.createInterface({ input: brain.stdout }).on("line", (line) => {
  const message = JSON.parse(line);
  if (message.type === "text_delta") return process.stdout.write(message.text);
  console.log(`\n[${elapsed()}] ${message.type}`, JSON.stringify({ ...message, text: message.type === "turn_done" ? undefined : message.text }).slice(0, 300));
  if (message.type === "tool_call") {
    const reply = message.name === "wait_for_step" || message.name === "look_at_screen"
      ? { text: "The learner clicked the target. Fresh screenshot attached.", screens }
      : message.name === "quiz" ? { text: "The learner picked choice 0. That is correct." } : { text: "Done." };
    send({ type: "tool_result", callId: message.callId, ...reply });
  }
  if (message.type === "turn_done" || message.type === "turn_error") { brain.stdin.end(); setTimeout(() => process.exit(0), 500); }
});
