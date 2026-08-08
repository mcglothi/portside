# Key distribution

**Hosts ▸ Copy SSH Key to Hosts…**, or right-click a host, a selection, or a folder.

Adds one of your public keys to a *selection* of hosts' `authorized_keys`, using
the passwords Portside already holds. The single-host case is one `ssh-copy-id`
command and needs no GUI — the fleet case is the feature.

This is the first thing Portside does that **changes remote machines**.
Everything else it does is read-only or a session you are driving. That is why
it works the way it does below.

## Where to start it

- **Hosts ▸ Copy SSH Key to Hosts…** — opens with the sidebar selection ticked.
- **Right-click a host**, or a multi-selection, or a **folder** — a folder ticks
  every host inside it.
- **Settings ▸ Profiles ▸ Copy Key…** on a credential profile that has an
  identity file — ticks the hosts that authenticate with it, and chooses that
  profile's key.

Right-clicking a specific host or folder *does* pre-tick protected hosts, unlike
Select All inside the sheet. Naming a target is the deliberate act the protected
flag asks for; they are still badged and called out again on the confirmation.

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

The success marker carries a random per-push tag, so a host's banner or `motd`
can't be mistaken for a result — a report of success means this push's script
actually ran.

**Certificates are not offered.** An `id_ed25519-cert.pub` looks like a key and
appending one to `authorized_keys` is accepted silently while granting nothing;
certificates are trusted through `TrustedUserCAKeys`. Offering one would report
success and leave you locked out wondering why.

## Copying to a different account

**Copy to account** installs the key for an account other than the one Portside
logs in as. Leave it empty — the common case — and the key goes to the login
user's home, needing no privileges at all. That is the `ssh-copy-id` model,
where `[user@]hostname` decides both who authenticates and whose
`authorized_keys` is written.

Fill it in and **sudo is required on every selected host**. Portside still logs
in as each host's own user and runs:

```sh
sudo -H -u svc_ansible sh -c '<the same script>'
```

This is the only honest way to reach an account you *cannot* log in as — a
key-only service account being bootstrapped is exactly that case, and it is why
Ansible's `authorized_key` module pairs its `user:` parameter with `become`.

- `-H` sets `HOME` to the target's, so the script resolves the right `~/.ssh`.
- Running **as** the target rather than as root means every file is created with
  the correct ownership — no `chown` afterwards, and nothing for sshd's
  `StrictModes` to reject.
- The sudo password is the host's own saved password, sent on stdin **once**.
  A failed sudo is logged on the host and repeats carry the same lockout risk as
  repeated ssh authentications, so the one-attempt rule covers sudo too.
- A host that doesn't permit it is reported as a failure and left alone. The
  reason is sudo's own words — "a password is required", "is not in the sudoers
  file" — rather than a bare exit code.

The confirmation warns before any of this happens.

## Credential profiles

A profile says "these hosts log in with this key". Portside could configure that
and nothing more — it set `ssh -i` and hoped the host already trusted the key.
Two things close that loop:

- **Copy Key… on the profile** (Settings ▸ Profiles) pushes the profile's key to
  the hosts that use it.
- **Assigning a profile** to hosts offers the same thing straight away, since
  that's the moment you've just declared they log in with it. Offered, never
  done — it opens the same sheet, which still confirms.

Two details:

- The profile stores the **private** key path, because that's what `ssh -i`
  wants. What gets pushed is the `.pub` beside it. A profile whose key has no
  public half offers nothing rather than guessing.
- For the **default** profile, "hosts using it" includes every host with no
  profile of its own — which may be most of the library. The count is in the
  button, and the sheet names every host.
- **Aliased hosts are excluded.** `~/.ssh/config` owns their identity file, so
  the profile's key may not be the one they present.

## What Portside can and cannot know

It knows which hosts *it points at* a key — entry, then credential profile, then
defaults. It does **not** know what any `authorized_keys` actually contains
until it looks, and a key set by `IdentityFile` in `~/.ssh/config` is invisible
to it.

**Which account does the key land in?** Whichever one Portside logs in as for
that host — the user resolved from the entry, then its credential profile, then
your defaults, and for an aliased host whatever `~/.ssh/config` says. *Not* an
account named after the key file: pushing `svc_ansible.pub` to a host you
connect to as `deploy` installs it in `/home/deploy/.ssh/authorized_keys`. The
resolved user is shown beside each host in the sheet for exactly this reason.

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
