# Contributing

Bug reports are the most valuable thing you can send. Portside is used daily
against real fleets, and nearly every defect worth fixing so far has come from
someone doing ordinary work and noticing something wrong — not from a test.

## Reporting

Open an issue. The template asks for a version, a macOS version, and steps; the
steps matter most. If it only happens sometimes, say what you were doing when
it did — "only when the destination subfolder was empty" is the kind of detail
that turns an intermittent report into a one-line fix.

If Portside quit unexpectedly, attach the crash report from
`~/Library/Logs/DiagnosticReports/`. Please don't paste your library: it
contains hostnames and usernames. A description of its shape is plenty.

Security vulnerabilities go through [SECURITY.md](SECURITY.md), privately.

## Building

```sh
swift build          # or: swift run
swift test
```

Swift 6 toolchain, macOS 14+. `Scripts/make_app.sh` produces a signable
`.app` bundle; you don't need one to develop.

Run a dev build against a throwaway library rather than your real one:

```sh
PORTSIDE_LIBRARY_DIR=/tmp/portside-dev swift run
```

Seeding from `~/.ssh/config` is deliberately off in that mode, so the isolated
library stays empty until you put something in it, and your real hosts stay out
of screenshots.

## Pull requests

Three things are checked, and all three are enforced rather than requested:

1. **`swift test` passes.** New behaviour comes with tests. The interesting
   ones here tend to be about a rule rather than a function — that reordering a
   tab doesn't disturb the selection, that an excluded pane stays excluded when
   moved.
2. **No new strict-concurrency warnings.** `bash Scripts/strict-concurrency-check.sh`
   holds a per-file baseline. Fix them rather than raising it; raise it
   deliberately, with a reason, if they're genuinely unavoidable.
3. **`CHANGELOG.md` has an entry**, copied to
   `Sources/Portside/Resources/CHANGELOG.md`. The app ships that copy and shows
   it in About Portside, so a stale one answers "what changed" wrongly. A test
   and a release gate both check.

## What the code is like

A few conventions that aren't obvious from a diff:

- **Comments say why, not what.** Especially where the obvious approach is
  wrong. A lot of this codebase is one-line fixes wrapped in a paragraph
  explaining the afternoon that found them; that paragraph is the valuable part.
- **Anything visual is verified by running the app and looking at it.** Several
  bugs here compiled, passed, and were plainly wrong on screen — a drag handle
  sitting on top of the terminal's first line, an empty-state overlay drawn over
  a populated sidebar. If a change touches the UI, say in the PR that you looked
  at it.
- **The library layer gets the most suspicion.** It has produced the most
  data-loss bugs, and "no known way to lose or corrupt a library" is a 1.0 gate
  (see [docs/road-to-1.0.md](docs/road-to-1.0.md)). Changes to persistence,
  import/export or migration want tests against realistic data, not toy data.

## Scope

Portside is opinionated about being a native macOS app that leans on the
OpenSSH you already have, rather than reimplementing it. Features that would
mean shipping our own crypto, a cloud service, or an Electron-shaped dependency
are out of scope regardless of merit. [docs/road-to-1.0.md](docs/road-to-1.0.md)
says what's planned before 1.0 and what's deliberately after it — worth a look
before starting something large.
