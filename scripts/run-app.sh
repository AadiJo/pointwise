#!/bin/zsh
# Builds (debug) and opens Pointwise. Extra arguments are passed to the app.
set -euo pipefail
repo_root="${0:A:h:h}"
"$repo_root/scripts/build-app.sh" "${POINTWISE_CONFIGURATION:-debug}"
pkill -x Pointwise 2>/dev/null || true
open "$repo_root/build/Pointwise.app" --args "$@"
