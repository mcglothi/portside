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

**Where it stands:** they don't, and the docs don't say so.

No sleep/wake recovery, no restart with backoff, `terminate()` with no SIGKILL
escalation, no warning on a non-loopback bind. A feature that can silently stop
working is a `0.x` posture; either fix it or document it as best-effort.

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
