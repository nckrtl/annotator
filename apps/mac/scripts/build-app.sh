#!/usr/bin/env bash
# Builds a native bundle. Default: release, signed with Nick's identity.
# --debug: a local ad-hoc bundle for testing; never installs it.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/vm-build-cleanup.sh
trap 'vm_build_cleanup "$?" "$PWD/build/swift-app" "$PWD/build/rust" "$PWD/build/swift-native"' EXIT
configuration=release
if [[ ${1:-} == --debug ]]; then configuration=debug; fi
if [[ $configuration == release ]]; then
  source scripts/signing.sh
  require_signing_identity
fi
swift build --package-path app --scratch-path build/swift-app -c "$configuration"
bash scripts/build-native.sh
if [[ $configuration == release ]]; then
  CARGO_TARGET_DIR="$PWD/build/rust" cargo build --manifest-path src-tauri/Cargo.toml --release
else
  CARGO_TARGET_DIR="$PWD/build/rust" cargo build --manifest-path src-tauri/Cargo.toml
fi
built="build/$configuration/Annotator.app"
mkdir -p "$built/Contents/MacOS" "$built/Contents/Resources"
bin=$(swift build --package-path app --scratch-path build/swift-app -c "$configuration" --show-bin-path)
cp "$bin/Annotator" "$built/Contents/MacOS/Annotator"
cp build/rust/"$configuration"/annotator "$built/Contents/Resources/annotator-core"
helper="$built/Contents/Helpers/AnnotatorNative.app"
mkdir -p "$helper/Contents/MacOS"
cp native/Helper-Info.plist "$helper/Contents/Info.plist"
cp build/helpers/annotator-native "$helper/Contents/MacOS/annotator-native"
rm -f "$built/Contents/Resources/annotator-native"
cp src-tauri/icons/icon.icns "$built/Contents/Resources/Annotator.icns"
# SwiftPM's Xcode build backend emits resource bundles beside the executable.
for bundle in "$bin"/*.bundle; do
  [[ -e "$bundle" ]] || continue
  ditto "$bundle" "$built/Contents/Resources/$(basename "$bundle")"
done
cp app/Info.plist "$built/Contents/Info.plist"
if [[ $configuration == release ]]; then
  bash scripts/sign-app.sh "$built"
else
  codesign --force --sign - --identifier com.nckrtl.annotator.core "$built/Contents/Resources/annotator-core"
  codesign --force --sign - --identifier com.nckrtl.annotator.native "$helper"
  codesign --force --sign - "$built"
  codesign --verify --deep --strict "$built"
fi
printf 'Built %s\n' "$built"

bash scripts/check-bundle.sh "$built"
