#!/bin/bash
# Builds a standalone Portside.app bundle from the SPM release binary, with
# Sparkle embedded for auto-updates. Works with Command Line Tools alone.
#
# Version/build come from the environment so the release script can set them:
#   PORTSIDE_VERSION (marketing, e.g. 0.2.0)   default 0.1.0
#   PORTSIDE_BUILD   (monotonic integer)       default 1
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${PORTSIDE_VERSION:-0.1.0}"
BUILD="${PORTSIDE_BUILD:-1}"
FEED_URL="https://github.com/mcglothi/portside/releases/latest/download/appcast.xml"
PUBLIC_ED_KEY="qYFGdTHUVnsLPyvyE495CVmbZ4UeSbdGM3+No7pLquI="

swift build -c release

APP=build/Portside.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp .build/release/Portside "$APP/Contents/MacOS/Portside"

# Embed Sparkle.framework (with its XPC helpers) and point the binary at it.
FRAMEWORK_SRC="$(find .build/artifacts -type d -path '*macos-arm64_x86_64/Sparkle.framework' | head -1)"
if [ -z "$FRAMEWORK_SRC" ]; then
    echo "error: Sparkle.framework not found — run 'swift build' first" >&2
    exit 1
fi
ditto "$FRAMEWORK_SRC" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Portside" 2>/dev/null || true

if [ ! -f build/AppIcon.icns ]; then
    swift Scripts/generate_icon.swift
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
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
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 Tim McGlothin</string>
    <key>SUFeedURL</key>
    <string>${FEED_URL}</string>
    <key>SUPublicEDKey</key>
    <string>${PUBLIC_ED_KEY}</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <integer>86400</integer>
</dict>
</plist>
PLIST

# Sign nested code first (framework + its XPC/helper apps), then the app.
codesign --force --deep --sign - "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$APP"
echo "Built $APP (version ${VERSION}, build ${BUILD})"
