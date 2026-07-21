# Session Restore / Workspaces — 0.8 Plan

Second 0.8 feature alongside the NSOutlineView sidebar
(docs/host-sidebar-outline-plan.md). Reopen the sessions you had running when
you last quit, so Portside comes back the way you left it.

## Goal
On launch, restore the set of open sessions (order, selection, MultiExec group
membership) from the last run. Additive — no change to the session/tab core.

## Why it's a small–medium lift
The model already carries the hooks:
- `SessionManager.sessions: [TerminalSession]` is the ordered tab list;
  `selectedID` is the active tab; `multiExecActive` is the group arm state.
- `TerminalSession.entry: SessionEntry?` — non-nil for every host/container/
  k8s/serial/telnet session (the entry's `id` is the stable restore key), nil
  for a local shell.
- `TerminalSession.includedInMultiExec` is per-session (defaults to
  `!entry.isProtected`).
- Every session is (re)created through exactly two paths: `connect(to: entry)`
  and `openLocalShell()`. Restore just replays those.

No SwiftTerm/AppKit depth, no structural change (unlike split panes).

## Data model — `Models/WorkspaceSnapshot.swift`
```
struct WorkspaceSnapshot: Codable, Equatable {
    var items: [Item] = []          // ordered, matches tab order
    var selectedIndex: Int?         // which tab was active (position, not UUID)
    struct Item: Codable, Equatable {
        enum Kind: Codable, Equatable { case host(UUID); case localShell }
        var kind: Kind
        var includedInMultiExec: Bool
    }
}
```
- `host(UUID)` is `entry.id`. `selectedIndex` is a **position**, not a UUID —
  replay mints new session ids.
- `multiExecActive` is deliberately **not** stored (see safety note below).
- Tolerant Codable, like the rest of the library; lives in
  `SessionStore.Document` as `workspace: WorkspaceSnapshot?`.

## Snapshot timing (continuous, no app-quit hook)
Rebuild the snapshot from `SessionManager` state and persist it via
`store.saveWorkspace(_:)` on the user-paced events that change it: session
open, close, selection change, MultiExec-membership toggle. These are all
low-frequency, so a direct full-document save each time is fine (matches how
every other setting persists today). No fragile `applicationWillTerminate`
dependency — if the app is killed, the last good snapshot is already on disk.

## Replay on launch — `PortsideApp.onAppear`
After settings are wired and if `restoreMode != .off` and the snapshot is
non-empty:
- **auto** → replay immediately.
- **ask** → small prompt ("Restore N sessions?" · Restore / Start Fresh).

Replay (a pure planner turns the snapshot + current library into an ordered
action list, so it's unit-testable without spawning terminals):
- `host(id)` → `store.entry(id:)`; if it still exists, `connect(to:
  store.resolved(entry))`, else **skip** (entry was deleted).
- `localShell` → `openLocalShell()`.
- Apply each item's `includedInMultiExec` to the created session.
- After the batch, set `selectedID` to the session at `selectedIndex`.
- **Stagger** ssh spawns (incremental `asyncAfter`) so a 10-host workspace
  doesn't fire ten simultaneous handshakes / password prompts.

Edge cases, all already handled by existing paths:
- Reconnect auth → reuses Keychain + askpass automatically.
- Vanished serial device / unreachable telnet → existing "Session ended"
  overlay + descriptive message; no special-casing.
- Post-connect commands (run-on-connect, container/pod exec) correctly
  re-fire on restore.

## Safety: MultiExec starts disarmed
Restore the **group membership** (`includedInMultiExec` per tab) but always
launch with `multiExecActive = false`. Auto-broadcasting keystrokes into a
freshly reconnected group of prod hosts on every launch is a footgun; the user
re-arms deliberately. (This is why `multiExecActive` isn't in the snapshot.)

## Preference — `restoreMode` (LOCKED: default ask)
New `enum RestoreMode { case off, ask, auto }` on `TerminalSettings` (tolerant
Codable already there), surfaced as a picker. **Default = ask** (safe +
discoverable; off/auto available in Settings). Settings placement: the existing
**Terminal** tab, or a small new **General** tab — minor, decide at build time.

## Scope (LOCKED: everything, tolerant)
Restore all session types: hosts (ssh/mosh/telnet/container/k8s), local shells
(as fresh login shells), and serial (attempt the connect; a missing device
falls through to the existing "session ended" overlay). Deleted library entries
are skipped. Nothing is excluded up front.

## Files touched
- **New** `Models/WorkspaceSnapshot.swift` — Codable model + pure replay planner.
- `Models/TerminalSettings.swift` — `restoreMode`.
- `Services/SessionStore.swift` — `workspace` in Document + `saveWorkspace(_:)`.
- `Services/SessionManager.swift` — `currentWorkspace` builder; `restore(_:
  resolve:)`; fire snapshot-persist on open/close/select/multiExec change.
- `PortsideApp.swift` — launch replay + ask prompt; wire change → saveWorkspace.
- Settings view — restoreMode picker.

## Testing
- Unit (pure, no terminals): `WorkspaceSnapshot` Codable round-trip + tolerant
  decode; the replay planner (maps items→actions, skips deleted entries, maps
  `selectedIndex`, carries MultiExec membership). Uses the injectable-fileURL
  `SessionStore` init from the sidebar work.
- Manual (`/run`): open a mix (ssh + local shell + serial-emulated + a
  MultiExec group), quit, relaunch → correct order, selection, membership,
  MultiExec disarmed; delete an entry then relaunch → that tab is skipped, rest
  restore; restoreMode off/ask/auto behave.

## Risk points
- Snapshot write frequency — user-paced events only; if it ever churns,
  coalesce on a short debounce.
- Selection restore before all staggered sessions exist — set `selectedIndex`
  against the final ordered list, or re-assert after the last spawn.
- `ask` prompt timing vs. window setup — present after `onAppear` settle so it
  doesn't race the first render.
