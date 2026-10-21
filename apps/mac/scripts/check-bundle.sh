#!/usr/bin/env bash
# Check host/helper LaunchServices metadata, supplied icons and inside-out signatures.
set -euo pipefail
app=${1:?usage: check-bundle.sh <Annotator.app>}
helper=$app/Contents/Helpers/AnnotatorNative.app
for pair in CFBundleIdentifier:com.nckrtl.annotator CFBundleExecutable:Annotator CFBundleName:Annotator CFBundleDisplayName:Annotator CFBundlePackageType:APPL LSUIElement:true CFBundleIconFile:Annotator; do
  key=${pair%%:*}; expected=${pair#*:}
  actual=$(/usr/libexec/PlistBuddy -c "Print :$key" "$app/Contents/Info.plist")
  [[ $actual == "$expected" ]] || { echo "Unexpected app $key: $actual" >&2; exit 1; }
done
for pair in CFBundleIdentifier:com.nckrtl.annotator.native CFBundleExecutable:annotator-native CFBundlePackageType:APPL LSUIElement:true CFBundleIconFile:Annotator; do
  key=${pair%%:*}; expected=${pair#*:}
  actual=$(/usr/libexec/PlistBuddy -c "Print :$key" "$helper/Contents/Info.plist")
  [[ $actual == "$expected" ]] || { echo "Unexpected helper $key: $actual" >&2; exit 1; }
done
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$helper/Contents/Info.plist") == 'Annotator Capture' ]]
cmp "$(dirname "$0")/../src-tauri/icons/icon.icns" "$app/Contents/Resources/Annotator.icns"
cmp "$app/Contents/Resources/Annotator.icns" "$helper/Contents/Resources/Annotator.icns"
for bundle in "$app" "$helper"; do
  [[ ! -e $bundle/Contents/Resources/icon.icns && ! -e $bundle/Contents/Resources/Assets.car ]]
  if /usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$bundle/Contents/Info.plist" >/dev/null 2>&1; then
    echo 'App icons must use the supplied .icns, not an asset catalog.' >&2; exit 1
  fi
done
[[ -x $helper/Contents/MacOS/annotator-native && ! -e $app/Contents/Resources/annotator-native ]]
for pair in "$app:com.nckrtl.annotator" "$helper:com.nckrtl.annotator.native" "$app/Contents/Resources/annotator-core:com.nckrtl.annotator.core"; do
  signature=$(codesign -dvv "${pair%:*}" 2>&1)
  grep -qx "Identifier=${pair##*:}" <<<"$signature"
  codesign --verify --strict "${pair%:*}"
done
codesign --verify --deep --strict "$app"
echo 'App and helper identities and signatures verified.'
