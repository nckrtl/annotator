#!/usr/bin/env bash
# Signs the helper and Rust core, then the SwiftUI app.
#   scripts/sign-app.sh <app>
set -euo pipefail
app=${1:?usage: sign-app.sh <app>}
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/scripts/signing.sh"
require_signing_identity
entitlements=$root/src-tauri/Entitlements.plist
unlock_signing_keychain
codesign --force --options runtime --sign "$ANNOTATOR_SIGNING_IDENTITY" --identifier com.nckrtl.annotator.native \
  "$app/Contents/Resources/annotator-native"
codesign --force --options runtime --sign "$ANNOTATOR_SIGNING_IDENTITY" --identifier com.nckrtl.annotator.core \
  "$app/Contents/Resources/annotator-core"
codesign --force --options runtime --sign "$ANNOTATOR_SIGNING_IDENTITY" --entitlements "$entitlements" "$app"
codesign --verify --deep --strict "$app"
