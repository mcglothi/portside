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

echo "==> Signing + generating appcast"
"$SPARKLE_BIN/generate_appcast" \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
    build/updates/

echo "==> Publishing GitHub release v$VERSION"
gh release create "v$VERSION" \
    "build/updates/Portside-$VERSION.zip" \
    "build/updates/appcast.xml" \
    --repo "$REPO" \
    --title "Portside $VERSION" \
    --notes "$NOTES"

echo "==> Done. Installed apps will see v$VERSION on their next update check."
echo "    Reinstall locally with: cp -R build/Portside.app /Applications/"
echo "    Homebrew cask bump:     version \"$VERSION\" / sha256 \"$(shasum -a 256 "$ZIP" | cut -d' ' -f1)\""
