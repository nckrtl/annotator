#!/bin/bash
# Start the signed development app. Save any open comment before running this.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"

scripts/bundle.sh debug
if ! pgrep -f '^/Applications/InjectionNext[.]app/Contents/MacOS/InjectionNext$' >/dev/null; then
    open -a /Applications/InjectionNext.app --env INJECTION_HIDE_XCODE_ALERT=1 \
        --env NSUnbufferedIO=YES \
        --stdout "$root/build/injection.log" --stderr "$root/build/injection.log"
fi

# Restart only this checkout's app, never another copy or the annotation server.
python3 - "$root/build/Annotator.app/Contents/MacOS/Annotator" <<'PY'
import os, signal, subprocess, sys, time
executable = sys.argv[1]
for line in subprocess.check_output(["ps", "-axo", "pid=,args="], text=True).splitlines():
    fields = line.strip().split(None, 1)
    if len(fields) != 2 or fields[1] != executable:
        continue
    pid = int(fields[0])
    os.kill(pid, signal.SIGTERM)
    for _ in range(50):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            break
        time.sleep(0.1)
    else:
        sys.exit("Annotator did not quit. Quit it before running scripts/dev.sh again.")
PY

: > "$root/build/dev.log"
open -n "$root/build/Annotator.app" \
    --env "INJECTION_PROJECT_ROOT=$root" \
    --env NSUnbufferedIO=YES \
    --stdout "$root/build/dev.log" --stderr "$root/build/dev.log"
python3 - "$root" <<'PY'
from pathlib import Path
import sys, time
root = Path(sys.argv[1])
for _ in range(100):
    if "Watching directory:" in (root / "build/dev.log").read_text(errors="replace"):
        # InjectionNext backdates its event stream on the first file event.
        # Prime it with a build marker so it does not consume the first source edit.
        marker = root / "build/injection-ready.tmp"
        marker.write_text(str(time.time()))
        marker.replace(root / "build/injection-ready")
        time.sleep(1)
        break
    time.sleep(0.1)
else:
    sys.exit("Live reload did not connect. See build/dev.log and build/injection.log.")
PY
echo "Live reload started. Edit Sources/Annotator/*.swift and save."
echo "App log: $root/build/dev.log"
