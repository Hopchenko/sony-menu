#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
app_path="$PWD/build/Sony Menu.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
swiftc -swift-version 5 -parse-as-library -O -module-cache-path /private/tmp/sony-menu-module-cache \
  -target arm64-apple-macosx14.0 Sources/SonyMenu/*.swift Sources/SonyMenu/Protocol/*.swift \
  -o "$app_path/Contents/MacOS/SonyMenu" \
  -framework AppKit -framework SwiftUI -framework IOBluetooth -framework ServiceManagement -framework CoreAudio
cp Resources/Info.plist "$app_path/Contents/Info.plist"
cp Resources/Headphones.png Resources/ThirdPartyNotices.txt "$app_path/Contents/Resources/"
codesign --force --sign - --identifier local.sonymenu.app "$app_path"
echo "Built: $app_path"
