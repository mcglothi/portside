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
- Passwords and passphrases are stored in the macOS Keychain. One exception:
  when a password must be handed to `ssh`, it is written to a mode-`0600`
  file in a private temporary directory for the askpass helper to read, and
  unlinked immediately afterwards. A crash or force-quit can leave that file
  until the next launch, which purges any it finds. This is materially weaker
  than the Keychain against another process running as you.
- **Deleting a host defers the removal of its Keychain password** for as long
  as the delete can still be undone (Edit ▸ Undo Delete, a ring of the last ten
  deletions). Removing it immediately would restore a host that could no longer
  authenticate, and stashing the plaintext to write back later would move a
  secret out of the Keychain. Quitting finishes the pending removals; a crash
  inside that window leaves an item behind, which the next launch sweeps up by
  deleting per-host passwords whose host is no longer in the library.
- Portside writes three files in `~/Library/Application Support/Portside/`, all
  plain JSON:
  - `portside.json` — the host library, macros, groups and credential
    *profiles*. No passwords: those are Keychain references only. This is the
    file Export Sessions writes, so it is the one that travels.
  - `portside.local.json` — window layout, appearance, log paths. Machine-shaped
    and disposable.
  - `portside.history.json` — connection statistics, and *optionally* a log of
    the commands you ran. **Command history is off by default and should stay
    off unless you want it**: command lines routinely contain secrets typed
    inline, and this records them in plain text. It is opt-in in Settings ▸
    Recording, capped, and never included in an export.
- Release binaries are Developer ID signed and notarized; updates are
  verified against a pinned EdDSA public key embedded in the app.
