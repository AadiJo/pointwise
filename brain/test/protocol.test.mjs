import assert from "node:assert/strict";
import { test } from "node:test";
import { buildUserMessage, toCallToolResult } from "../dist/testing.mjs";

const screen = { jpegBase64: "AAAA", label: "user's screen (cursor is here)", widthInPixels: 1280, heightInPixels: 800 };

test("user message lists each screenshot label before its image, then the question", () => {
  const message = buildUserMessage({ type: "ask", turnId: "t", text: "what is this?", screens: [screen], context: "Front app: Safari", inputMode: "typed" });
  const content = message.message.content;
  assert.equal(content[0].type, "text");
  assert.match(content[0].text, /1280x800 pixels/);
  assert.equal(content[1].type, "image");
  assert.equal(content[1].source.data, "AAAA");
  assert.match(content[2].text, /Front app: Safari/);
  assert.match(content[2].text, /The learner typed: what is this\?/);
});

test("tool results carry labeled screenshots as MCP image content", () => {
  const result = toCallToolResult({ text: "clicked", screens: [screen] });
  assert.deepEqual(result.content.map((block) => block.type), ["text", "text", "image"]);
  assert.equal(result.content[2].mimeType, "image/jpeg");
  assert.equal(result.isError, false);
});
