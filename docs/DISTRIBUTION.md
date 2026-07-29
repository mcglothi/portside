# Distributing Portside to other people

Portside releases should be **Developer ID signed and notarized** so they open
without a Gatekeeper exception. The release scripts support this distribution
path, while still allowing ad-hoc signing for local development builds.

## One-time setup

1. **Enroll** in the Apple Developer Program ($99/yr): <https://developer.apple.com/programs/>

2. **Create a "Developer ID Application" certificate** (Xcode → Settings →
   Accounts → Manage Certificates → +, or the Developer portal) and let it
   install into your login Keychain. Find its exact name:
   ```sh
   security find-identity -v -p codesigning
   # → "Developer ID Application: Tim McGlothin (TEAMID)"
   ```

3. **Create an app-specific password** for notarization at
   <https://account.apple.com> (Sign-In & Security → App-Specific Passwords),
   then store notarytool credentials once:
   ```sh
   xcrun notarytool store-credentials "portside-notary" \
       --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-pw"
   ```

## Cutting a notarized release

Set the two variables, then release as usual:
```sh
export PORTSIDE_SIGN_IDENTITY="Developer ID Application: Tim McGlothin (TEAMID)"
export PORTSIDE_NOTARY_PROFILE="portside-notary"

Scripts/release.sh 0.3.0 "What changed"
```
The pipeline will hardened-runtime sign, submit to Apple, wait for the ticket,
staple it to the app, then publish a stapled ZIP, a stapled DMG, and the
appcast. Downloaders get a clean first launch.

The DMG is the recommended direct download: open it and drag Portside to the
Applications alias in the Finder window. The ZIP remains the update artifact
for Sparkle and the Homebrew cask.

## Homebrew

The cask lives in a separate repo (`mcglothi/homebrew-tap`, `Casks/portside.rb`),
so none of the release gates cover it. `Scripts/release.sh` bumps it as its last
step, after the GitHub release is live: it downloads the *published* zip, checks
that hash against the one just built, rewrites the cask's `version` and `sha256`,
pushes, then reads the file back from GitHub to confirm the change landed.

That download is deliberate. If GitHub ever served something other than what was
uploaded, a cask built from the local zip would carry a checksum `brew` could
never match, and the first symptom would be a baffling checksum error for a user
rather than a loud failure at release time.

- `PORTSIDE_SKIP_TAP_BUMP=1` — leave the tap alone.
- `PORTSIDE_TAP_DRY_RUN=1` — do everything except the push, printing the diff.
- `PORTSIDE_TAP_REPO=owner/repo` — bump a different tap.

A failure here does not invalidate the release; it leaves Homebrew users on the
previous version, and the script prints the values needed to finish by hand.

## Notes

- **Hardened runtime:** Portside spawns `ssh`/`sftp`/a login shell and uses the
  Keychain — all allowed under the hardened runtime with no special
  entitlements. If notarization ever flags something, add an `entitlements`
  file and pass `--entitlements` in `make_app.sh`.
- **Intel Macs:** releases are currently arm64-only (built on Apple Silicon).
  A universal build (`swift build --arch arm64 --arch x86_64` + `lipo`) would
  cover Intel too — separate from notarization.
- **Signing key for updates:** the Sparkle EdDSA private key lives in your login
  Keychain; the public key is in `Scripts/make_app.sh`. Don't lose it.
