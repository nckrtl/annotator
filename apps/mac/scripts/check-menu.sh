#!/usr/bin/env bash
# Check the menu's intrinsic size and navigation with made-up data in light and dark.
set -euo pipefail
cd "$(dirname "$0")/.."
scratch="$PWD/build/swift-app"
output=${1:-"$PWD/build/menu-check"}
swift build --package-path app --scratch-path "$scratch"
bin=$(swift build --package-path app --scratch-path "$scratch" --show-bin-path)
ANNOTATOR_UI_DEMO=1 ANNOTATOR_MENU_CHECK="$output" "$bin/Annotator"
