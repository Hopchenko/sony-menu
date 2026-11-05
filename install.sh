#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
app_source="$PWD/build/Sony Menu.app"
app_destination='/Applications/Sony Menu.app'
if [[ ! -d "$app_source" ]]; then
  echo 'Build the app first: zsh build.sh' >&2
  exit 1
fi
codesign --verify --deep --strict "$app_source"
if [[ -d "$app_destination" ]]; then
  installed_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_destination/Contents/Info.plist")
  if [[ "$installed_id" != 'local.sonymenu.app' ]]; then
    echo 'A different app already occupies /Applications/Sony Menu.app.' >&2
    exit 1
  fi
fi
ditto "$app_source" "$app_destination"
codesign --verify --deep --strict "$app_destination"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app_destination"
echo "Installed: $app_destination"
