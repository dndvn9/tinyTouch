#!/bin/bash
# Supply the extracted release bundle built from this checkout.
set -euo pipefail
cli=${1:?Usage: build.sh CLI_BUNDLE_DIRECTORY OUTPUT_APP}
app=${2:?Provide a new output path ending in .app}
[[ "$app" == *.app && ! -e "$app" && -x "$cli/tinytouch" && -d "$cli/_internal" ]]
src=$(cd "$(dirname "$0")" && pwd)
version=$(cat "$src/../../VERSION")
[[ "$("$cli/tinytouch" --version | tail -1)" == "tinyTouch CLI $version" ]]
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
ditto "$cli" "$app/Contents/Resources/cli"
MACOSX_DEPLOYMENT_TARGET=13.0 xcrun swiftc -O -parse-as-library "$src/Manager.swift" -o "$app/Contents/MacOS/tinyTouch"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.tinytouch.manager</string>
<key>CFBundleName</key><string>tinyTouch</string>
<key>CFBundleExecutable</key><string>tinyTouch</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign --force --sign "${TINYTOUCH_SIGNING_IDENTITY:--}" "$app"
codesign --verify --deep --strict "$app"
