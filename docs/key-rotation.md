# Key rotation

**Hosts ▸ Rotate SSH Key…**

Replaces one key with another across a selection of hosts, in three stages you
drive yourself: **add** the new key, **verify** each host really authenticates
it, then **retire** the old one — only from the hosts that just passed.

It is deliberately not one button. Rotation's first stage *is*
[key distribution](key-distribution.md), and its last stage removes access; those
belong at arm's length from each other.

## The one rule

> The old key is never removed from a host that has not **just** proved the new
> one works.

"The push reported success" is not proof. It says a line was appended to
`authorized_keys`, not that sshd will authenticate with it. `StrictModes`
refusing a home directory's permissions, an `AuthorizedKeysFile` pointing
somewhere else, a `Match` block restricting key types — each leaves a
correct-looking file that authenticates nothing. So the proof is a real login,
and nothing else counts.

That rule is enforced three times over, because the cost of getting it wrong is
a trip to a console:

1. **The sheet** offers retirement only for hosts showing a verified result in
   *that* sheet. Change either key and every verification is discarded —
   structurally, because a rotation's keys are fixed at creation and a different
   key is necessarily a different rotation.
2. **The host itself** refuses to remove the old key unless the new one is
   *active* in the very file it is about to rewrite. The app's belief and the
   file's contents are different things, and only the second one matters at the
   moment of the rewrite.
3. **After the rewrite**, the host checks again, and restores `authorized_keys`
   from its own backup if the new key somehow went missing.

## The three stages

### 1. Add

Exactly a key push — same engine, same rules. Each host is contacted once, a
password is never tried twice, and `authorized_keys` is copied aside before it
is touched. A host that already has the key is a no-op rather than a duplicate.

Non-destructive and repeatable. Run it as often as you like.

### 2. Verify

Logs into each host **with the new key alone** and confirms the host accepted
*that key*. Changes nothing, sends no password, and is the only thing that
unlocks stage three.

Before contacting anything it checks the key can be used from this Mac at all: a
passphrase-protected key that isn't loaded in the agent would fail every host
identically, and forty hosts reporting "key not accepted" for a local problem is
the most misleading output this feature could produce. You get one sentence
telling you to run `ssh-add` instead.

### 3. Retire

Removes the old key from the hosts that passed stage two, and no others. Hosts
that didn't pass are listed on the confirmation as keeping their old key, so a
partial rotation is visible rather than silent.

On the host: `authorized_keys` is copied to `authorized_keys.portside-backup`
first — and if that copy fails, **nothing is rewritten**. The file is then
rewritten *through* the original rather than renamed over it, so its inode,
permissions and ownership survive and a symlinked `authorized_keys` is followed
rather than replaced. Comment lines are preserved exactly, including a
commented-out copy of the old key: a commented entry grants nothing, and your
annotations are not Portside's to delete.

A key is matched by **type and blob**, never by comment and never by substring.
Editing a key's comment does not make it a different key, and a longer key whose
blob merely starts with the old one is not the old one.

## Three ways a verification can lie

These are the reason stage two asserts *which key was accepted* rather than
merely that the connection worked. Each was measured against real hosts, and each
one — unnoticed — would have turned this feature into a way to lock yourself out
of a fleet.

**Connection multiplexing.** Portside opens a `ControlMaster` for interactive
sessions. A second connection over that socket authenticates *nothing at all* —
`ssh -v` through a live master prints `mux_client_request_session` and not one
`Server accepts key` line. Verifying a host you happen to have a session open to
would otherwise pass unconditionally. Rotation therefore sets `ControlPath=none`;
`ControlMaster=no` alone does not prevent *joining* an existing master.

**The host's own identity file.** A session entry carries the `-i` it normally
connects with, which during a rotation is usually the key being retired. Offering
it alongside the new one lets the old key satisfy the check that justifies
deleting it. Verification uses the destination and nothing else.

**`~/.ssh/config`.** `IdentitiesOnly=yes` does not mean "only the key I passed on
the command line" — identity files configured in `ssh_config` count as
configured, and an aliased host's `IdentityFile` is duly offered and reported as
`explicit`. There is no option that suppresses it while still resolving the
alias.

So a verification passes only when ssh's own verbose output reports that the
server accepted a key **with the new key's fingerprint**, *and* the session
actually ran a command. Either proof missing is a failure, never a pass. A key
that was offered and declined is reported as rejected — a plain fact, and the
expected answer before the key has been added.

## Rotating a key for another account

Fill in **Account** and the key is added to, verified against, and retired from
that account rather than each host's login user. Add and retire escalate with
`sudo`, exactly as key distribution does; verification logs in *as* that account
using the new key, which is the honest test of whether the account is usable.

## What Portside knows, and what it doesn't

It knows which hosts *it points at* a key — through the entry, its credential
profile, or your defaults. It does **not** know what any `authorized_keys`
contains, and a key set by `IdentityFile` in `~/.ssh/config` is invisible to it.

So the host list is a **proposal**. Stage two is what makes it true.

## If something goes wrong

Every host that was rewritten has `authorized_keys.portside-backup` beside its
`authorized_keys`, holding the file exactly as it was before. Restoring is
`cp ~/.ssh/authorized_keys.portside-backup ~/.ssh/authorized_keys`.

A host reported as **refused** was not touched at all — that is the host's own
guard firing because the new key wasn't in the file.
