# Key distribution

**View ▸ Copy SSH Key to Hosts…**

Adds one of your public keys to a *selection* of hosts' `authorized_keys`, using
the passwords Portside already holds. The single-host case is one `ssh-copy-id`
command and needs no GUI — the fleet case is the feature.

This is the first thing Portside does that **changes remote machines**.
Everything else it does is read-only or a session you are driving. That is why
it works the way it does below.

## What happens

Three steps, and nothing is contacted before the second one.

1. **Choose.** Pick a key from `~/.ssh` and tick the hosts. The key's SHA256
   fingerprint is shown here, not after — a filename does not identify a key,
   and the fingerprint is the only thing you can check against a host or against
   what someone sent you.
2. **Confirm.** Every host is named, not counted. Protected hosts included in
   the selection are called out separately.
3. **Push.** One host at a time, with a per-host result: *key added*, *already
   had it*, or *failed* with the reason.

## The rules

**Never more than one password attempt per host.** Every connection sets
`NumberOfPasswordPrompts=1`, and nothing in the code retries. Forty hosts pushed
with a stale password is forty failed authentications, and enough of those locks
the account across the estate — turning "the key didn't install" into "nobody
can log in". A push that fails is reported and left alone.

**Hosts Portside holds no password for run under `BatchMode=yes`**, so they fail
immediately rather than blocking the queue on a prompt nobody is watching.

**Select All never sweeps in a protected host.** Tick those individually, the
same rule MultiExec uses, and for the same reason: "select all" is how someone
ends up acting on the production box they deliberately fenced off. A protected
host you *have* ticked is flagged again on the confirmation.

**A failure on one host doesn't stop the run.** The report is the product, and a
partial one is what makes a fleet push hard to trust.

**Pushes reuse an interactive session's connection but never become one.** If
you already have a terminal open to a host, the push rides its ControlMaster
socket and costs no authentication at all.

## What it does on the host

```sh
umask 077
# ~/.ssh and authorized_keys are created if missing — and only then given
# 0700/0600. An existing file's permissions are yours, not Portside's.
# The key is appended only if the host doesn't already have it.
# authorized_keys is copied to authorized_keys.portside-backup first.
```

Two details worth knowing:

- **"Already has it" compares the key type and blob, never the comment.** That
  pair is what `authorized_keys` actually authenticates on, so the same key
  under a different comment is correctly recognised as already installed and is
  not appended twice.
- **A commented-out entry does not count as installed.** Matching is done over
  non-comment lines field by field, which also handles entries carrying
  `command=` or `from=` options, where the key type isn't the first field.

Re-running a push is therefore safe and does nothing on hosts that already have
the key.

## What Portside can and cannot know

It knows which hosts *it points at* a key — entry, then credential profile, then
defaults. It does **not** know what any `authorized_keys` actually contains
until it looks, and a key set by `IdentityFile` in `~/.ssh/config` is invisible
to it.

So the host list is a proposal. The per-host result is what makes it true.

## What this is not

It does not remove keys, and it does not rotate them. **Key rotation** — generate
a new key, add it everywhere, verify, then retire the old one — is deliberately a
later feature, because rotation's first phase *is* key distribution, and shipping
both together would mean the first time anyone retires a key, the code that
installed it is also new. See `docs/road-to-1.0.md`.

## Troubleshooting

**"Permission denied"** — Portside had no password for that host, or the one it
had was wrong. It will not try again on its own. Check the host's credentials
(or its credential profile) and re-run; the hosts that succeeded will report
"already had it" the second time.

**"Host key verification failed"** — the host isn't in `known_hosts` and
Settings ▸ Connection ▸ accept new host keys is off. Connect a terminal session
to it once, then re-run.

**Nothing in the key list** — Portside reads only `*.pub` files from `~/.ssh`.
Generate one with `ssh-keygen -t ed25519`.
