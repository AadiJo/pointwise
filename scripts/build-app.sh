#!/bin/zsh
# Builds Pointwise.app into ./build. Usage: scripts/build-app.sh [debug|release]
set -euo pipefail

configuration="${1:-release}"
repo_root="${0:A:h:h}"
cd "$repo_root"

# Limit parallel compile jobs so the build stays friendly on 8 GB machines.
swift build -c "$configuration" --jobs "${POINTWISE_BUILD_JOBS:-4}" --product Pointwise

echo "→ Bundling the brain sidecar"
(cd brain && [ -d node_modules ] || npm install --no-audit --no-fund) >/dev/null
(cd brain && npm run --silent build)

app_path="build/Pointwise.app"
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources/brain"
cp ".build/$configuration/Pointwise" "$app_path/Contents/MacOS/Pointwise"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
cp brain/dist/brain.mjs "$app_path/Contents/Resources/brain/brain.mjs"
cp -R Resources/Assets/. "$app_path/Contents/Resources/" 2>/dev/null || true
mkdir -p "$app_path/Contents/Resources/voice"
cp voice/kokoro_server.py "$app_path/Contents/Resources/voice/kokoro_server.py"
cp scripts/install-local-voice.sh "$app_path/Contents/Resources/voice/install-local-voice.sh"

# Prefer a stable Developer ID signature so macOS keeps permissions across rebuilds.
identities="$(security find-identity -v -p codesigning 2>/dev/null)"
signing_identity="${POINTWISE_SIGNING_IDENTITY:-$(echo "$identities" | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
[ -z "$signing_identity" ] && signing_identity="$(echo "$identities" | awk -F'"' '/Apple Development/ {print $2; exit}')"
if [ -n "$signing_identity" ] && perl -e 'alarm 60; exec @ARGV' codesign --force --deep --options runtime --timestamp=none \
    --entitlements Resources/Pointwise.entitlements --sign "$signing_identity" "$app_path" 2>/dev/null; then
  echo "→ Signed with: $signing_identity"
else
  codesign --force --deep --entitlements Resources/Pointwise.entitlements --sign - "$app_path"
  echo "→ Signed ad hoc (permissions may reset after each rebuild)"
fi

echo "✓ Built $app_path"
