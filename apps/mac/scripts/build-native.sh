#!/usr/bin/env bash
# Builds the Swift helper into build/helpers/annotator-native.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/vm-build-cleanup.sh
trap 'vm_build_cleanup "$?" "$PWD/build/swift-native"' EXIT
swift build --package-path native --scratch-path build/swift-native -c release
mkdir -p build/helpers
cp build/swift-native/release/AnnotatorNative build/helpers/annotator-native
codesign --force --sign - --identifier com.nckrtl.annotator.native build/helpers/annotator-native
