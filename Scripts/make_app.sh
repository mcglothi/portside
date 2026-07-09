#!/bin/bash
# Builds a standalone Portside.app bundle from the SPM release binary.
# Works with Command Line Tools alone — no full Xcode required.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/Portside.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Portside "$APP/Contents/MacOS/Portside"

if [ ! -f build/AppIcon.icns ]; then
    swift Scripts/generate_icon.swift
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Portside</string>
    <key>CFBundleIdentifier</key>
    <string>net.timmcg.portside</string>
    <key>CFBundleName</key>
    <string>Portside</string>
    <key>CFBundleDisplayName</key>
    <string>Portside</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 Tim McGlothin</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
