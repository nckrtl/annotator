#!/usr/bin/env bash
# Builds a native bundle. Default: release, signed with Nick's identity.
# --debug: a local ad-hoc bundle for testing; never installs it.
set -euo pipefail
cd "$(dirname "$0")/.."
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
cp build/helpers/annotator-native "$built/Contents/Resources/annotator-native"
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
  codesign --force --sign - --identifier com.nckrtl.annotator.native "$built/Contents/Resources/annotator-native"
  codesign --force --sign - "$built"
  codesign --verify --deep --strict "$built"
fi
printf 'Built %s\n' "$built"
