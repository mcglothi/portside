# Key rotation

**Hosts ▸ Rotate SSH Key…**, or right-click a host, a selection, or a folder.
A credential profile also offers **Rotate Key…**, which arrives with that
profile's current key already chosen as the one to retire.

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

Only one thing actually proves it: stage two, a real login. What surrounds that
proof is three **safety layers**, because the cost of getting this wrong is a
trip to a console and one check at one moment is a thin thing to rest it on:

1. **The sheet** offers retirement only for hosts showing a verified result in
   *that* sheet. Change either key and every verification is discarded —
   structurally, because a rotation's keys are fixed at creation and a different
   key is necessarily a different rotation.
2. **The host itself** refuses to remove the old key unless a plain entry for
   the new one — no options at all — is in the very file it is about to
   rewrite. The app's belief about what a host holds and what the file actually
   says are different things, and at the moment of a rewrite only the file can
   answer.
3. **After the rewrite**, the host looks again, and restores `authorized_keys`
   from its own backup if that entry somehow went missing.

## The three stages

### 1. Add

Exactly a key push — same engine, same rules. Each host is contacted once, a
password is never tried twice, and `authorized_keys` is copied aside before it
is touched. A host whose `authorized_keys` already holds a matching entry is a no-op
rather than a duplicate.

Non-destructive and repeatable. Run it as often as you like.

### 2. Verify

Logs into each host **with the new key** and confirms that key is the one the
host authenticated with. Changes nothing, sends no password, and is the only
thing that unlocks stage three.

Note the wording: *the key that authenticated*, not *a key that was accepted*.
Those are different questions, and getting them confused is how this stage
becomes decorative — see [below](#what-makes-a-verification-real).

Before contacting anything it checks the key can be used from this Mac at all.
Two local faults would otherwise be reported as forty hosts rejecting the key:

- a passphrase-protected key that isn't loaded in the agent, and
- a `.pub` that doesn't match the private key beside it. `ssh-keygen -y`
  succeeds whenever it can *read* the private key and says nothing about the
  `.pub`, so a stale or swapped one used to sail through and fail much later,
  in the wrong place. Portside now compares the derived key.

Either way you get one sentence naming the local problem instead of a fleet of
misleading rejections.

### 3. Retire

Removes the old key from the hosts that passed stage two, and no others. Hosts
that didn't pass are listed on the confirmation as keeping their old key, so a
partial rotation is visible rather than silent. A retirement that *fails* — a
dropped connection, a host that refused — stays on the list and can be retried;
only a successful one removes a host from it.

On the host, the rewrite is transactional:

- `authorized_keys` is copied to `authorized_keys.portside-backup` first, and if
  that copy fails **nothing is rewritten**.
- The rewrite is guarded by a trap on interruption. Redirecting into a file
  truncates it *before* anything is written, so losing the connection in that
  gap — or the process being killed from outside — would otherwise leave a
  truncated `authorized_keys` and exit without restoring. The original is put
  back instead, and if *that* fails you are told plainly to recover from the
  backup by hand rather than being shown a success.
- **Stop does not interrupt a rewrite in progress.** It waits for the host
  currently being written to finish, then skips the rest. The trap above is for
  interruptions Portside does not control; Stop is not one of them, deliberately,
  because the safest moment to stop is between hosts rather than inside one.
- The file is rewritten *through* the original rather than renamed over it, so
  its inode, permissions and ownership survive and a symlinked `authorized_keys`
  is followed rather than replaced.
- Comment lines are kept, including a commented-out copy of the old key: a
  commented entry grants nothing, and your annotations are not Portside's to
  delete. Their *content* survives unchanged, though a final comment with no
  trailing newline will gain one. The backup beside the file is byte-exact.

**Which line counts as the key** is decided by reading it with
`authorized_keys`'s own quoting rules — skipping any options, honouring quoted
values that contain spaces, and taking the key type and data from the positions
they actually occupy. A key written inside a comment or an option is a *mention*
of that key, not permission to use it, and must not be deleted as though it were
the real entry. Copying a key uses the same reading, because finding an existing
entry wherever it sits is exactly what both want.

The guard protecting the key you are **keeping** deliberately does not. It
accepts only a plain entry with no options at all — the shape Portside itself
installs. An entry behind `from=` or `command=` may be perfectly good or may have
expired an hour ago, and that is a question only sshd can answer. Portside
refuses to retire rather than guess, which costs you a manual step; guessing
wrong would cost you the host.

## What makes a verification real

Stage three deletes access. The only thing standing between it and a locked-out
fleet is stage two actually meaning something, so it is worth being precise
about what it checks.

**A connection succeeding says nothing about which credential succeeded.** That
is the whole problem in one sentence, and every trap below is a version of it.

**`Server accepts key` is not authentication.** OpenSSH logs it when the server
accepts an *unsigned probe*; ssh then signs and sends the real request, and the
signature can still be rejected — after which ssh quietly moves to the next
identity and may well get in with that one. A check asking "was our fingerprint
accepted anywhere" answers yes to a key that authenticated nothing. Portside
reads the transcript in order and takes **the key named on the last acceptance
before the connection reports being authenticated**, because anything accepted
earlier had its signature refused.

**A connection that rides an existing multiplexed session authenticates
nothing at all.** Portside opens a shared connection for interactive sessions,
and a second connection over that socket skips authentication entirely, so
verifying a host you happen to have a terminal open to would pass
unconditionally. Verification opts out of sharing.

**The host's own configured key gets offered too.** A session entry carries the
key it normally connects with — during a rotation, usually the very key being
retired — and `~/.ssh/config` may name another. `IdentitiesOnly` does not
suppress those: the manual is explicit that configured identity files count as
configured, and on an aliased host that is the common case rather than the
corner. There is no option that suppresses them while still resolving the alias,
which is exactly why the check has to be about *which key won* rather than about
the connection succeeding.

**The evidence is read from a channel the host cannot write to.** ssh's stderr
is shared with the remote host's, and a host can print a convincing acceptance
line of its own. Verification sends ssh's log to a private file instead, and
matches lines by their beginning rather than searching anywhere in them — ssh
also logs the command *we* send, and a search would happily match text we handed
it ourselves.

So a verification passes only when the transcript shows this key authenticating
**and** the session actually ran something. Either proof missing is a failure,
never a pass.

Two failures that look identical are reported differently, because they send you
to different machines:

- **Offered and never accepted** — the host declined this key. A definite
  negative about that host, and the expected answer before the key is added.
- **Accepted and then the signature refused** — the host *does* trust the key;
  the private key on this Mac is a different one. A local fault.

## Rotating a key for another account

Fill in **Account** and the key is added to, verified against, and retired from
that account rather than each host's login user.

Add and retire escalate **once, straight to that account** — never via root, and
exactly as key distribution does since 0.23.2. Root working inside a directory
the account controls is a privilege escalation, and validating the path first
cannot be made safe in a shell, so Portside does not try. One consequence
follows: **the account's home must already exist.** Portside will not create it,
and says so rather than guessing.

Verification logs in *as* that account using the new key, which is the honest
test of whether the account is usable at all — and the one case where a
key-only service account with no shell will authenticate and still be unable to
run anything, which is reported as exactly that rather than as a rejection.

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
