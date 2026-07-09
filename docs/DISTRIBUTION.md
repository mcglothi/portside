# Distributing Portside to other people

Today Portside is **ad-hoc signed**. That's fine for you and a few trusted
people, but anyone who downloads a release will hit Gatekeeper on first launch
("Apple cannot check it for malicious software") and must approve it manually in
**System Settings → Privacy & Security → Open Anyway**.

To make it open with no friction, the app must be **Developer ID signed and
notarized**. The build/release scripts are already wired for this — they just
need credentials. Until the environment variables below are set, everything
stays ad-hoc and nothing changes.

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
staple it to the app, then publish the stapled zip + appcast. Downloaders get a
clean first launch.

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
