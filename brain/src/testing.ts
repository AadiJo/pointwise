// Entry point that exposes pure helpers to the unit tests without starting the stdio loop.
export { buildUserMessage } from "./session.js";
export { toCallToolResult } from "./tools.js";
export { buildSystemPrompt } from "./prompt.js";
export { SayFieldExtractor } from "./sayStream.js";
