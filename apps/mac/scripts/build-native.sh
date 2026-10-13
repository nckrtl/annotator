#!/usr/bin/env bash
# Builds the Swift helper into src-tauri/binaries/annotator-native.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --package-path native -c release
mkdir -p src-tauri/binaries
cp native/.build/release/AnnotatorNative src-tauri/binaries/annotator-native
codesign --force --sign - --identifier com.nckrtl.annotator.native src-tauri/binaries/annotator-native
