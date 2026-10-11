#!/usr/bin/env bash
# Runs every test: the Swift helper, the Rust core and the React views.
set -euo pipefail
cd "$(dirname "$0")/.."
swift test --package-path native
(cd src-tauri && cargo test)
bunx tsc -b
bun test scripts/
