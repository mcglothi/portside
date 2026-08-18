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

# ---------------------------------------------------------------------------
# Release gate.
#
# The build compiles whatever is in the working tree, but `gh release create`
# tags whatever the remote's default branch points at. Those are different
# things, and nothing used to check they agreed: v0.14.0 shipped a correct
# binary under a tag pointing at the previous release's source, and had to be
# repaired with a force-moved tag afterwards. Treating "commit and push first"
# as a habit rather than a precondition is what allowed that.
#
# Every check can be waived with PORTSIDE_ALLOW_UNSAFE_RELEASE=1, which prints
# loudly. Nothing here is a judgement call the script should make silently.
# ---------------------------------------------------------------------------
UNSAFE="${PORTSIDE_ALLOW_UNSAFE_RELEASE:-}"

gate_fail() {
    if [ -n "$UNSAFE" ]; then
        echo "warning: $1 (overridden by PORTSIDE_ALLOW_UNSAFE_RELEASE)" >&2
    else
        echo "error: $1" >&2
        echo "       Fix it, or re-run with PORTSIDE_ALLOW_UNSAFE_RELEASE=1 to override." >&2
        exit 1
    fi
}

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
DEFAULT_BRANCH="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || echo main)"

# 1. Clean tree: anything uncommitted is in the build but not in the tag.
if [ -n "$(git status --porcelain)" ]; then
    git status --short >&2
    gate_fail "working tree is dirty — the build would contain changes the tag does not"
fi

# 2. On the branch the release will be tagged against.
if [ "$BRANCH" != "$DEFAULT_BRANCH" ]; then
    gate_fail "on branch '$BRANCH' but the release tags '$DEFAULT_BRANCH' — merge first"
fi

# 3. HEAD actually pushed, so the tag resolves to the source that was built.
#
# A failed fetch used to be swallowed (`|| true`), which meant the very next
# check could pass by comparing against a *stale* cached origin/$DEFAULT_BRANCH
# from a previous fetch — exactly the "tag points at different code than what
# was built" failure mode this gate exists to catch, just moved one step
# earlier. A fetch failure gets no benefit of the doubt.
if ! git fetch --quiet origin "$DEFAULT_BRANCH"; then
    gate_fail "git fetch origin $DEFAULT_BRANCH failed — check network/auth before releasing"
fi
LOCAL_HEAD="$(git rev-parse HEAD)"
REMOTE_HEAD="$(git rev-parse "origin/$DEFAULT_BRANCH" 2>/dev/null || echo none)"
if [ "$LOCAL_HEAD" != "$REMOTE_HEAD" ]; then
    echo "       local  HEAD: $LOCAL_HEAD" >&2
    echo "       origin HEAD: $REMOTE_HEAD" >&2
    gate_fail "HEAD is not what origin/$DEFAULT_BRANCH points at — push before releasing"
fi

# 4. Version not already released.
if git rev-parse "v$VERSION" >/dev/null 2>&1; then
    gate_fail "tag v$VERSION already exists"
fi

# 5. Signed and notarized, or explicitly acknowledged. An ad-hoc build published
#    to the appcast is one users cannot launch without Gatekeeper warnings.
if [ -z "${PORTSIDE_SIGN_IDENTITY:-}" ]; then
    gate_fail "PORTSIDE_SIGN_IDENTITY is not set — this would publish an ad-hoc signed build"
fi
if [ -z "${PORTSIDE_NOTARY_PROFILE:-}" ]; then
    gate_fail "PORTSIDE_NOTARY_PROFILE is not set — this would publish an unnotarized build"
fi

# 6. The changelog entry has to exist before the release notes are extracted.
if [ -f CHANGELOG.md ] && ! grep -q "^## $VERSION\b" CHANGELOG.md; then
    gate_fail "CHANGELOG.md has no '## $VERSION' section — add it before releasing"
fi

# 6b. The in-app About window reads a bundled copy of the changelog. Shipping a
# stale one would answer "what changed" confidently and wrongly.
if ! diff -q CHANGELOG.md Sources/Portside/Resources/CHANGELOG.md >/dev/null 2>&1; then
    gate_fail "Sources/Portside/Resources/CHANGELOG.md is out of date — cp CHANGELOG.md over it"
fi

if [ -n "$UNSAFE" ]; then
    echo "==> Release gate OVERRIDDEN — publishing anyway (branch $BRANCH @ ${LOCAL_HEAD:0:9})"
else
    echo "==> Release gate passed (branch $BRANCH @ ${LOCAL_HEAD:0:9}, signed + notarized)"
fi

# 7. Tests and the Swift 6 warning ratchet, before anything is packaged. CI
#    runs both; a release must not be the path that quietly skips the stricter
#    concurrency build.
if [ -z "$UNSAFE" ]; then
    echo "==> Running tests"
    swift test
    echo "==> Running Swift 6 strict-concurrency ratchet"
    Scripts/strict-concurrency-check.sh
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

echo "==> Writing artifact checksums"
CHECKSUMS="build/updates/Portside-$VERSION.SHA256SUMS.txt"
(cd build/updates && shasum -a 256 "Portside-$VERSION.zip" "Portside-$VERSION.dmg") > "$CHECKSUMS"

echo "==> Publishing GitHub release v$VERSION"
# --target pins the new tag to the exact commit gate #3 verified and this
# script built — not whatever origin/$DEFAULT_BRANCH happens to point at by
# the time this runs, which (unlike LOCAL_HEAD) could have moved during the
# build/notarization wait above. This is what actually closes the race the
# fetch check above only detects; without it, tag creation still trusted the
# branch tip at publish time.
gh release create "v$VERSION" \
    "build/updates/Portside-$VERSION.zip" \
    "build/updates/Portside-$VERSION.dmg" \
    "build/updates/appcast.xml" \
    "build/updates/Portside-$VERSION.md" \
    "$CHECKSUMS" \
    --repo "$REPO" \
    --title "Portside $VERSION" \
    --notes "$NOTES" \
    --target "$LOCAL_HEAD"

# Belt-and-suspenders: read the tag back from GitHub and confirm it actually
# landed on the built commit. --target above should make this unconditionally
# true; this exists to catch it loudly if it somehow isn't, rather than
# leaving a mismatched tag to be discovered later by a user's bug report.
echo "==> Verifying the published tag resolves to the built commit"
git fetch --quiet origin "refs/tags/v$VERSION:refs/tags/v$VERSION-verify"
PUBLISHED_SHA="$(git rev-parse "v$VERSION-verify^{commit}")"
git tag -d "v$VERSION-verify" >/dev/null
if [ "$PUBLISHED_SHA" != "$LOCAL_HEAD" ]; then
    echo "error: published tag v$VERSION resolves to $PUBLISHED_SHA on GitHub," >&2
    echo "       not the built commit $LOCAL_HEAD. The release is already live —" >&2
    echo "       investigate and fix the tag (or yank the release) immediately." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Homebrew tap bump.
#
# The cask lives in a separate repo, so none of the gates above cover it — and
# printing the version/sha as a closing hint, which is what this used to do,
# left pushing them to memory. It was forgotten: the tap served 0.17.1 while
# Sparkle users were two releases ahead, so `brew upgrade` was quietly the
# stalest way to get Portside.
#
# Runs last, because the cask has to point at an asset that already exists. A
# failure here does not invalidate the release — it just leaves Homebrew users
# on the previous version — so it reports the values needed to finish by hand.
#
#   PORTSIDE_SKIP_TAP_BUMP=1  don't touch the tap
#   PORTSIDE_TAP_DRY_RUN=1    do everything except push
# ---------------------------------------------------------------------------
TAP_REPO="${PORTSIDE_TAP_REPO:-mcglothi/homebrew-tap}"
TAP_CASK="Casks/portside.rb"
TAP_DIR=""
PUBLISHED_ZIP=""
cleanup_tap() { [ -n "$TAP_DIR" ] && rm -rf "$TAP_DIR"; [ -n "$PUBLISHED_ZIP" ] && rm -f "$PUBLISHED_ZIP"; return 0; }
trap cleanup_tap EXIT

tap_fail() {
    echo "error: $1" >&2
    echo "       The v$VERSION release itself is live and unaffected. Homebrew users stay" >&2
    echo "       on the previous version until the cask is bumped by hand:" >&2
    echo "         $TAP_REPO  $TAP_CASK" >&2
    echo "         version \"$VERSION\"" >&2
    echo "         sha256 \"${PUBLISHED_SHA256:-<sha256 of the published zip>}\"" >&2
    exit 1
}

if [ -n "${PORTSIDE_SKIP_TAP_BUMP:-}" ]; then
    echo "==> Skipping Homebrew tap bump (PORTSIDE_SKIP_TAP_BUMP set)"
else
    echo "==> Bumping the Homebrew tap ($TAP_REPO)"

    # Hash the asset as GitHub is serving it, not the local file. They should be
    # identical; if they ever aren't, a cask built from the local zip would
    # carry a checksum `brew` can never match, and that surfaces as a baffling
    # checksum error for a user instead of a loud failure here. Downloading it
    # doubles as proof the upload survived intact.
    PUBLISHED_ZIP="$(mktemp -t portside-published)"
    if ! curl -fsSL -o "$PUBLISHED_ZIP" \
        "https://github.com/$REPO/releases/download/v$VERSION/Portside-$VERSION.zip"; then
        tap_fail "could not download the published zip to verify its checksum"
    fi
    PUBLISHED_SHA256="$(shasum -a 256 "$PUBLISHED_ZIP" | cut -d' ' -f1)"
    LOCAL_SHA256="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
    if [ "$PUBLISHED_SHA256" != "$LOCAL_SHA256" ]; then
        echo "       local:     $LOCAL_SHA256" >&2
        echo "       published: $PUBLISHED_SHA256" >&2
        tap_fail "the published zip is not the one just built — do not point the cask at it"
    fi

    TAP_DIR="$(mktemp -d -t portside-tap)"
    if ! git clone --quiet --depth 1 "git@github.com:$TAP_REPO.git" "$TAP_DIR"; then
        tap_fail "could not clone $TAP_REPO"
    fi
    [ -f "$TAP_DIR/$TAP_CASK" ] || tap_fail "$TAP_CASK not found in $TAP_REPO"

    # Anchored so only the cask's own two stanzas move; `url` interpolates
    # #{version} and must not be rewritten.
    sed -i.bak \
        -e "s|^  version \".*\"$|  version \"$VERSION\"|" \
        -e "s|^  sha256 \".*\"$|  sha256 \"$PUBLISHED_SHA256\"|" \
        "$TAP_DIR/$TAP_CASK"
    rm -f "$TAP_DIR/$TAP_CASK.bak"

    grep -q "^  version \"$VERSION\"$" "$TAP_DIR/$TAP_CASK" \
        || tap_fail "the version stanza in $TAP_CASK did not take the edit"
    grep -q "^  sha256 \"$PUBLISHED_SHA256\"$" "$TAP_DIR/$TAP_CASK" \
        || tap_fail "the sha256 stanza in $TAP_CASK did not take the edit"

    if git -C "$TAP_DIR" diff --quiet; then
        echo "    Cask already at $VERSION — nothing to push"
    elif [ -n "${PORTSIDE_TAP_DRY_RUN:-}" ]; then
        echo "    DRY RUN — would push:"
        git -C "$TAP_DIR" --no-pager diff
    else
        git -C "$TAP_DIR" add "$TAP_CASK"
        git -C "$TAP_DIR" commit --quiet -m "portside $VERSION"
        git -C "$TAP_DIR" push --quiet origin HEAD || tap_fail "could not push to $TAP_REPO"

        # Read it back: a push that lands on the wrong branch, or a tap with
        # branch protection that accepted nothing, both look like success above.
        REMOTE_VERSION="$(gh api "repos/$TAP_REPO/contents/$TAP_CASK" --jq '.content' \
            | base64 -d | sed -n 's|^  version "\(.*\)"$|\1|p')"
        [ "$REMOTE_VERSION" = "$VERSION" ] \
            || tap_fail "$TAP_REPO still serves version '$REMOTE_VERSION' after the push"
        echo "    Tap now serves $VERSION"
    fi
fi

echo "==> Done. Installed apps will see v$VERSION on their next update check."
echo "    Reinstall locally with: cp -R build/Portside.app /Applications/"
