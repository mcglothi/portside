# ⚓ Portside

**A fast, beautiful, native macOS workbench for people who live on SSH.**

Portside rebuilds the [MobaXterm](https://mobaxterm.mobatek.net/) workflow —
saved sessions, folders, multi-host broadcast, macros — as a real Mac app,
for people whose Linux boxes are servers they connect *to*, from a Mac.
No Electron, no web view: SwiftUI and a native terminal, wrapped around the
OpenSSH you already have configured.

> Early days, moving fast. Built on the coast of Maine. ⛵

## Why

The gap on macOS isn't a terminal emulator — iTerm2 and WezTerm are excellent.
The gap is the *operator workflow* MobaXterm bundles: a session library you can
organize, broadcast execution across a fleet with guardrails, credential glue,
and file transfer, all in one surface. Portside exists to close that gap
without giving up native speed and macOS polish.

**Opinionated bets:**
- Win on **workflow density**, not protocol count. SSH-first, always.
- Multi-host execution deserves **safety UX as a flagship feature**, not a checkbox.
- **Local-first, self-owned state.** Your session library is a JSON file on
  your disk, not a cloud sync subscription.
- Lean on **OpenSSH itself** for transport — your `~/.ssh/config`, agent,
  keys, and `ProxyJump` chains work on day one, unmodified.

## What works today

- **Session library with folders** — organize hosts under `prod`, `nonprod`,
  `personal`, nested as deep as you like. Everything is editable in place.
- **`~/.ssh/config` import** — seeds the library on first launch (follows
  `Include` directives); re-import merges new hosts anytime.
- **MobaXterm migration** — import `.mxtsessions` files with their folder
  structure intact, and `.mxtmacros` files decoded into editable macros.
- **Native terminal tabs** — [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
  rendering, sessions run through the OpenSSH subprocess. Local shells too (⌘T).
- **MultiExec** — the MobaXterm feature you miss: tile every session in a
  grid and type into all of them at once. Per-terminal include toggles, a
  broadcast command bar for deliberate one-shot commands, and a loud orange
  banner so you always know when you're armed.
- **Environment badges & protected hosts** — tag sessions prod / staging /
  dev / personal for color-coded badges in the sidebar and tabs. Protected
  hosts stay **out of MultiExec by default** and require explicit
  confirmation to join a broadcast.
- **Macros** — named command sequences, run in the active terminal or across
  the whole MultiExec grid.

## Roadmap

- SFTP browser with drag/drop upload & download alongside the terminal
- Keychain + Touch ID credential glue (Vaultwarden references later)
- Port forwarding management UI
- Session restore / pinned workspaces
- Serial connections
- App Store-quality packaging, icon, updates

## Building

Requires Swift 6+ (Xcode Command Line Tools are enough):

```sh
# Run for development
swift run

# Build a standalone Portside.app
Scripts/make_app.sh
open build/Portside.app
```

## Status & contributions

Pre-1.0 and evolving quickly; expect sharp edges. Issues and ideas welcome —
especially from fellow MobaXterm refugees.
