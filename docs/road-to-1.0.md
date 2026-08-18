# Road to 1.0

Written at 0.20.0, while it's still easy to see what's shaky. That's the point
of writing it now: it gets much harder to be honest about 1.0 criteria once you
want to ship 1.0.

## What 1.0 means here

Portside has no public API to freeze, so semver's literal meaning doesn't
apply. What changes at 1.0 is **expectation**. `0.x` says "moving fast, expect
sharp edges", and people forgive accordingly. `1.0` says "I'll be held to
this."

So the working definition:

> **1.0 is when the failure modes are boring.**

Not feature-complete, not bug-free — but the bugs that remain are annoyances
rather than "it ate my library" or "it ran that on the wrong host".

## Gates and scope are different things

Keeping these apart is what stops 1.0 sliding forever.

- **Gates** are readiness: things that must be *true*. They're mostly about
  evidence, and some of them can only be bought with time.
- **Scope** is the feature set you want in before you'd call it 1.0. That's a
  judgement call, and it's the maintainer's to make.

A feature landing does not satisfy a gate. Shipping shared inventory doesn't
make the terminal more correct.

---

## Gates

### 1. No known way to lose or corrupt a library

**Where it stands:** much better than it was, not yet proven.

0.20 alone fixed: an SFTP path that could forge a `rm`, exports that left every
restored host unable to authenticate, imports duplicating within a batch, the
whole library being rewritten on every tab change, one malformed group sinking
the entire file, no guard against clobbering a library changed on disk, and a
downgrade silently dropping groups. The 0.16 audit found a data-loss P0 in the
same layer.

That is a lot of integrity bugs from one week of looking, in the part of the
app that has produced them before.

**What would satisfy it:** a few months of real use across more than one
person's library with no new data-integrity finding. The signal isn't "we fixed
them all" — it's that looking stops turning things up. This one cannot be
shortcut, only waited out.

### 2. Terminal correctness has a floor you can point at

**Where it stands:** this is the real gap, and the only one that's hard work.

There is no answer today to: does vim survive a flaky link, does tmux resize
correctly, does a 2 MB paste land intact, what happens on a malformed escape
mid-stream, do combining characters and CJK widths render right. Two incidents
have already come from this area (the Sixel crash, the transcript truncation),
and `SixelStreamGuard` is a workaround being carried in-tree.

A terminal at 1.0 that can't point at a compatibility suite is claiming
something it hasn't checked.

**Started at 0.20.** `Tests/PortsideTests/TerminalHarness.swift` drives a real
SwiftTerm parser with no window — `Terminal` is separable from `TerminalView`,
so bytes go in and the buffer is readable — and the first slice
(`TerminalStreamIntegrityTests`) covers chunk-boundary splitting, unterminated
sequences, random bytes, and volume. Twelve cases in under half a second, so it
runs on every build rather than being a thing someone remembers to do.

Extended since with character width (`TerminalUnicodeTests`) and the OSC
contracts Portside's own features are built on (`TerminalOSCTests`) — OSC 7 for
the SFTP browser's directory tracking, OSC 133 for command history and the
post-connect gate, bracketed paste for the MultiExec paste confirmation, and
mouse mode. Those are pinned separately from general correctness because they
break *Portside* quietly rather than looking wrong on screen. 31 cases, still
under a second.

**Known limitation found by the suite:** ZWJ emoji sequences render as their
separate components with the joiner drawn literally as `<200d>` — `👨‍👩‍👧`
comes out as three emoji and two visible placeholders. The buffer accounts the
cluster as two columns while the view paints roughly eight, so this is not
cosmetic: everything after a ZWJ emoji on that line sits in the wrong place,
and a shell prompt carrying one will corrupt. Upstream in SwiftTerm. The suite
pins the column accounting so a bump that changes it is noticed.

Still to cover: vttest, tmux, vim/neovim, ncurses, OSC 52, Sixel, Kitty
graphics, iTerm2 inline images. Those need either a real child process or
fixture captures, which is a bigger lift than the byte-level cases.

**What would satisfy it:** an executable suite — vttest, tmux, vim/neovim,
ncurses, Unicode width, combining marks, CJK, emoji/ZWJ, bracketed paste, mouse
reporting, OSC 52/7/133, Sixel, Kitty graphics, iTerm2 inline images, malformed
sequences, large payloads, chunk-boundary fuzzing — **that runs before a
SwiftTerm bump**. That gate is the point: the suite matters most as the thing
standing between a dependency upgrade and a regression nobody notices for a
week.

### 3. Tunnels supervise themselves, or the docs say plainly that they don't

**Where it stands:** partly fixed, the rest still open.

**Done:** teardown now escalates. `terminate()` is SIGTERM, and an ssh wedged
mid-handshake or blocked on a stuck ProxyCommand can sit through it — leaving
the local port bound by a process Portside believes it stopped, so restarting
the same forward fails with "address already in use" and the only way out is
Activity Monitor. It now SIGKILLs the process *group* after a grace period,
which also takes a ProxyCommand child with it. Quit does the same thing
synchronously, because a deferred kill never runs once the app is on its way
out and the tunnel would outlive Portside still holding the port.

**Documented instead of built** — `docs/port-forwarding.md`, linked from the
README. The gate offered either, and documenting is the honest option here:
neither maintainer library contains a single saved forward, so supervision
would be designed on speculation with no way to tell whether the behaviour is
right.

The doc is blunt about the gap that matters — "Running" means the ssh process
is alive, not that traffic flows — and about the fact that Portside sets no
`ServerAliveInterval`, so a half-open connection can sit there looking healthy
indefinitely unless the user's own `~/.ssh/config` says otherwise.

One reason for restraint is worth keeping even if this is built later:
automatic retry against a host requiring a password or MFA means repeated
failed authentications, and enough of those lock the account. A tunnel that
gives up loudly beats one that quietly locks you out of the estate.

**Reopen this if** someone starts using forwards in anger. What they expect
after a lid closes is the missing input, not the missing code.

### 4. MultiExec has mileage beyond one person

**Where it stands:** the safety work is good and about a week old, with one
user.

It is the feature Portside would be recommended *for*, and the one that can do
the most damage. The paste confirmation, the three disarm rules and the
protected-host handling all need to survive other people's habits — including
the ones that will find the frequency wrong in one direction or the other.

**What would satisfy it:** a handful of operators using it in anger for a
while, and at least one report of the guardrails being *annoying* — because
that's the failure mode that matters. A guardrail nobody has complained about
is usually one nobody has exercised.

### 5. Upgrade and downgrade are both survivable

**Where it stands:** largely done at 0.20. Migrations rehearse against real
libraries via `PORTSIDE_UPGRADE_FIXTURE`, and the local split keeps a
pre-migration copy so going back is possible.

**What's left:** keep it true. Every future migration needs the same rehearsal
and the same restore point, and the pattern should be documented rather than
remembered.

---

## Scope: what goes in before 1.0

The maintainer's call, not a readiness question.

- **Shared git session library** (`docs/shared-inventory-plan.md`, phase 4) —
  wanted for 1.0. Read-only team inventory over plain git, alongside personal
  sessions rather than instead of them.

- **Key distribution** — **built at 0.23.0**, see
  [key-distribution.md](key-distribution.md). A front end for `ssh-copy-id` that
  pushes a key to a *selection* of hosts, not one at a time, using the passwords
  Portside already holds. Requested by a user; the fleet case is the feature,
  since the single-host case is one command nobody needs a GUI for.

  This is the first thing Portside does that **changes remote machines**.
  Everything before it was read-only or a session you're driving. It got the
  treatment MultiExec paste got, and all of it shipped: a confirmation naming
  every host, the key's fingerprint shown before rather than after,
  `isProtected` never swept in by Select All, per-host results rather than one
  "done", and no auth retry ever.

  **Validated against a real fleet on 2026-08-11**, which was the mileage
  rotation was waiting on. `KeyDistributorIntegrationTests` drives the real
  `defaultRunner` against two Linux hosts — one with passwordless sudo, one
  requiring a password it deliberately doesn't supply — so a single run covers
  both outcomes of a fleet push. All four cases pass, and the side effects were
  checked independently of what the tests believe:

  - The `authorized_keys.portside-backup` written on each host is byte-identical
    to the pre-push file (sha256 compared against a baseline taken beforehand).
    That is the first real-host proof of the backup path, which the
    single-quoted `$HOME` bug had silently disabled until 0.23.0.
  - A service account's `~/.ssh` owned by a **non-default group** came through
    the push unchanged, group included.
  - The throwaway key used for the reversible cases was gone afterwards, and
    both hosts' own `authorized_keys` hashed identical to their baseline.
  - A host that refuses sudo is reported in sudo's own words and does not stop
    the run; an unknown account is named rather than returning an exit code.

  Before this, the remote script was exercised only against `/bin/sh` with a
  throwaway `HOME` on every build — which is how two real bugs in it were
  caught, the unexpanded `$HOME` above and an append that welded the key onto an
  `authorized_keys` with no trailing newline.

- **Key rotation** — **built at 0.24.0**, see [key-rotation.md](key-rotation.md).
  Add the new key everywhere, verify, then retire the old one. Three phases the
  user drives, never one button, and it waited for key distribution's real-fleet
  mileage as planned.

  One thing this plan got wrong, worth recording. It said verify meant
  "connect with `IdentitiesOnly=yes` and the new key alone" — **that does not
  work**, and believing it would have shipped a feature that locks people out of
  fleets. `IdentitiesOnly=yes` does not mean "only the key I passed": identity
  files configured in `ssh_config` count as configured, so an aliased host's
  `IdentityFile` is still offered and reported as `explicit`. There is no option
  that suppresses it while keeping the alias resolvable, and every host in the
  maintainer's library is aliased.

  Two further ways a verify passes while proving nothing, both measured against
  real hosts: a connection joining an existing `ControlMaster` authenticates
  *nothing at all* (`ssh -v` prints `mux_client_request_session` and no
  `Server accepts key` line), and the session entry's own `-i` — during a
  rotation, usually the key being retired — would otherwise be offered too.

  And a third, deeper than the other two, which was found only by building the
  check and then attacking it: **"the server accepted this key" is itself not
  authentication.** OpenSSH logs that line when it accepts an unsigned *probe*;
  signing happens after and can still be refused, at which point ssh moves on and
  may authenticate with something else. Reproduced on a fixture host by putting
  one key's `.pub` beside another's private key — the probe was accepted, the
  signature refused, a different key got in, and the command exited 0.

  So the assertion is not "the connection succeeded", and not "this key was
  accepted", but **"this key is the one that authenticated"** — the key named on
  the last acceptance before the connection reports being authenticated, since
  anything accepted earlier had its signature refused. Plus the session having
  actually run a command, read from a private channel the host cannot write to.

  The lesson generalises, and it took three attempts to state correctly: *a
  connection succeeding says nothing about which credential succeeded, and
  neither does a credential being accepted.*

  The rule is enforced in three independent places — the sheet, the remote script
  (which refuses unless the new key is active in the file it's rewriting), and a
  post-rewrite check that restores from the backup if the new key ever goes
  missing.

  Two hard rules. The old key is never removed from a host that hasn't just
  proved the new one works — "the push reported success" is not proof. And
  `authorized_keys` is copied aside before being rewritten, the same instinct as
  `portside.pre-local-split.json`: cheap, and the difference between a bad edit
  being a nuisance and being a trip to a console.

  Note what Portside can and can't know here. It knows which hosts *it points
  at* a key (entry → profile → defaults). It does not know what any
  `authorized_keys` contains, and a key set by `IdentityFile` in `~/.ssh/config`
  is invisible to it. The target list is a proposal; the verify phase is what
  makes it true.

Everything else currently on the table is explicitly **1.x**, not 1.0: CLI and
URL scheme, tmux control mode, triggers and notifications, connection
diagnostics, Touch ID gating, dynamic inventory providers, Intel support.

1.0 does not mean "has everything". It means what it has, it does properly.

---

## How we'd know

The honest test isn't a checklist score. It's this:

> A release cycle goes by where nothing surfaces that makes you say *we should
> fix that before anyone else hits it.*

The 0.20 cycle had several. When one doesn't, and the gates above are met,
that's 1.0.
