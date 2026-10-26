/**
 * Pulls the top-level "say" string out of a tool call's JSON input while the
 * model is still writing it, so Pointwise can start talking seconds before the
 * whole tool call (a whiteboard, a list of steps) is finished.
 *
 * Feed it the `partial_json` chunks in order; each call returns the newly
 * decoded characters of the "say" value (empty when there are none).
 */
export class SayFieldExtractor {
  private depth = 0;
  private isInString = false;
  private isEscapeNext = false;
  private unicodeEscapeDigits: string | null = null;
  private pendingHighSurrogate = "";
  private isExpectingKey = false;
  private isCapturingKey = false;
  private currentKey = "";
  private lastCompletedKey = "";
  private isExpectingValue = false;
  private isEmittingSay = false;
  private hasFinishedSay = false;

  append(chunk: string): string {
    let decodedSay = "";
    const emit = (text: string) => {
      if (this.isEmittingSay) decodedSay += this.joinSurrogates(text);
      else if (this.isCapturingKey) this.currentKey += text;
    };

    for (const character of chunk) {
      if (this.isInString) {
        if (this.unicodeEscapeDigits !== null) {
          this.unicodeEscapeDigits += character;
          if (this.unicodeEscapeDigits.length === 4) {
            emit(String.fromCharCode(parseInt(this.unicodeEscapeDigits, 16)));
            this.unicodeEscapeDigits = null;
          }
          continue;
        }
        if (this.isEscapeNext) {
          this.isEscapeNext = false;
          if (character === "u") {
            this.unicodeEscapeDigits = "";
            continue;
          }
          const escapedCharacters: Record<string, string> = { n: "\n", t: "\t", r: "\r", b: "\b", f: "\f" };
          emit(escapedCharacters[character] ?? character);
          continue;
        }
        if (character === "\\") {
          this.isEscapeNext = true;
          continue;
        }
        if (character === '"') {
          this.isInString = false;
          if (this.isCapturingKey) {
            this.isCapturingKey = false;
            this.lastCompletedKey = this.currentKey;
          }
          if (this.isEmittingSay) {
            this.isEmittingSay = false;
            this.hasFinishedSay = true;
          }
          continue;
        }
        emit(character);
        continue;
      }

      if (character === '"') {
        this.isInString = true;
        if (this.depth === 1 && this.isExpectingKey) {
          this.isExpectingKey = false;
          this.isCapturingKey = true;
          this.currentKey = "";
        } else if (this.depth === 1 && this.isExpectingValue) {
          this.isExpectingValue = false;
          this.isEmittingSay = this.lastCompletedKey === "say" && !this.hasFinishedSay;
        }
        continue;
      }
      if (character === "{" || character === "[") {
        this.depth += 1;
        if (this.depth === 1) this.isExpectingKey = true;
        this.isExpectingValue = false;
        continue;
      }
      if (character === "}" || character === "]") {
        this.depth -= 1;
        continue;
      }
      if (this.depth === 1) {
        if (character === ":") this.isExpectingValue = true;
        else if (character === ",") this.isExpectingKey = true;
        else if (!/\s/.test(character)) this.isExpectingValue = false;
      }
    }
    return decodedSay;
  }

  /** Holds a lone high surrogate until its partner arrives, so no message carries half an emoji. */
  private joinSurrogates(text: string): string {
    let combined = this.pendingHighSurrogate + text;
    this.pendingHighSurrogate = "";
    const lastCode = combined.charCodeAt(combined.length - 1);
    if (lastCode >= 0xd800 && lastCode <= 0xdbff) {
      this.pendingHighSurrogate = combined.slice(-1);
      combined = combined.slice(0, -1);
    }
    return combined;
  }
}
