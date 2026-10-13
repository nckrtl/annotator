#!/usr/bin/env bash
# Captures the real SwiftUI views with made-up data. No helpers, servers or user files.
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-app.sh --debug
output=${1:-"$PWD/Snapshots/designkit"}
mkdir -p "$output"
ANNOTATOR_UI_DEMO=1 ANNOTATOR_UI_SNAPSHOTS="$output" build/debug/Annotator.app/Contents/MacOS/Annotator
swift build --package-path native
ANNOTATOR_OVERLAY_SNAPSHOTS="$output" native/.build/debug/AnnotatorNative
