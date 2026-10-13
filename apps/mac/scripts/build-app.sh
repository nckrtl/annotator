#!/usr/bin/env bash
# Builds and signs src-tauri/target/release/bundle/macos/Annotator.app.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing.sh
require_signing_identity
bash scripts/build-native.sh
bun run tauri build
bash scripts/sign-app.sh src-tauri/target/release/bundle/macos/Annotator.app
echo "Built src-tauri/target/release/bundle/macos/Annotator.app"
