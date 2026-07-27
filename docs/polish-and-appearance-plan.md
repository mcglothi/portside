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
Added File ▸ Close Tab, bound to ⌥⌘W — *not* ⌘W, which is Close Window and has
never belonged to Portside, and not ⇧⌘W, which is already Close Pane. It is
remappable like every other shortcut if the terminal-app convention (⌘W closes
the tab) is what you want.

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

- **Empty states.** The file browser, coverage view and history browser all
  render blank today. Each needs to say what would fill it and how.
- **Density and spacing consistency** across the newer views, which were built
  independently and don't quite agree.
- **Sidebar and tab-strip chrome.**
- **Iconography consistency.**

This is the part with no hard acceptance test, so it is also the part most
likely to expand. Timebox it and cut from the bottom of the list.

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
