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

## Phase 1 — App appearance

**Locked with Tim during 0.16 planning, unchanged:** the setting lives next to
the terminal colour theme in Settings ▸ Appearance, clearly separated. Adjacent
so the relationship is obvious, explicitly independent so a dark terminal in a
light app (or the reverse) stays possible. The two must never be coupled.

Implementation is `NSApp.appearance` driven from a persisted enum on
`TerminalAppearance` — tolerant Codable, default `.followSystem`, following the
same decoding precedent as `WorkspaceSnapshot`.

The one thing to watch is SwiftTerm's own view. The terminal draws its own
background from the colour theme, not from the effective appearance, so the
seam between app chrome and terminal is where a mismatch will show — check the
split divider, the tab strip under an active tab, and the SFTP pane's border
against both appearances before calling it done.

---

## Phase 2 — Carry-overs

Both were cut from 0.16 and named in the README, so they are promises already
made.

### Browsable recently-closed tabs

Reopen any of the last N closed tabs, not just the single most recent (⇧⌘T
today). The restore planner already rebuilds a `PaneNode` tree from a
`WorkspaceSnapshot`, so a closed tab is a snapshot to retain rather than
anything new to model — the work is a bounded ring of snapshots and a menu to
pick from, not a new persistence format.

Decide: does the ring survive app restart? Session restore already persists a
workspace, so the machinery exists, but a closed-tab history that outlives a
quit is a different privacy proposition than one that doesn't — it is a record
of what you had open. Default it to in-memory unless there's a reason not to.

### A "never connected" coverage category

Distinct from stale. Today a host nobody has ever opened and a host untouched
for 90+ days land in the same bucket, and they mean opposite things: one is an
import that was never verified, the other is drift. The coverage view already
separates *reported* from *scored* axes, so this slots in as a reported axis
without putting 100% out of reach.

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
