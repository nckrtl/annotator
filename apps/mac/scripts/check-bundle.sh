#!/usr/bin/env bash
# Check the helper's LaunchServices identity and inside-out signatures.
set -euo pipefail
app=${1:?usage: check-bundle.sh <Annotator.app>}
helper=$app/Contents/Helpers/AnnotatorNative.app
for pair in CFBundleIdentifier:com.nckrtl.annotator.native CFBundleExecutable:annotator-native CFBundlePackageType:APPL LSUIElement:true CFBundleIconFile:Annotator; do
  key=${pair%%:*}; expected=${pair#*:}
  actual=$(/usr/libexec/PlistBuddy -c "Print :$key" "$helper/Contents/Info.plist")
  [[ $actual == "$expected" ]] || { echo "Unexpected helper $key: $actual" >&2; exit 1; }
done
cmp "$app/Contents/Resources/Annotator.icns" "$helper/Contents/Resources/Annotator.icns"
[[ -x $helper/Contents/MacOS/annotator-native && ! -e $app/Contents/Resources/annotator-native ]]
for pair in "$app:com.nckrtl.annotator" "$helper:com.nckrtl.annotator.native" "$app/Contents/Resources/annotator-core:com.nckrtl.annotator.core"; do
  signature=$(codesign -dvv "${pair%:*}" 2>&1)
  grep -qx "Identifier=${pair##*:}" <<<"$signature"
  codesign --verify --strict "${pair%:*}"
done
codesign --verify --deep --strict "$app"
echo 'App and helper identities and signatures verified.'
