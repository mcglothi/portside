#!/bin/bash
# Cuts a Sparkle-updatable release: builds the bundle, zips it, signs it with
# the EdDSA key (from the Keychain), generates the appcast, and publishes both
# to GitHub Releases. Installed apps poll the appcast and update themselves.
#
#   Scripts/release.sh <version> [release notes]
#   e.g. Scripts/release.sh 0.2.1 "Fix SFTP drag-out filename"
#
# Prereqs: `gh auth login` done; EdDSA key present (Scripts/generate_keys once).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: release.sh <version> [notes]}"
NOTES="${2:-Portside $VERSION}"
BUILD="$(git rev-list --count HEAD)"          # monotonic build number
REPO="mcglothi/portside"
SPARKLE_BIN="$(find .build/artifacts -type d -path '*Sparkle/bin' | head -1)"

if [ -z "$SPARKLE_BIN" ]; then
    echo "error: Sparkle tools not found — run 'swift build' first" >&2
    exit 1
fi

echo "==> Building Portside $VERSION (build $BUILD)"
PORTSIDE_VERSION="$VERSION" PORTSIDE_BUILD="$BUILD" ./Scripts/make_app.sh

echo "==> Packaging"
rm -rf build/updates
mkdir -p build/updates
ZIP="build/updates/Portside-$VERSION.zip"
DMG="build/Portside-$VERSION.dmg"
ditto -c -k --keepParent build/Portside.app "$ZIP"

# Notarization (only when set up). Requires make_app to have Developer-ID
# signed the app (PORTSIDE_SIGN_IDENTITY). Submit the zip, staple the ticket
# onto the .app, then re-zip so the distributed archive carries the ticket.
NOTARY_PROFILE="${PORTSIDE_NOTARY_PROFILE:-}"
if [ -n "$NOTARY_PROFILE" ]; then
    echo "==> Notarizing (profile: $NOTARY_PROFILE)"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    echo "==> Stapling ticket"
    xcrun stapler staple build/Portside.app
    rm "$ZIP"
    ditto -c -k --keepParent build/Portside.app "$ZIP"
else
    echo "==> Skipping notarization (set PORTSIDE_NOTARY_PROFILE + PORTSIDE_SIGN_IDENTITY to enable)"
fi

# The ZIP remains the Sparkle/Homebrew artifact. The DMG is a separate,
# Finder-friendly direct download with the conventional Applications alias.
./Scripts/create_dmg.sh build/Portside.app "$DMG" "Portside"
if [ -n "$NOTARY_PROFILE" ]; then
    echo "==> Notarizing disk image"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    echo "==> Stapling disk image"
    xcrun stapler staple "$DMG"
fi

echo "==> Writing changelog for Sparkle update UI"
# generate_appcast embeds Portside-$VERSION.md as this release's appcast
# description (matched by basename against the .zip above). Since users often
# auto-update across several skipped versions, the description is the last
# CHANGELOG_LIMIT entries of CHANGELOG.md (newest first), not just this
# version's own notes — so scrolling down covers everything they missed.
CHANGELOG_LIMIT=15
awk -v limit="$CHANGELOG_LIMIT" '
    /^## / { n++ }
    n == 0 { next }
    n > limit { exit }
    { print }
' CHANGELOG.md > "build/updates/Portside-$VERSION.md"

echo "==> Signing + generating appcast"
"$SPARKLE_BIN/generate_appcast" \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
    build/updates/

# Keep the DMG out of generate_appcast: Sparkle consumes the ZIP enclosure.
mv "$DMG" "build/updates/Portside-$VERSION.dmg"

echo "==> Publishing GitHub release v$VERSION"
gh release create "v$VERSION" \
    "build/updates/Portside-$VERSION.zip" \
    "build/updates/Portside-$VERSION.dmg" \
    "build/updates/appcast.xml" \
    "build/updates/Portside-$VERSION.md" \
    --repo "$REPO" \
    --title "Portside $VERSION" \
    --notes "$NOTES"

echo "==> Done. Installed apps will see v$VERSION on their next update check."
echo "    Reinstall locally with: cp -R build/Portside.app /Applications/"
echo "    Homebrew cask bump:     version \"$VERSION\" / sha256 \"$(shasum -a 256 "$ZIP" | cut -d' ' -f1)\""
