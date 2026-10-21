#!/usr/bin/env bash
# All native app suites: capture helper, Rust services, Swift bridge and dictation.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tmp
export TMPDIR="$PWD/build/tmp"
swift test --package-path native --scratch-path build/swift-native
CARGO_TARGET_DIR="$PWD/build/rust" cargo test --manifest-path src-tauri/Cargo.toml
swift test --package-path app --scratch-path build/swift-app

python3 scripts/test-install-bundle.py
