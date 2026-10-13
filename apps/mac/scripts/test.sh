#!/usr/bin/env bash
# Runs every test: the Swift helper, the Rust core and the React views.
set -euo pipefail
cd "$(dirname "$0")/.."
swift test --package-path native
# The Tauri build bundles the helper, so cargo test needs it to exist.
[[ -e src-tauri/binaries/annotator-native ]] || bash scripts/build-native.sh
(cd src-tauri && cargo test)
bunx tsc -b
bun test scripts/
