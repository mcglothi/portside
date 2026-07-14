# Security Policy

## Supported Versions

Only the latest release receives security fixes. Portside auto-updates via
Sparkle (EdDSA-signed appcast), so staying current is the default.

## Reporting a Vulnerability

Please report vulnerabilities privately — do not open a public issue.

- Preferred: [GitHub private vulnerability reporting](https://github.com/mcglothi/portside/security/advisories/new)
- Email: timmcg@gmail.com

You can expect an acknowledgment within a week. Once a fix ships, the
advisory is published with credit unless you ask otherwise.

## Scope and Design Notes

- SSH transport is delegated to the system OpenSSH client; Portside does not
  implement its own cryptography.
- Passwords and passphrases are stored in the macOS Keychain, never on disk.
- Session metadata lives in `~/Library/Application Support/Portside/` and is
  plain JSON by design (no secrets are written there).
- Release binaries are Developer ID signed and notarized; updates are
  verified against a pinned EdDSA public key embedded in the app.
