#!/bin/bash
# Builds a Finder-friendly drag-to-install disk image containing an app bundle
# and an Applications alias. The caller is responsible for signing/notarizing
# the app and, if desired, the resulting disk image.
#
#   Scripts/create_dmg.sh build/Portside.app build/Portside-0.7.0.dmg [Portside]
set -euo pipefail

APP="${1:?usage: create_dmg.sh <App.app> <output.dmg> [volume name]}"
OUTPUT="${2:?usage: create_dmg.sh <App.app> <output.dmg> [volume name]}"
VOLUME_NAME="${3:-Portside}"

if [ ! -d "$APP" ]; then
    echo "error: app bundle not found: $APP" >&2
    exit 1
fi

STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/portside-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT
STAGING="$STAGING_ROOT/staging"
mkdir -p "$STAGING"

# This is the established macOS direct-distribution convention: Finder shows
# Portside.app next to an Applications alias so installation is drag-and-drop.
ditto "$APP" "$STAGING/$(basename "$APP")"
ln -s /Applications "$STAGING/Applications"

mkdir -p "$(dirname "$OUTPUT")"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov "$OUTPUT"

echo "Built $OUTPUT"
