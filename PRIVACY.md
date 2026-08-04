# Privacy

Portside is a local application. It has no accounts, no analytics, and no
servers of its own.

## What leaves your Mac

**The connections you make.** SSH, mosh, telnet and serial traffic goes where
you point it, using the system OpenSSH client and your own `~/.ssh/config`.
Portside does not proxy, relay or inspect it.

**Update checks.** Portside asks GitHub for the release appcast on a schedule
and on request. That request tells GitHub what any web request tells a server:
your IP address, and — from the user agent — the Portside and macOS versions.
No identifier is attached, nothing about your hosts is sent, and Sparkle's
optional system-profiling feature is not enabled. Turn checks off entirely in
Settings ▸ Updates.

That is the complete list. There is no telemetry, no crash reporting, and no
"anonymous usage statistics".

## What stays on your Mac

Your host library, macros, groups, connection history and session logs are
files in `~/Library/Application Support/Portside/` and wherever you point
logging. Passwords and passphrases live in the macOS Keychain. Nothing is
uploaded, and nothing is shared between machines unless you put those files
somewhere shared yourself.

Two things are worth knowing because they are recordings rather than settings:

- **Session logging** (Settings ▸ Recording) writes terminal output to disk,
  including anything a remote host prints back at you.
- **Command history** records the command lines you run. It is off by default,
  because command lines routinely contain secrets typed inline.

Both are yours to enable, and yours to delete.

## Questions

Open an issue, or email timmcg@gmail.com. For anything security-sensitive,
see [SECURITY.md](SECURITY.md) — please don't use a public issue.
