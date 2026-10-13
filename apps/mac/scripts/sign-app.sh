#!/usr/bin/env bash
# Signs a built Annotator.app inside out: the helper, then the app.
#   scripts/sign-app.sh <app>
set -euo pipefail
app=${1:?usage: sign-app.sh <app>}
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/scripts/signing.sh"
require_signing_identity
entitlements=$root/src-tauri/Entitlements.plist
# Over SSH the login keychain is locked and codesign fails with errSecInternalComponent.
# Run `security unlock-keychain ~/Library/Keychains/login.keychain-db` first, or sign locally.
codesign --force --options runtime --sign "$ANNOTATOR_SIGNING_IDENTITY" --identifier com.nckrtl.annotator.native \
  "$app/Contents/Resources/annotator-native"
codesign --force --options runtime --sign "$ANNOTATOR_SIGNING_IDENTITY" --entitlements "$entitlements" "$app"
codesign --verify --deep --strict "$app"
