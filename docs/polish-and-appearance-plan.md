# 0.17 — Polish & Appearance

The Phase 3 that 0.16 deliberately deferred, plus the small carry-overs it left
behind and one defect the pre-release verification turned up.

0.16 added several new surfaces — the coverage view, the history browser, the
split sidebar toolbar — and the plan put styling last on purpose so those views
would be styled once instead of restyled afterwards. That condition is now met.

---

## Phase 0 — The Sixel crash

Not on any roadmap; found while re-verifying the compatibility matrix on
2026-07-27. It goes first because it is the only item here that can lose
someone's session, and it is small.

**The defect** is upstream, in SwiftTerm 1.15.0's `SixelDcsHandler`. It measures
an image in one pass and fills it in a second, but the measuring pass only
widens the image at a band terminator (`$` or `-`). A sixel whose final band is
wider than every terminated band before it is measured too narrow, and the fill
pass writes past the end of the pixel buffer. It is a `fatalError`, so the app
dies — triggered by ordinary output arriving over SSH, with no user action.

Every single-band image of width ≥ 2 hits this. Portside also advertises Sixel
support in its device attributes (`TerminalOptions.enableSixelReported` defaults
to true), so applications probe, find support, and send.

The fix is one line in `unhook()`, before the buffer is allocated:

```swift
maxX = max (maxX, x)
```

Verified in both directions against the vectors in
`Tests/PortsideTests/InlineImageProtocolTests.swift`: with it, all decode to
correct dimensions; without it, the wider-final-band and single-band cases
crash.

### It is already fixed upstream, and we missed it by three hours

Checked before writing this up, which is the only reason it didn't become a
duplicate bug report:

| | |
|---|---|
| `v1.15.0` tagged | 2026-07-19 18:55:43Z — commit `dd2fb8ac`, exactly our pin |
| `58915b10` "Fix sixel crash" | 2026-07-19 21:41:30Z |

The fix on `main` is character-for-character the line derived above, in the same
place, with a comment giving the same reasoning. It missed the release by two
hours and forty-six minutes, and `v1.15.0` is still the newest tag.

`main` is 9 commits ahead of it, and the rest of that range is unusually
relevant to a terminal whose input is untrusted remote output:

- `c1671643` replace `abort()` and force-unwraps in `CircularList` with
  preconditions
- `b1b4636c` avoid force-casting `CTRun` font/colour attributes
- `d327a2bb` clamp oversized CSI/DCS/OSC parameters
- `64dc185a` decode Kitty placeholder IDs in RGB order

So this is not a defect to report. **It is a release to wait for, work around,
or pin past** — see the decision below.

**Decided: ship a byte-tap guard.** ✅ Done — `SixelStreamGuard`.

`LoggingTerminalView` already taps raw bytes in `dataReceived` before handing
them to SwiftTerm — the same seam OSC 133 parsing uses — so the guard appends
the band terminator the encoder left off, on the way past. A trailing `-` folds
the last band into the measured width but plots no pixels, so the decoded image
is identical to what the upstream fix produces. `SixelStreamGuardTests` asserts
that equivalence against a real `Terminal` instead of assuming it, and checks
every chunk boundary from 1 byte upward, because output arrives in whatever
sizes the transport hands over and the terminator decision has to survive a
split between the `ESC` and the `\`.

The log and the command timeline still receive the bytes exactly as they
arrived — only the terminal sees the repaired stream — because the guard can
change the byte count and transcript offsets have to keep matching what is on
disk.

Rejected alternatives, and why:

- **Wait for `v1.16.0`.** Zero work, unknown date, leaves a remote-triggerable
  crash in shipped builds for as long as it takes.
- **Pin to the fix revision.** Picks up the crash fix *and* the four hardening
  commits above, but notarised releases would ship off an untagged dependency —
  a real reproducibility question for a signed app.
- **Stop advertising Sixel** (`enableSixelReported = false`). A mitigation, not
  a fix: it does nothing about a program that emits sixel unconditionally.

**Delete the guard when the pin moves.** It is dead weight the moment a
SwiftTerm carrying `58915b10` is released, and it is written to be removed in
one commit.

No upstream report was filed — the defect is already fixed on `main`, so a bug
report would have been a duplicate.

There is a second, cosmetic finding alongside it: a single-band sixel of width 1
decodes to a 0×0 image rather than 1×6, because the sizing loop's `p + 1 <
data.count` bound skips the last byte. No crash, no realistic image hits it.
Worth mentioning in the same upstream issue, not worth its own work.

### While here: the matrix was wrong

`docs/COMPATIBILITY.md` listed Sixel, iTerm2 (OSC 1337) and Kitty graphics as
unsupported. That was true when measured, against SwiftTerm 0.6.1-dev, and has
been wrong since the dependency moved to 1.x. All three work. The matrix and the
README are corrected, and `InlineImageProtocolTests` now re-checks all three on
every `swift test` so the claim stops being carried forward on faith.

The correction is already committed to docs. What's left is deciding whether
inline images are worth *surfacing* as a feature — they're currently a
capability nobody knows Portside has.

---

## Phase 1 — App appearance ✅ Done

**Locked with Tim during 0.16 planning, unchanged:** the setting lives next to
the terminal colour theme in Settings ▸ Appearance, clearly separated. Adjacent
so the relationship is obvious, explicitly independent so a dark terminal in a
light app (or the reverse) stays possible. The two must never be coupled.

Shipped as `AppAppearance` on `TerminalAppearance` — tolerant Codable, default
`.followSystem` — driving `NSApp.appearance` from `PortsideApp`. Settings gets
an "App Appearance" section directly above "Font" and "Theme", with a line
saying outright that the terminal keeps its own colours, because that is the
question the control invites.

Two things worth keeping in mind:

- **"Follow system" is `nil`, not a third appearance.** Returning `.aqua` for it
  would pin the app to light and look identical until the user changed their
  system theme — a bug that hides for as long as your test machine stays light.
  `AppAppearanceTests` asserts the `nil`.
- **The apply is guarded.** It runs on every appearance change, including font
  and theme edits, and reassigning the same `NSAppearance` makes AppKit redraw
  every window — visible as a flicker while dragging the font-size slider.

Verified in a real build against a **dark** system, so the override is doing
something rather than agreeing with macOS by accident: light chrome renders with
the dark terminal theme intact and a clean seam, and dark renders dark. The
first attempt at the dark check was a false negative — `open` reactivated the
still-running app instead of restarting it, so it kept the old in-memory value.
Quit and confirm the process is gone before relaunching, or the check is
measuring nothing.

---

## Phase 2 — Carry-overs

Both were cut from 0.16 and named in the README, so they are promises already
made.

### Browsable recently-closed tabs ✅ Done

Reopen any of the last N closed tabs, not just the single most recent. The ring
already existed and already held ten — only the UI was single-step, so this was
mostly a menu.

**Decided with Tim: in-memory only.** The ring is a record of what
infrastructure you had open, which is a different proposition from the session
restore that outlives a quit by design. Quitting clears it, and File ▸ Recently
Closed ▸ Clear drops it on demand, the same courtesy the connection log gets.

Extracted to a `ClosedTabRing` value type so eviction and take-out rules test
without a `SessionManager` or a spawned terminal. Reopening removes the entry —
a tab that is open again is not a tab you can reopen, and leaving it in means
every pick spawns another copy.

**This uncovered a real gap: there was no way to close a tab from the keyboard
or the menu bar at all.** Closing a whole tab was reachable only from the tab
strip's × button, so ⇧⌘T could undo something you had no keyboard way to do.
Added File ▸ Close Tab. It shipped on ⌥⌘W first, on the reasoning that ⌘W is
Close Window and had never belonged to Portside; Tim then asked for the
terminal-app convention, so **it is ⌘W** and ⇧⌘W stays Close Pane.

Taking ⌘W costs the stock File ▸ Close its own shortcut — SwiftUI yields the key
to our item and strips its own, and re-applies that on every menu-bar open, so
an AppKit fixup to rename and rebind it does not survive to display. The window
is still closable by its red button, the Window menu, and ⌥⌘W Close All.

One SwiftUI wrinkle worth remembering: **`.disabled` is ignored on a `Menu`
inside a `CommandGroup`.** The submenu opens whatever you do, so the empty state
is a disabled "No Recently Closed Tabs" placeholder inside it rather than a
greyed-out parent. Verified by enumerating the live menu, not by reading the
code.

### A "never connected" coverage category ✅ Done

Distinct from stale. A host nobody has ever opened and a host untouched for 90+
days mean opposite things: one is an import that was never verified, the other
is drift. `ConnectionHistory.staleEntryIDs` already said as much in a comment —
"a host with no history at all is *not* stale — it's unknown, which the coverage
view reports separately" — except that it didn't yet. Now it does.

Reported, not scored, so 100% stays reachable for a fleet that is fully
described but not fully visited.

The judgement call worth keeping: **no history at all is not evidence that
nothing has been connected to.** Recording may be off, or the library may be
minutes old. `connectedEntryIDs` returns `nil` in that case and the axis stays
silent, rather than declaring an entire imported fleet unvisited. The detail
text also says outright that only recorded connections count, so hosts used
before history was enabled will show up here.

No bulk action, deliberately. The obvious one would be "delete these", and an
unvisited host is exactly as likely to be one you have not needed yet as one
that was never real.

---

## Phase 3 — The broader pass

In roughly descending order of how often you'd notice:

- **Empty states** ✅ Done — see below.
- **Density and spacing consistency** ✅ Done — `Metrics`.
- **Chrome** ✅ Done — one `CapsuleBadge` instead of three.
- **Iconography** ✅ Done — one warning symbol instead of two.

This is the part with no hard acceptance test, so it is also the part most
likely to expand. It was kept to *removing duplicates that already existed*
rather than introducing a design system the app has not asked for.

### Density and spacing ✅ Done

The sheet-style views were each built independently and each picked its own
numbers: 10pt header padding in some, 12 in others, content insets that did not
match the chrome above them. Individually invisible; together they are why the
app looked assembled rather than designed.

`Metrics` holds the agreed values. Deliberately five constants and not a design
system — the goal was to stop re-picking numbers, not to build a framework.

### Chrome ✅ Done

`CapsuleBadge` already existed for host tags, and the credential-profile list
and port-forwarding list had each hand-rolled their own capsule beside it, at
6pt and 5pt horizontal padding respectively. Same element, three
implementations, none agreeing.

Now one component with three styles, matching the three jobs a badge does here:
label a *kind* (tinted, the host tags), mark the *chosen* one (accent), or state
a neutral attribute. Uppercasing belongs to the tinted style alone — it suits
`PROD` and looks shouty on "Default".

One thing to know if you touch it: the background must be `AnyShapeStyle`, not
`some View`. `.background(_:in:)` fills a shape with a *style*, and a
`@ViewBuilder` there yields a view, which does not compile.

### Iconography ✅ Done

Warnings were split between `exclamationmark.triangle` and its `.fill` form for
the same meaning. Unified on `.fill`, which was already the majority.

Left alone deliberately: the checkmark family. `checkmark.circle.fill` marks a
live status (connected, succeeded) and `checkmark.circle` marks a static
attribute ("Installed") — that reads as a real distinction rather than drift,
and flattening it would lose meaning to gain tidiness.

### Empty states ✅ Done

**Eight** views could show nothing, and each had invented its own way of saying
so: the sidebar and three others used `ContentUnavailableView`, the history
browser and the credential-profile list hand-rolled icon/title/detail, the
coverage view had a bare line of caption text, and the file browser had two
lines jammed into one `Text`. They read as different apps, and the thin ones
read as a bug rather than a state. (The count grew from four as the sweep went
on — the later ones were only found by opening the app and looking.)

All four now go through one `EmptyStateView`, which **wraps
`ContentUnavailableView`** rather than replacing it — full-size states stay
native and follow the platform as it changes. The compact variant is hand-rolled
only because there is no small `ContentUnavailableView` and the full one swamps
a pane inside a split.

The shape is fixed on purpose: an icon, a short statement of *what is not here*,
and a detail line saying **what would put something here**. An empty state that
only says "nothing yet" tells you what you can already see. An action is offered
only when the thing that fills the view is one control away — a wrong button is
worse than no button.

Two states now say something they previously got wrong:

- **The coverage view treated an empty library and a fully-covered one as the
  same thing.** They are opposites — nothing to survey versus nothing left to
  fix — and the old code would congratulate you on an inventory you had not
  imported yet.
- **The file browser called a directory of dotfiles "Empty directory."** It now
  distinguishes genuinely empty from hidden-by-filter, because the old wording
  sent people hunting for a transfer that had worked fine.

Also renamed `EmptyStateView` → `WelcomeView`. The name was taken by the
"welcome aboard" start page, which is not an empty state, and that collision is
exactly the sort of thing this phase exists to remove.

**A crash caught on the way through**: sheets here do not inherit environment
objects — which is why `CoverageView` was already being handed `store`
explicitly. Adding an Import action to its empty state introduced a second
dependency, and a missing `@EnvironmentObject` is a crash, not a blank view.
Verified by opening the sheet against an emptied library, not by reading the
code.

---

## Codex CLI pre-release review, 2026-07-27 (`docs/0.17-pre-release-review.md`)

Commissioned before tagging, same as the 0.16 audit. It found one real defect
that our own tests missed, in the file we most wanted reviewed.

**P1 — `SixelStreamGuard` ignored DCS cancellation.** SwiftTerm treats CAN
(`0x18`) and SUB (`0x1A`) as cancels from *every* parser state — a global
"anywhere" rule in its transition table — and ST as a terminator before a DCS
handler is selected. The guard honoured none of them, so it stayed inside the
DCS while the terminal had returned to ground. `ESC P CAN q ~~ ESC \` is plain
text to the terminal and looked like a sixel payload to the guard, which wrote a
`-` into the middle of it. Fixed, with cancellation vectors run at every chunk
boundary like the positive cases.

The lesson is the one the guard's own design invites: **a shim that mirrors part
of another parser's state machine has to mirror its exits too.** Positive-path
tests cannot find that; only asking what the *other* parser does can.

**P2 — the ⌘W documentation contradicted the shipped binding.** Real, and worth
noting how it happened: Close Tab shipped on ⌥⌘W, Tim then asked for ⌘W, and the
implementation moved while two comments and this plan did not. Reconciled.

**P2 — no assertion on raw-versus-repaired routing.** Added, and it produced a
finding of its own. The review's rationale was that feeding repaired bytes to
the logger would invalidate persisted transcript offsets. Measured: it does not.
Every byte the guard inserts is inside a DCS body, and `ANSIStripper` drops DCS
bodies wholesale, so transcript content and `settledOffset()` are identical
either way. The terminal-path assertion is the one with teeth.

**Disproved by the review, worth recording:** the 8-bit DCS opener (`0x90`)
looked like a way around the guard, but SwiftTerm 1.15.0's ground fast path
consumes it as printable data and never dispatches a sixel handler. No guard
change needed; delete the guard on upgrade rather than extending it.

Also confirmed clean: appearance persistence (real-library upgrade rehearsal
passed against a copy of Tim's actual `portside.json`), the closed-tab ring's
in-memory guarantee, the never-connected axis, and the compatibility correction.

---

## Testing notes

Unchanged from 0.16, and all still live:

- **`CredentialStore` is not test-isolated** — it wraps the real Keychain with
  no seam. No new `SessionStore` path may reach it from the test-seam init.
  This destroyed a real credential once.
- **Back up `~/Library/Application Support/Portside/portside.json`** before any
  GUI pass. Opening sessions persists a workspace into the real library.
- **Verify a fix by reverting it and watching the test fail.** Adopted after the
  0.16 audit found "passing" tests that proved nothing. It is what established
  the Sixel one-liner above actually fixes anything.
- Prefer pure functions for anything rankable or computable, so it tests without
  a store or a GUI.
- Storage changes go through `UpgradeRehearsalTests` (gated on
  `PORTSIDE_UPGRADE_FIXTURE`) against a real library. Phase 1 and Phase 2 both
  touch persisted state, so both qualify.

## Why this order

Phase 0 is a crash and is nearly free, so it goes first regardless of theme.
Phase 1 is the release's headline and sets the visual vocabulary Phase 3 then
applies consistently. Phase 2 sits between them because both carry-overs add UI
that Phase 3 would otherwise have to restyle — the same reasoning that put the
visual pass last in 0.16, applied one level down.
