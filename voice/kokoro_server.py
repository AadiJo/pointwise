"""Pointwise's local neural voice: Kokoro-82M through kokoro-onnx.

Runs as a sidecar with the model loaded once. One JSON request per line on
stdin, one JSON reply per line on stdout:

  {"id": "7", "text": "Hello!", "voice": "af_heart", "speed": 1.0, "lang": "en-us", "out": "/tmp/x.wav"}
  {"id": "7", "ok": true, "path": "/tmp/x.wav", "seconds": 0.84}

Install with scripts/install-local-voice.sh. Everything runs on the Mac.
"""

import json
import os
import sys

import soundfile
from kokoro_onnx import Kokoro

VOICE_DIRECTORY = os.environ.get(
    "POINTWISE_VOICE_DIR",
    os.path.expanduser("~/Library/Application Support/Pointwise/voice"),
)


def reply(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def main():
    model = Kokoro(
        os.path.join(VOICE_DIRECTORY, "kokoro-v1.0.int8.onnx"),
        os.path.join(VOICE_DIRECTORY, "voices-v1.0.bin"),
    )
    reply({"ready": True, "voices": sorted(model.get_voices())})
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        request = {}
        try:
            request = json.loads(line)
            samples, sample_rate = model.create(
                request["text"],
                voice=request.get("voice", "af_heart"),
                speed=float(request.get("speed", 1.0)),
                lang=request.get("lang", "en-us"),
            )
            soundfile.write(request["out"], samples, sample_rate)
            reply({"id": request.get("id"), "ok": True, "path": request["out"], "seconds": len(samples) / sample_rate})
        except Exception as error:  # Report every failure; the app falls back to an Apple voice.
            reply({"id": request.get("id"), "ok": False, "error": str(error)})


if __name__ == "__main__":
    main()
