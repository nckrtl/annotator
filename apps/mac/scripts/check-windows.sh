#!/usr/bin/env bash
# Check library and comment window lifecycle with demo data; no core or server.
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-app.sh --debug
output=${1:-"$PWD/build/window-check"}
mkdir -p "$output"
rm -f "$output/window-check.txt"
open -n -W --env ANNOTATOR_UI_DEMO=1 --env ANNOTATOR_WINDOW_CHECK="$output" \
  --stdout "$output/stdout.log" --stderr "$output/stderr.log" "$PWD/build/debug/Annotator.app"
grep -q '^PASS:' "$output/window-check.txt"
