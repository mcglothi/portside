# ⚓ Portside

**A fast, native macOS workbench for people who live in remote terminals.**

Portside is a session manager and terminal for operators who run fleets of
Linux servers — plus their containers, Kubernetes pods, serial consoles, and
legacy telnet endpoints — from a Mac. Connect over OpenSSH or mosh, plug into a
switch with a native serial bridge, and keep every target in one searchable,
foldered library. Multi-host broadcast with guardrails, SFTP, port forwarding,
and credential glue all live in the same native window. No Electron, no web
view: SwiftUI and a real terminal, built around the tools you already use.

> Early days, moving fast. Built on the coast of Maine. ⛵

## Install

Grab the latest notarized build from [Releases](https://github.com/mcglothi/portside/releases/latest), or:

```sh
brew install mcglothi/tap/portside
```

Builds are Developer ID signed and notarized by Apple, and keep themselves
current via Sparkle. Requires macOS 14+.

![Portside's foldered session library with transport and environment badges](docs/screenshots/library.png)

*One foldered library for SSH and mosh hosts, containers, Kubernetes pods, serial consoles, and telnet endpoints — with transport and environment badges.*

![Quick Connect — a fuzzy-search command palette across the whole library](docs/screenshots/quick-connect.png)

*⌘K Quick Connect fuzzy-searches every saved target and recent connection at once.*

![A live SSH session in a native terminal tab, inspecting a deploy on a remote host](docs/screenshots/terminal.png)

*Real terminal tabs over the OpenSSH you already have configured — keys, agent, and `ProxyJump` chains included.*

![MultiExec broadcasting the same command to two hosts at once, with a safety banner and per-terminal include toggles](docs/screenshots/multiexec.png)

*MultiExec broadcasts your keystrokes to every included session — with a loud banner and per-terminal opt-in so you always know what's armed.*

![The SFTP file browser riding the same SSH session as the terminal, listing a remote directory](docs/screenshots/sftp.png)

*The SFTP browser rides the same SSH connection as your shell — no second login — with drag-and-drop transfer right beside the terminal.*

## Why

macOS has excellent terminal *emulators* — iTerm2 and WezTerm are superb. What
it lacks is a native **operator workflow**: a session library you can organize,
broadcast execution across a fleet with real safety UX, credential glue, file
transfer, and container/Kubernetes access — in one fast surface. Portside
exists to fill that gap without giving up native speed and macOS polish.

**Opinionated bets:**
- Win on **workflow density**, not protocol count. SSH-first, with the console
  transports operators still need close at hand.
- Multi-host execution deserves **safety UX as a flagship feature**, not a checkbox.
- **Local-first, self-owned state.** Your session library is a JSON file on
  your disk, not a cloud sync subscription.
- Lean on **OpenSSH itself** for transport — your `~/.ssh/config`, agent,
  keys, and `ProxyJump` chains work on day one, unmodified.

## What works today

- **Session library with folders** — organize hosts under `prod`, `nonprod`,
  `personal`, nested as deep as you like. Everything is editable in place.
- **Containers & Kubernetes as first-class sessions** — save a docker/podman
  container or a `kubectl` pod (context-aware for NKP, GKE, and any kubeconfig)
  the same way you save a host. It runs on this Mac or through an SSH jump host,
  and shows up in the library, Quick Connect, and recents like everything else.
  Browse live `docker ps` / `kubectl get pods` from the editor so you never
  have to remember a churning name.
- **`~/.ssh/config` import** — seeds the library on first launch (follows
  `Include` directives); re-import merges new hosts anytime.
- **Import from MobaXterm** — bring over `.mxtsessions` / `.mxtmacros` files
  with their folder structure intact.
- **Export & import** — back up or move your library as portable JSON;
  sessions (with folders) and macros export separately and re-import into any
  Portside install. Passwords stay in the Keychain and never travel.
- **Native terminal tabs** — [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
  rendering across OpenSSH, mosh, serial, and telnet sessions. Local shells too
  (⌘T). Find in scrollback with ⌘F, per-tab zoom with ⌘+/−/0. See the tested
  [compatibility matrix](docs/COMPATIBILITY.md) for exactly what's supported.
- **Terminal appearance & behavior** — pick from hundreds of built-in themes and
  Nerd Fonts (or import your own), set a configurable scrollback depth (default
  10,000 lines), and optionally switch on GPU (Metal) rendering — all in
  Settings, applied live to open terminals.
- **Mosh roaming** — opt any SSH host into mosh for sessions that survive sleep
  and network changes. Portside respects your SSH alias, key, port, and saved
  password during bootstrap, and falls back to SSH when mosh is unavailable.
- **Native serial consoles** — connect directly to live `/dev/cu.*` devices
  without spawning `screen`. Choose baud rate, data bits, parity, stop bits,
  and flow control; logging, run-on-connect, and MultiExec work on the same path.
- **Telnet for legacy endpoints** — save host and port, handle RFC 854 option
  negotiation cleanly, and use the same terminal, logging, and MultiExec tools.
  Telnet sessions carry a prominent **UNENCRYPTED** badge.
- **Quick Connect (⌘K)** — a fuzzy-search command palette over the whole
  library; empty query lists recent hosts so it doubles as fast reconnect.
- **MultiExec** — tile every session in a grid and type into all of them at
  once. Arming it is one step: with several separate tabs open it gathers
  them into Grid View automatically instead of requiring that first. Per-
  terminal include toggles, a broadcast command bar for deliberate one-shot
  commands, and a loud orange banner so you always know when you're armed.
- **Environment badges & protected hosts** — tag sessions prod / staging /
  dev / personal for color-coded badges in the sidebar and tabs. Protected
  hosts stay **out of MultiExec by default** and require explicit
  confirmation to join a broadcast.
- **Macros** — named command sequences, run in the active terminal or across
  the whole MultiExec grid. Per-host **run-on-connect** commands too.
- **SFTP browser** — per-session remote file pane riding the same SSH
  connection (no re-auth), with drag/drop upload and drag-out download (a
  persistent hint keeps that discoverable), automatic refresh when you
  switch hosts, and a confirmation before deleting anything. It follows
  `cd` in the live shell for bash/zsh (via the OSC 7 "current directory"
  escape sequence) — one-click "Install Shell Integration" appends the
  needed one-liner to the host's `.bashrc`/`.zshrc` over ssh (idempotent,
  with an option to `source` it into the session immediately), and
  auto-detects which shell you're running so you don't have to know.
- **Port forwarding** — saved `-L` / `-R` / SOCKS tunnels with live status,
  start/stop, and launch-at-startup, tunneled through any host in the library.
- **A welcome screen that searches** — the tab bar's + button opens a
  "welcome aboard" tab with a live host search bar, arrow-key navigation and
  Enter to launch, focused automatically so you can type right away (picking
  a host or starting a local shell takes over that same tab); the
  whole-window empty state and the "jump back in" recent-connections list
  work the same way. The sidebar's own host filter supports the same
  arrow-key navigation into its results.
- **Tabs, tuned for a lot of them** — right-click a tab to duplicate it (same
  host(s)/split layout, fresh sessions) or reopen the last one you closed
  (⇧⌘T); an overflowing tab strip grows </> chevrons to page through it
  instead of requiring you to know a keyboard shortcut. A dropped session
  reconnects with a single keystroke (`R`) from its "session ended" bar.
- **Every shortcut remappable** — Settings → Shortcuts lists every keyboard
  shortcut with a click-to-record rebind, conflict detection, and per-row or
  one-click reset to defaults. New default shortcuts: Reopen Closed Tab,
  Toggle MultiExec, Toggle Grid View, and Clear Buffer.
- **Cursor styling** — block, underline, or bar, with independent blink,
  in Settings → Appearance with a live preview.
- **Copy/paste from a right-click** — a context menu in every terminal,
  alongside the existing ⌘C/⌘V.
- **Session logging** — per-host log folders with compression and search.
- **Keychain passwords** — per-host saved passwords supplied to ssh
  automatically; nothing ever lands in the JSON library. An app-wide default
  password (Settings → Connection) covers hosts that opt in to saving a
  password but don't have one of their own yet — pairs with the sidebar's
  bulk "Save Password in Keychain" action for a multi-selection of hosts, so
  a big batch of imported hosts sharing one login doesn't need per-host
  passwords typed in one at a time.
- **Auto-updates** — Sparkle-powered in-app updates from GitHub Releases,
  with the check frequency and on/off switch configurable in
  Settings → Updates.
- **Host key handling** — an optional "automatically accept new host keys"
  toggle (Settings → Connection) skips the first-connection prompt without
  weakening protection against a *known* host's key changing later, which
  still hard-fails exactly as ssh normally does.

## Roadmap

### Shipped recently

- ✅ Configurable scrollback, GPU (Metal) rendering, a tested
  [terminal-compatibility matrix](docs/COMPATIBILITY.md), native sidebar
  multi-selection with drag-to-folder, session restore, and split panes.
- ✅ Tab bar polish — keyboard tab switching (⌘⇧[/], ⌘1–9, and a ⌘←/⌘→
  alias), pane zoom (⌘⇧↵), reconnect-in-place from the "session ended" bar,
  a tab context menu (rename / duplicate / close / close others), overflow
  chevrons, and a configurable MultiExec alert color.
- ✅ Fully remappable keyboard shortcuts, cursor shape/blink, right-click
  terminal copy/paste, the searchable welcome/start-page tab, app-wide and
  bulk password handling, and configurable auto-update checking.
- ✅ SFTP browser polish — auto-refresh on host switch, delete confirmation,
  a persistent drag/drop hint, and `cd`-following with one-click shell
  integration install + shell auto-detection (bash/zsh). Plus MultiExec
  arming in one step, a Grid View restore bugfix, working toolbar tooltips,
  an optional auto-accept-new-host-keys toggle, arrow-key navigation in both
  the welcome-screen search and the sidebar filter, and single-keystroke
  session reconnect.

### Next up

- Pinned favorites on the welcome/start page, shown alongside "Jump back
  in" — hidden while actively searching, same as recents are today. Pinning
  itself: a sidebar right-click ("Add/Remove Favorites," single host or a
  multi-selection at once — mirrors the existing bulk "Save Password in
  Keychain" action), a hover star icon directly on each sidebar row and
  search result for a one-click toggle, and a Favorite toggle in the
  session editor next to Environment/Protected host.
- Sidebar: an Expand All / Collapse All action for folders.
- App UI appearance (light / dark / follow system) — distinct from the
  terminal's own color theme, which stays per-appearance-profile as today.
- Bulk-tag environment (prod/staging/dev/personal) across a multi-selection
  or a whole folder, alongside the existing bulk "Save Password in Keychain"
  action — aimed at managing a large (500+) imported host inventory.
- **Named credential profiles** — multiple reusable identities (username +
  SSH key and/or password), managed in Settings and applied in bulk to a
  multi-selection or a folder, so a fleet split across a handful of shared
  accounts (AD, Ansible/Nutanix service accounts, IPMI/vendor consoles,
  etc.) doesn't need per-host credential entry. A host holds a *live*
  reference to its assigned profile rather than a one-time copy, so
  rotating a profile's password or key updates every host using it
  immediately — the actual point, for forced rotations across a fleet. The
  existing single default password (Settings ▸ Connection) folds into this
  as the first profile ("Default") rather than staying a second, parallel
  mechanism.
- **Connection history** — grow today's capped 20-entry recents list into a
  real, searchable, browsable history (its own view, separate from Quick
  Connect), with a "clear history" action and a way to exclude protected
  hosts from being logged at all. Rolls in:
  - Browsable "recently closed tabs" — reopen any of the last N closed
    tabs/layouts, not just the single most recent one (⇧⌘T today).
  - Frecency-ranked Quick Connect — blend frequency and recency instead of
    pure recency, so a host you hit constantly outranks one touched once
    yesterday.
  - Stale-host detection — surface hosts not connected to in 90+ days,
    pairing with the coverage-view idea below.
- **Inventory coverage view** — a quick way to see which hosts still have no
  environment tag, no credential profile, or no saved password, so a big
  bulk pass across a large library can be verified rather than guessed at.
- **SFTP: open with default app + auto-reupload** — double-clicking a remote
  file downloads it to a temp location and opens it in its default app
  (there's no live mount); saving in that app watches the temp file (FSEvents)
  and silently re-uploads it back to the host, so it feels like editing the
  remote file directly rather than a manual download/upload round-trip.
- **SFTP: host-to-host file copy in Grid View** — drag a file from the one
  shared SFTP pane onto a *different* pane/tab (not its own file browser —
  there's only one shared pane today, tied to whichever pane is focused) to
  copy it directly to that host, landing in whatever directory that
  session's shell is currently sitting in. The live-current-directory
  tracking this needs already landed (OSC 7, used by the SFTP pane's own
  `cd`-following) — what's left is the new drop target and the actual
  transfer, which relays through a temp file behind the scenes (reusing the
  existing download/upload code) rather than a true zero-hop pipe between
  the two hosts.

### Later

- Per-profile font/theme choices (appearance is global today).
- Font ligatures and inline image protocols (Sixel / iTerm2) are current
  SwiftTerm limitations, tracked in the compatibility matrix rather than
  promised here. Shell integration / prompt markers (OSC 133) is likewise
  blocked upstream — SwiftTerm implements only OSC 8 hyperlinks.

- Touch ID gating for saved credentials (Vaultwarden references later)
- Named / pinned layout presets
- tmux control-mode (`-CC`) integration — native splits backed by a durable
  remote tmux session

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
especially from fellow operators who live in the terminal.
