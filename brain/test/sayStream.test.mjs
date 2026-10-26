import assert from "node:assert/strict";
import { test } from "node:test";
import { SayFieldExtractor } from "../dist/testing.mjs";

/** Feeds JSON in small uneven chunks, the way input_json_delta events arrive. */
function streamInChunks(json, chunkSizes = [1, 3, 7, 2, 5]) {
  const extractor = new SayFieldExtractor();
  let spoken = "";
  let position = 0;
  let chunkIndex = 0;
  while (position < json.length) {
    const size = chunkSizes[chunkIndex++ % chunkSizes.length];
    spoken += extractor.append(json.slice(position, position + size));
    position += size;
  }
  return spoken;
}

test("streams only the top-level say value, decoded", () => {
  const input = { say: "Click \"Insert\" here. [POINT:212,14:Insert menu]\nThen pick Chart.", title: "Make a chart", steps: ["Open Insert", "Pick Chart"] };
  assert.equal(streamInChunks(JSON.stringify(input)), input.say);
});

test("ignores say keys nested inside other values and keys after the first say", () => {
  const json = JSON.stringify({ steps: [{ say: "nested" }], markdown: "the word say: \"x\"", say: "Hello there.", note: { say: "no" } });
  assert.equal(streamInChunks(json), "Hello there.");
});

test("decodes unicode escapes and keeps emoji whole across chunks", () => {
  const json = '{"say":"Caf\\u00e9 time \\ud83d\\ude00 done"}';
  const extractor = new SayFieldExtractor();
  const pieces = [];
  for (const character of json) pieces.push(extractor.append(character));
  assert.equal(pieces.join(""), "Café time 😀 done");
  assert.ok(pieces.every((piece) => !/^[\ud800-\udbff]$/.test(piece)), "no piece is a lone high surrogate");
});

test("returns nothing when the tool has no say field", () => {
  assert.equal(streamInChunks(JSON.stringify({ title: "say", markdown: "say" })), "");
});
