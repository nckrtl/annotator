#!/usr/bin/env bash
# Builds, signs and installs /Applications/Annotator.app, then starts it.
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-app.sh
built=build/release/Annotator.app
# AppKit targets only the installed host executable, even on the old helper layout.
for executable in Annotator annotator; do
  pids=$(osascript -l JavaScript scripts/quit-installed-app.js \
    "/Applications/Annotator.app/Contents/MacOS/$executable")
  for pid in $pids; do
    for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$pid" 2>/dev/null; then
      echo "Annotator PID $pid did not quit; keeping the installed app." >&2
      exit 1
    fi
  done
done
rm -rf /Applications/Annotator.app
ditto "$built" /Applications/Annotator.app
codesign --verify --deep --strict /Applications/Annotator.app
helper=/Applications/Annotator.app/Contents/Helpers/AnnotatorNative.app
touch "$helper"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$helper" || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$helper"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/$built" || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Annotator.app
open /Applications/Annotator.app
echo "Installed and started /Applications/Annotator.app"
