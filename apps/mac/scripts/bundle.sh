#!/bin/bash
# Builds build/Annotator.app and signs it with a stable identity,
# so macOS keeps the Accessibility and Screen Recording grants.
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="${1:-release}"
case "$configuration" in
    release|debug) ;;
    *) echo "Usage: $0 [release|debug]" >&2; exit 1 ;;
esac

identity="${SIGNING_IDENTITY:-Apple Development: Nick Retel (G9Y9TT23QF)}"
if ! security find-identity -v -p codesigning | grep -qF "\"$identity\""; then
    echo "error: signing identity not found: $identity" >&2
    echo "Set SIGNING_IDENTITY to one of:" >&2
    security find-identity -v -p codesigning >&2
    exit 1
fi

entitlements=Resources/Annotator.entitlements
if [[ "$configuration" == debug ]]; then
    if [[ ! -d /Applications/InjectionNext.app ]]; then
        echo "Install InjectionNext in /Applications first. See DEVELOPMENT.md." >&2
        exit 1
    fi
    mkdir -p build
    echo "Building for live reload (log: build/dev-build.log)…"
    if ! xcodebuild -scheme Annotator -configuration Debug -destination 'platform=macOS' \
        -derivedDataPath build/InjectionDerivedData EMIT_FRONTEND_COMMAND_LINES=YES \
        COMPILATION_CACHE_ENABLE_CACHING=NO build > build/dev-build.log 2>&1; then
        tail -80 build/dev-build.log >&2
        exit 1
    fi
    binary=build/InjectionDerivedData/Build/Products/Debug/Annotator
    entitlements=Resources/AnnotatorDev.entitlements
else
    swift build -c release
    binary="$(swift build -c release --show-bin-path)/Annotator"
fi

app=build/Annotator.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/Annotator"
cp Resources/Info.plist "$app/Contents/Info.plist"
version="$(git describe --tags --always --dirty 2>/dev/null || echo 0.0.0)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"

# Over SSH the login keychain is locked and codesign fails with errSecInternalComponent.
# Run `security unlock-keychain ~/Library/Keychains/login.keychain-db` first, or sign locally.
codesign --force --options runtime --entitlements "$entitlements" --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
echo "Built and signed $app ($version, $configuration)"
