#!/usr/bin/env bash
# One-off: moves the Swift app's settings from UserDefaults to the Tauri app's files.
# Reads `defaults export com.nckrtl.annotator -` and writes, in
# ~/Library/Application Support/com.nckrtl.annotator:
#   settings.json  the settings, with the shortcut's modifiers as Carbon flags
# An existing file stays unless you pass --force. Quit Annotator first.
set -euo pipefail

force=0
[[ "${1:-}" == "--force" ]] && force=1
target="$HOME/Library/Application Support/com.nckrtl.annotator"
mkdir -p "$target"

if [[ -e "$target/settings.json" && $force -eq 0 ]]; then
  echo "$target/settings.json exists. Pass --force to replace it." >&2
  exit 1
fi

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
for key in ["serverAutoStart", "serverURL", "operatorEnabled", "operatorAutoStart"]:
    if key in defaults:
        settings[key] = defaults[key]

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
PY
