#!/usr/bin/env bash
# The caller builds and quits the installed app first. Never keep a backup .app:
# LaunchServices can use its filename and old icon for the live app's TCC entry.
set -euo pipefail
source_app=${1:?usage: install-bundle.sh <built-app> <installed-app> <backup.zip>}
installed_app=${2:?}
backup=${3:?}
lsregister=${ANNOTATOR_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}
[[ $source_app != "$installed_app" && $installed_app == */Annotator.app && $backup == *.zip ]]
codesign --verify --deep --strict "$source_app"
if [[ -d $installed_app ]]; then
  # A valid signature alone is not enough: a different requirement loses TCC grants.
  for relative in '' /Contents/Helpers/AnnotatorNative.app /Contents/Resources/annotator-core; do
    previous=$(codesign -d -r- "$installed_app$relative" 2>&1 | sed -n 's/^designated => //p')
    candidate=$(codesign -d -r- "$source_app$relative" 2>&1 | sed -n 's/^designated => //p')
    if [[ -z $previous || $previous != "$candidate" ]]; then
      echo "Signing requirement changed for ${relative:-Annotator.app}; keeping the installed app and its permissions." >&2
      exit 1
    fi
  done
fi
mkdir -p "$(dirname "$backup")"
had_previous=false
if [[ -d $installed_app ]]; then
  # Complete and verify the archive before touching the installed app or older archive.
  ditto -c -k --sequesterRsrc --keepParent "$installed_app" "$backup.partial"
  unzip -tq "$backup.partial" >/dev/null
  mv -f "$backup.partial" "$backup"
  had_previous=true
fi
unregister() {
  local app=$1
  [[ ! -d $app/Contents/Helpers/AnnotatorNative.app ]] || "$lsregister" -u "$app/Contents/Helpers/AnnotatorNative.app" || true
  "$lsregister" -u "$app" || true
}
register() {
  local app=$1
  touch "$app" "$app/Contents/Helpers/AnnotatorNative.app"
  "$lsregister" -f "$app/Contents/Helpers/AnnotatorNative.app"
  "$lsregister" -f "$app"
}
rollback() {
  local status=$?
  trap - EXIT
  if [[ $status != 0 ]]; then
    unregister "$installed_app"
    rm -rf "$installed_app"
    if $had_previous; then
      ditto -x -k "$backup" "$(dirname "$installed_app")"
      register "$installed_app"
      echo "Install failed; restored $installed_app from $backup" >&2
    fi
  fi
  exit "$status"
}
unregister "$installed_app"
unregister "$source_app"
trap rollback EXIT
rm -rf "$installed_app"
ditto "$source_app" "$installed_app"
codesign --verify --deep --strict "$installed_app"
register "$installed_app"
trap - EXIT
