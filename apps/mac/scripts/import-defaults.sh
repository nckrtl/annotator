#!/usr/bin/env bash
# One-off: moves the Swift app's settings from UserDefaults to the Tauri app's files.
# Reads `defaults export com.nckrtl.annotator -` and writes, in
# ~/Library/Application Support/com.nckrtl.annotator:
#   settings.json  the settings, with the shortcut's modifiers as Carbon flags
#   sessions.json  the Conn sessions (the former t3Sessions value, unchanged)
# Existing files stay unless you pass --force. Quit Annotator first.
set -euo pipefail

force=0
[[ "${1:-}" == "--force" ]] && force=1
target="$HOME/Library/Application Support/com.nckrtl.annotator"
mkdir -p "$target"

for file in settings.json sessions.json; do
  if [[ -e "$target/$file" && $force -eq 0 ]]; then
    echo "$target/$file exists. Pass --force to replace it." >&2
    exit 1
  fi
done

plist="$(mktemp)"
trap 'rm -f "$plist"' EXIT
if ! defaults export com.nckrtl.annotator - >"$plist" 2>/dev/null; then
  echo "No settings for com.nckrtl.annotator in UserDefaults." >&2
  exit 1
fi

/usr/bin/python3 -I - "$plist" "$target" <<'PY'
import json, os, plistlib, sys

plist_path, target = sys.argv[1], sys.argv[2]
with open(plist_path, "rb") as f:
    defaults = plistlib.load(f)

settings = {}
for key in ["serverAutoStart", "serverURL", "ofideEnabled", "ofideAutoStart", "ofideURL", "ofideApp",
            "t3Enabled", "t3Endpoint", "t3Effort", "t3Home", "t3WindowHome", "t3Nudge", "t3DefaultModel"]:
    if key in defaults:
        settings[key] = defaults[key]

# The Swift app moved everyone to Opus 5.5 at medium effort once.
if not defaults.get("opus55DefaultApplied", False):
    settings["t3DefaultModel"] = "claudeAgent/claude-opus-5-5"
    settings["t3Effort"] = "medium"

# Swift stored the shortcut as JSON: {"keyCode", "modifiers" (control 1, option 2, shift 4, command 8), "key"}.
if "hotkey" in defaults:
    hotkey = json.loads(bytes(defaults["hotkey"]))
    swift = int(hotkey.get("modifiers", 0))
    carbon = 0
    for bit, flag in [(1, 1 << 12), (2, 1 << 11), (4, 1 << 9), (8, 1 << 8)]:
        if swift & bit:
            carbon |= flag
    settings["hotkey"] = {"keyCode": int(hotkey["keyCode"]), "modifiers": carbon}

def write(name, value):
    path = os.path.join(target, name)
    with open(path + ".tmp", "w") as f:
        json.dump(value, f, indent=2, ensure_ascii=False)
    os.replace(path + ".tmp", path)
    print("Wrote " + path)

write("settings.json", settings)
sessions = json.loads(bytes(defaults["t3Sessions"])) if "t3Sessions" in defaults else {}
write("sessions.json", sessions)
PY
