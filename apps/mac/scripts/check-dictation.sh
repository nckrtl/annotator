#!/usr/bin/env bash
# Test the real panel with fake Operator session replies and made-up text. No user settings,
# recording or clipboard.
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-app.sh --debug
output=${1:-"$PWD/build/dictation-check"}
mkdir -p "$output"
rm -f "$output/dictation-panel-check.txt"
# LaunchServices must activate the bundle, as it does for an installed menu-bar app.
open -n -W --env ANNOTATOR_UI_DEMO=1 --env ANNOTATOR_DICTATION_CHECK="$output" \
  --stdout "$output/panel-stdout.log" --stderr "$output/panel-stderr.log" "$PWD/build/debug/Annotator.app"
grep -q '^PASS:' "$output/dictation-panel-check.txt"
