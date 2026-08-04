# Credential profiles — one identity, many hosts

A credential profile is a named user, key and password that hosts can defer to
instead of each carrying their own.

The point is rotation. When the ops account's password changes, you change it
once instead of on four hundred hosts — and every host that defers to that
profile is immediately correct.

## What a profile holds

- **A user** — applied to hosts that use the profile.
- **An identity file** — the private key, passed as `ssh -i`.
- **A password**, in the macOS Keychain. Passwords never touch the library JSON.

Manage them in Settings ▸ Profiles. Assign one to a host in the host editor, or
to a whole selection at once from the sidebar's context menu.

## How a host resolves its credentials

Assigning a profile **overrides** the host's own user and key. That's the
feature, not a side effect: if a profile didn't override, rotating it wouldn't
change what a host actually uses.

Two details worth knowing:

- **The user is not overridden when the host uses an SSH alias.** With an
  alias, `~/.ssh/config` owns the user and Portside stays out of the way.
- **Connection defaults only fill gaps.** The default user and key in Settings ▸
  Connection apply where nothing more specific is set. They never override a
  profile or a host's own value.

For the password, the order is:

1. The host's **assigned profile**
2. A password stored against **the host itself**
3. The **default profile**, if one is set
4. The **legacy default password**

The default profile is the implicit fallback — the profile used by a host that
has saved passwords switched on but names no profile and stores no password of
its own.

**A host with "Save password in Keychain" off resolves to nothing, whatever is
stored.** That toggle is consent, not a hint. Turning it off means "don't use a
saved password for this host", and nothing overrides it.

The same resolution is used everywhere something authenticates as a host —
sessions, SFTP, and port forwards including the ones that start at launch,
before any session exists.

## Finding hosts that aren't covered

**View ▸ Inventory Coverage** reports gaps across the library, including hosts
with **no credential profile** and hosts with **no stored credentials** at all.
A host pointing at a profile that no longer exists is reported too, rather than
silently falling through to something else.

That view is the fastest way to answer "which of these eight hundred hosts will
actually prompt me".

## Export, import, and backup

**Exported libraries do not contain passwords.** They can't — passwords live in
the Keychain, and the export is JSON you might put in a shared folder or a git
repository. An export carries the profile *definitions* and each host's
*assignment*, not the secrets.

So restoring a library on a new Mac gives you every host correctly pointed at
the right profile, and you enter each profile's password once. That is the
intended shape, and it's why profiles matter for backup: without them you'd be
re-entering a password per host.

On import, Portside normalises what it takes in:

- A host referencing a profile that **exists here** keeps the assignment and has
  saved passwords switched on — which is what makes restoring your own backup
  actually authenticate rather than merely look right.
- A host referencing a profile that **doesn't exist** has the reference cleared
  and saved passwords switched off. An import can neither carry a dangling
  reference nor quietly inherit this machine's default profile.

Importing a library exported from a machine whose profiles you don't have will
therefore give you hosts that prompt, not hosts that silently use the wrong
credentials. If most of a large import comes in with no credentials, that is
almost certainly what happened — the profiles it referenced weren't in the file.

## Where the secrets live

In the macOS login Keychain, under the service `net.timmcg.portside.ssh`.
Profile passwords are keyed separately from per-host ones, and deleting a
profile removes its password with it.

For the full picture — including what happens to a deleted host's password
while the delete can still be undone — see
[SECURITY.md](../SECURITY.md).
