#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
app_source="$PWD/build/Sony Headphone Control.app"
app_destination='/Applications/Sony Headphone Control.app'
if [[ ! -d "$app_source" ]]; then
  echo 'Build the app first: zsh build.sh' >&2
  exit 1
fi
codesign --verify --deep --strict "$app_source"
if [[ -d "$app_destination" ]]; then
  installed_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_destination/Contents/Info.plist")
  if [[ "$installed_id" != 'local.sonymenu.app' ]]; then
    echo 'A different app already occupies /Applications/Sony Headphone Control.app.' >&2
    exit 1
  fi
fi
# Rename the existing installation in place so file bookmarks can follow it.
# Keep the established bundle identifier and signing identity unchanged.
legacy_destination='/Applications/Sony Menu.app'
if [[ ! -e "$app_destination" && -d "$legacy_destination" ]]; then
  legacy_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$legacy_destination/Contents/Info.plist")
  if [[ "$legacy_id" == 'local.sonymenu.app' ]]; then
    mv -- "$legacy_destination" "$app_destination"
  fi
fi
ditto "$app_source" "$app_destination"
python3 Tools/verify-app.py "$app_destination"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app_destination"
echo "Installed: $app_destination"
