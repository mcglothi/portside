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

# SPM resource bundle (bundled themes etc.); TerminalTheme.resourceBundle
# looks for it in Contents/Resources. (Not Bundle.module — SwiftPM's generated
# accessor for executables checks the .app root and the build machine's
# absolute .build path, then fatalErrors; see the 0.7.0 Settings crash.)
ditto .build/release/Portside_Portside.bundle "$APP/Contents/Resources/Portside_Portside.bundle"

# SwiftTerm's Metal shader bundle. Its renderer (as of 1.15.0, our upstream
# fix in migueldeicaza/SwiftTerm#593) probes Bundle.main.resourceURL for this
# alongside its other candidates, so it belongs in Contents/Resources too.
ditto .build/release/SwiftTerm_SwiftTerm.bundle "$APP/Contents/Resources/SwiftTerm_SwiftTerm.bundle"

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
    <key>NSLocalNetworkUsageDescription</key>
    <string>Portside needs local network access to reach mosh servers over UDP on hosts you connect to.</string>
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

# Signing. If PORTSIDE_SIGN_IDENTITY is set (a "Developer ID Application"
# identity), sign with the hardened runtime so the app can be notarized —
# that's what removes the Gatekeeper block for people who download it.
# Otherwise fall back to ad-hoc (local/personal; updates trusted via Sparkle's
# EdDSA signature). Sign nested code first, then the app.
SIGN_IDENTITY="${PORTSIDE_SIGN_IDENTITY:-}"
if [ -n "$SIGN_IDENTITY" ]; then
    # Sparkle's documented order: its nested XPC services and helpers first
    # (--deep is deprecated and mis-signs them), then the framework, then us.
    SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
    # XPC services only exist in sandboxed distributions; SPM's is empty.
    for XPC in "$SPARKLE/Versions/B/XPCServices/"*.xpc; do
        [ -e "$XPC" ] || continue
        codesign --force --options runtime --preserve-metadata=entitlements \
            --sign "$SIGN_IDENTITY" "$XPC"
    done
    codesign --force --options runtime --sign "$SIGN_IDENTITY" \
        "$SPARKLE/Versions/B/Autoupdate"
    codesign --force --options runtime --sign "$SIGN_IDENTITY" \
        "$SPARKLE/Versions/B/Updater.app"
    codesign --force --options runtime --sign "$SIGN_IDENTITY" "$SPARKLE"
    codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP"
    echo "Built $APP (version ${VERSION}, build ${BUILD}) — Developer ID: $SIGN_IDENTITY"
else
    codesign --force --deep --sign - "$APP/Contents/Frameworks/Sparkle.framework"
    codesign --force --sign - "$APP"
    echo "Built $APP (version ${VERSION}, build ${BUILD}) — ad-hoc signed"
fi
