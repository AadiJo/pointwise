#!/bin/zsh
# Installs Pointwise's free on-device neural voice (Kokoro-82M via kokoro-onnx).
# About 280 MB in ~/Library/Application Support/Pointwise/voice. Needs Python 3.10+.
set -euo pipefail

voice_dir="${POINTWISE_VOICE_DIR:-$HOME/Library/Application Support/Pointwise/voice}"
model_base="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
python_bin="$(command -v python3 || true)"
if [ -z "$python_bin" ]; then
  echo "Python 3 is needed. Install it from python.org, then run this again." >&2
  exit 1
fi

mkdir -p "$voice_dir"
echo "→ Creating a private Python environment"
[ -x "$voice_dir/venv/bin/python" ] || "$python_bin" -m venv "$voice_dir/venv"
"$voice_dir/venv/bin/pip" install --quiet --no-cache-dir kokoro-onnx soundfile

echo "→ Downloading the voice model (about 120 MB)"
for file in kokoro-v1.0.int8.onnx voices-v1.0.bin; do
  [ -s "$voice_dir/$file" ] || curl -fL --progress-bar -o "$voice_dir/$file" "$model_base/$file"
done

echo "✓ Natural voice installed in $voice_dir. Restart Pointwise to use it."
