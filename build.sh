#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
python3 Tools/retire-development-apps.py
app_path="$PWD/build/Applications.noindex/Sony Headphone Control.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
swiftc -swift-version 5 -parse-as-library -O -module-cache-path /private/tmp/sony-menu-module-cache \
  -target arm64-apple-macosx14.0 Sources/SonyMenu/*.swift Sources/SonyMenu/Protocol/*.swift \
  -o "$app_path/Contents/MacOS/SonyMenu" \
  -framework AppKit -framework SwiftUI -framework IOBluetooth -framework ServiceManagement -framework CoreAudio
cp Resources/Info.plist "$app_path/Contents/Info.plist"
cp Resources/Headphones*.png Resources/ThirdPartyNotices.txt "$app_path/Contents/Resources/"
if [[ -f Resources/AppIcon.png ]]; then
  iconset_path="$PWD/build/AppIcon.iconset"
  mkdir -p "$iconset_path"
  for icon_size in 16 32 128 256 512; do
    sips -z "$icon_size" "$icon_size" Resources/AppIcon.png --out "$iconset_path/icon_${icon_size}x${icon_size}.png" >/dev/null
    retina_size=$((icon_size * 2))
    sips -z "$retina_size" "$retina_size" Resources/AppIcon.png --out "$iconset_path/icon_${icon_size}x${icon_size}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset_path" -o "$app_path/Contents/Resources/AppIcon.icns"
fi
if [[ -n "${SONY_MENU_SIGNING_IDENTITY:-}" ]]; then
  signing_identity="$SONY_MENU_SIGNING_IDENTITY"
else
  signing_identity=$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk '/"Sony Menu Local Signing"/ {print $2; exit}')
  signing_identity="${signing_identity:--}"
fi
# Runtime Finder icons are harmless metadata, but distribution signing requires
# a clean bundle. This directory contains generated build output only.
rm -f -- "$app_path/Icon"$'\r'
/usr/bin/xattr -d com.apple.FinderInfo "$app_path" 2>/dev/null || true
codesign --force --sign "$signing_identity" --timestamp=none --identifier local.sonymenu.app "$app_path"
echo "Built: $app_path"
