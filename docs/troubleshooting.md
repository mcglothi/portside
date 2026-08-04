# Troubleshooting

Portside runs the OpenSSH you already have, so most connection problems are
ordinary ssh problems with Portside in front of them. The fastest diagnostic is
usually to run the same connection in Terminal — if it fails there too, the
answer is in `~/.ssh/config` or on the far end, not here.

## Connecting

### It asks for a password even though one is saved

Check, in order:

1. **"Save password in Keychain" is off for that host.** That toggle is
   consent, not a hint — with it off, a host resolves to no password whatever
   is stored.
2. **A credential profile is assigned but has no password**, or the profile the
   host names no longer exists. **View ▸ Inventory Coverage** lists hosts with
   no stored credentials and reports dangling profile references.
3. **The password is right but the account isn't.** A profile *overrides* the
   host's own user — see [credential profiles](credential-profiles.md).

If a whole imported library prompts, see *Everything I imported has no
credentials* below.

### It asks twice, or asks after I typed the right password

By design. The saved password answers the **first** password or passphrase
prompt exactly once. A second prompt means the far end rejected the first, so
Portside stops replaying it and shows a dialog instead.

That is deliberate: blind retries against a fleet burn authentication attempts,
and enough failures trigger `fail2ban` or lock the account. One quiet attempt,
then it asks you.

### An MFA or verification code prompt appears

Expected. Anything that isn't the first password prompt falls through to a
dialog — MFA codes, host-key confirmations, and rejected passwords all land
there.

### "Host key verification failed"

The host's key changed since you last connected. Portside does not override
this and shouldn't: it is the actual protection against a machine-in-the-middle.

If you know why it changed — the box was rebuilt, the IP was reused — remove
the old entry and reconnect:

```sh
ssh-keygen -R hostname
```

If you don't know why it changed, find out before you connect.

Note what the **"Automatically accept new host keys"** connection default does and
doesn't do. It passes `-o StrictHostKeyChecking=accept-new`, which skips typing
"yes" for a host you've never seen. It does **not** weaken the check on a host
you already know — a changed key still hard-fails. It also doesn't apply to
mosh, which bootstraps over its own ssh.

### A jump host or ProxyCommand hangs

Portside passes your `~/.ssh/config` through untouched, so a hanging
`ProxyJump`/`ProxyCommand` hangs identically in Terminal. Test it there with
`ssh -v` and read the last line before the pause.

## mosh

### mosh won't connect but ssh does

mosh bootstraps over ssh and then moves to **UDP, ports 60000–61000**. If ssh
works and mosh doesn't, that range is almost always blocked between you and the
host.

Other common causes: `mosh-server` isn't installed on the far end, or the login
shell prints something on connect that isn't valid for the bootstrap.

### The SFTP browser is missing for a mosh host

Not a fault. SFTP rides the ssh ControlMaster socket, and a mosh session — UDP
after bootstrap — never opens one. The file browser is offered for plain SSH
hosts only.

## Serial consoles

The device is a `/dev/cu.*` node, and Portside can only open what your user can
open. If a USB adapter's device doesn't appear or won't open:

- Confirm it exists: `ls /dev/cu.*`
- Some adapters need their vendor's driver before macOS creates the node at all.
- Check the baud rate and line settings — a wrong baud gives you a connection
  that opens and prints garbage, which looks like a terminal bug.

Use `cu.*` rather than `tty.*`; the `tty.*` node blocks waiting for carrier
detect.

## Terminal output

### Box-drawing, emoji or CJK is misaligned

See [terminal compatibility](COMPATIBILITY.md), which says what is tested and
what is still rough — East Asian widths, combining marks, and ZWJ sequences are
covered there, with the known gaps named.

Check the remote `$TERM` and locale first. A host with `LANG` unset will send
you Latin-1 for anything non-ASCII, and no terminal can render that correctly.

### Colours are wrong

Portside advertises truecolor. If a program disagrees, it's usually reading
`$TERM` or `$COLORTERM` from a stale profile on the far end.

## The library

### "Portside couldn't read your library"

The library existed but wouldn't decode. Portside **does not** overwrite it —
it copies the file aside as `portside.unreadable-<timestamp>.json` and refuses
to save until you decide what to do. Nothing is lost.

That file is JSON. A hand edit, a truncated sync, or a file half-written by a
crash are the usual causes, and the copy is usually recoverable by eye.

### "Library changed on disk"

Another copy of Portside — or a sync client — wrote the library after this one
read it. Rather than clobber it, Portside offers to reload the on-disk version
or overwrite it with what's in memory. Reload is the safe choice unless you
know the in-memory copy is the one you want.

### Everything I imported has no credentials

An exported library carries profile *definitions* and *assignments* but never
passwords, because passwords live in the Keychain. Importing a library whose
profiles you don't have clears those references rather than silently
substituting your own — so the hosts arrive correct but uncredentialed.

Import the profiles too, or recreate them by name, and reassign. See
[credential profiles](credential-profiles.md).

### My tabs didn't come back

Session restore has three settings in Settings ▸ Terminal: don't restore, ask
each launch, or restore automatically. Start pages are never restored.

## Files and resetting

Everything lives in `~/Library/Application Support/Portside/`:

| File | What it is |
|---|---|
| `portside.json` | hosts, folders, groups, macros, credential profiles |
| `portside.local.json` | window layout, appearance, log paths — machine-specific, disposable |
| `portside.history.json` | connection statistics, and command history if you enabled it |

Passwords are in the login Keychain, not in any of these.

To start clean while keeping a way back, quit Portside and move `portside.json`
aside rather than deleting it. To reset only the window layout and appearance,
delete `portside.local.json` — it's designed to be disposable.

## Still stuck

Open an [issue](https://github.com/mcglothi/portside/issues/new/choose) with
the Portside version from About Portside, your macOS version, and the steps.

If Portside quit unexpectedly, attach the report from
`~/Library/Logs/DiagnosticReports/`. It usually points straight at the cause —
the last two crash-class bugs here were each solved in one pass from that file.

**Please don't paste your library.** It contains hostnames and usernames. A
description of its shape — roughly how many hosts, folders and profiles — is
what actually helps, since some bugs only appear at scale.
