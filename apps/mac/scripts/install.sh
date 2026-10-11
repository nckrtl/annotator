#!/usr/bin/env bash
# Builds, signs and installs /Applications/Annotator.app, then starts it.
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-app.sh
built=src-tauri/target/release/bundle/macos/Annotator.app
osascript -e 'quit app id "com.nckrtl.annotator"' 2>/dev/null || true
pkill -x Annotator 2>/dev/null || true
pkill -f '/Annotator.app/Contents/MacOS/annotator$' 2>/dev/null || true
sleep 1
rm -rf /Applications/Annotator.app
ditto "$built" /Applications/Annotator.app
codesign --verify --deep --strict /Applications/Annotator.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/$built" || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Annotator.app
open /Applications/Annotator.app
echo "Installed and started /Applications/Annotator.app"
