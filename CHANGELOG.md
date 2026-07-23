# Changelog

All notable changes to Portside are documented here, newest first. This file
also feeds the in-app update changelog — see `Scripts/release.sh`.

## 0.14.0

Named credential profiles, pinned favorites, and a cumulative changelog on update.

- **Credential profiles** (Settings ▸ Profiles): reusable identities (user, SSH key, and/or password) applied in bulk to a multi-selection or a whole folder. A host holds a *live* reference to its assigned profile — rotating a profile's password or key updates every host using it immediately. The old single default password folds into this as the first profile ("Default").
- **Favorites**: pin hosts from a sidebar right-click (single or multi-selection), a hover star icon on each sidebar row, or a toggle in the session editor. Favorites show on the welcome/start page alongside "Jump back in," hidden while actively searching.
- Update prompts now show a cumulative changelog covering everything since the version you're updating from, not just the latest release's own notes — useful since auto-updaters often jump several versions at once.

## 0.13.0

SFTP polish, MultiExec one-step, and host key auto-accept.

- SFTP: auto-refresh on host switch, delete confirmation, a persistent drag/drop hint, and cd-following via OSC 7 for bash/zsh — one-click "Install Shell Integration" (idempotent remote append + optional immediate source) with automatic shell detection.
- MultiExec is one step: arming it gathers separate tabs into Grid View automatically if needed.
- Fixed toolbar tooltips (Files/Grid View/MultiExec), a Grid View restore bug, and the start-page tab's content not updating after connecting.
- Arrow-key navigation + Enter-to-launch in the welcome-screen search and the sidebar host filter.
- New: 'R' reconnects a dropped session; an optional "automatically accept new host keys" toggle (Settings ▸ Connection) that only skips the first-connection prompt, not protection against a known host's key changing later.
- Bigger, reliable click targets on the tab bar's + button and scroll chevrons.

## 0.12.0

Tab overflow scrolling, remappable shortcuts, and credential fixes.

- Tab strip grows </> chevrons to page through when tabs overflow the window.
- Every keyboard shortcut is remappable (Settings ▸ Shortcuts) with a click-to-record recorder, conflict detection, and reset to defaults. New shortcuts: Reopen Closed Tab (⇧⌘T), Toggle MultiExec (⇧⌘M), Toggle Grid View (⇧⌘G), Clear Buffer (⌘⌫), plus a ⌘←/⌘→ tab-cycling alias.
- Fixed a real bug where saved passwords could silently fail to write to the Keychain with no error shown.
- New app-wide default password (Settings ▸ Connection) as a fallback for hosts that opt in to saved passwords but don't have one of their own — pairs with the bulk "Save Password in Keychain" sidebar action.
- New Settings ▸ Updates: toggle automatic update checks, pick the interval, see last-checked time, check now.

## 0.11.0

Cursor styling, tab duplicate, smarter search, a real start page, and terminal right-click.

- Cursor shape (block/underline/bar) and blink, configurable in Settings ▸ Appearance, with a live preview.
- Duplicate Tab: right-click any tab to reopen its same host(s)/layout as a fresh tab.
- Sidebar host search now auto-expands folders containing matches.
- The tab bar's + button opens a "Welcome aboard" start page with a host search bar instead of a local shell; picking a host or a local shell from it takes over that same tab.
- Right-click inside a terminal for Copy/Paste.
- Fixed: dragging the window by its titlebar could hijack terminal scroll (jumping to the top and fighting further scrolling) and start a phantom selection.
- New Settings ▸ Connection option to default new sessions to "Save password in Keychain", plus a sidebar bulk action to enable it across an existing selection of hosts.

## 0.10.0

Terminal & tab polish.

- Keyboard tab switching: ⌘⇧[ / ⌘⇧] to cycle, ⌘1–9 to jump (Window menu).
- Pane zoom: ⌘⇧↵ maximizes the active pane to fill its tab and toggles back to the split.
- Reconnect in place: the "Session ended" bar can relaunch a dropped session in the same pane, keeping your layout.
- Tab bar: right-click a tab for Rename / Close / Close Others, plus a "+" new-tab button; background tabs show a dot when they have new output.
- Configurable alert color: set the MultiExec banner/border color in Settings ▸ Appearance ▸ Alert Color.

## 0.9.2

Bug fix: switching tabs now correctly changes the terminal shown.

A regression from the 0.9 split-panes work left a single-tab switch showing the previously selected session's terminal (splits and the grid were unaffected). Fixed.

## 0.9.1

Grid View — tile every open session into one grid to watch them at once, then arm MultiExec to broadcast across them.

- New Grid View toolbar button (⊞) gathers your open tabs into a tiled grid; toggle it off to split back into tabs. This restores the classic "group several sessions and drive them together" flow that 0.9.0's per-tab MultiExec had narrowed.
- MultiExec (broadcast) now enables only when a tab has 2+ panes, pointing you to Grid View first when your sessions are in separate tabs.

## 0.9.0

Native split panes.

- Split any tab with ⌘D (right) / ⌘⇧D (down); each new pane opens a local shell. Move focus by click or ⌘⌥←/→, close a pane with ⌘⇧W.
- MultiExec now lives in the split: arm a tab to broadcast keystrokes across its panes, with per-pane opt-in, protected-host guardrails, and the loud armed banner. Open a folder of hosts straight into an armed grid.
- Session restore reopens your whole pane layout, not just the tabs.
- A dead session now closes on ⏎ or a second ⌃D (MobaXterm-style).

## 0.8.0

Two big library/workspace features:

- Native Hosts sidebar (NSOutlineView): shift-click ranges, ⌘-click, and full keyboard multi-selection, plus drag hosts (single or multi) between folders.
- Session restore: reopen the tabs you had open when you last quit — Settings ▸ Terminal (off / ask / auto, default ask). Hosts reconnect, local shells start fresh, and MultiExec groups reopen disarmed so a relaunch never auto-broadcasts.
- Also enables GPU (Metal) rendering in packaged builds.

## 0.7.3

Enables Metal (GPU) rendering in packaged builds — our upstream fix for the SwiftTerm shader-bundle crash shipped in 1.15.0. Previously the Metal toggle silently stayed on CoreGraphics outside dev builds; it now works end-to-end.

## 0.7.2

Fixes last line truncated when returning to a session, and drag-to-select now auto-scrolls past the visible viewport.

## 0.7.1

Fixes a crash when opening Settings (resource bundle lookup failed on any machine other than the build machine). Also guards the experimental Metal renderer against the same crash; it stays on the standard renderer in packaged builds for now.

## 0.7.0

Configurable scrollback (default 10,000 lines), opt-in GPU (Metal) rendering, and a tested terminal-compatibility matrix. Fixes mosh's first connection on macOS by declaring Local Network usage. First release to ship a drag-to-install DMG alongside the ZIP.
