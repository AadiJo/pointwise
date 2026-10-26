import readline from "node:readline";
import type { AppToBrainMessage, BrainToAppMessage } from "./protocol.js";
import { TutorSession } from "./session.js";

// stdout carries the protocol, so anything else that logs must go to stderr.
console.log = (...values: unknown[]) => process.stderr.write(`${values.map(String).join(" ")}\n`);
console.info = console.log;

function sendToApp(message: BrainToAppMessage): void {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

const session = new TutorSession(sendToApp);

const lineReader = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });

lineReader.on("line", (line) => {
  if (!line.trim()) return;
  let message: AppToBrainMessage;
  try {
    message = JSON.parse(line) as AppToBrainMessage;
  } catch {
    sendToApp({ type: "log", level: "warn", message: "Ignored a line that was not JSON." });
    return;
  }
  void handleMessage(message).catch((error) =>
    sendToApp({ type: "log", level: "error", message: `Failed to handle ${message.type}: ${String(error)}` }),
  );
});

lineReader.on("close", () => {
  session.shutdown();
  process.exit(0);
});

async function handleMessage(message: AppToBrainMessage): Promise<void> {
  switch (message.type) {
    case "configure":
      session.configure(message);
      return;
    case "ask":
      await session.ask(message);
      return;
    case "tool_result":
      session.handleToolResult(message);
      return;
    case "cancel":
      await session.cancel();
      return;
    case "reset":
      session.reset();
      return;
    case "summarize":
      await session.summarize(message.requestId, message.transcript);
      return;
  }
}

for (const signal of ["SIGTERM", "SIGINT"] as const) {
  process.on(signal, () => {
    session.shutdown();
    process.exit(0);
  });
}
