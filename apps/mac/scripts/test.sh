#!/usr/bin/env bash
# All native app suites: capture helper, Rust services, Swift bridge and dictation.
set -euo pipefail
cd "$(dirname "$0")/.."
swift test --package-path native
cargo test --manifest-path src-tauri/Cargo.toml
swift test --package-path app
