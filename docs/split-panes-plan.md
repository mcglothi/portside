# Split Panes — 0.9 Plan

The 0.9 anchor. Grounded in prior-art research (iTerm2 tmux `-CC`,
WezTerm/Kitty/Ghostty native splits, iTerm2 broadcast-input) — see the
"Prior art" section.

## The framing that shapes everything
"Split panes" is really two independent features that share one substrate:

- **(A) Local split panes** — a tab becomes a *tree* of leaf-panes joined by
  H/V split nodes. The ergonomic feature.
- **(B) tmux control-mode (`-CC`) integration** — remote tmux emits a text
  protocol that we render as native splits; durable, survive-disconnect
  remote sessions. iTerm2's signature feature and the most on-brand endgame
  for a remote-ops workbench.

Both render onto the **same pane-tree model**. 0.9 builds (A) and the tree;
(B) plugs into the same tree in a later release. Don't attempt (B) first.

## Locked decisions
- **MultiExec is absorbed into the pane tree.** A MultiExec group *is* a split
  layout: arming broadcast applies to the panes of the active tab, with the
  loud banner on top and per-pane opt-in/protected-host guardrails moved onto
  each pane. The separate full-area `MultiExecView` grid goes away.
- **Session restore extends to the layout tree.** `WorkspaceSnapshot` grows
  from a flat item list to a per-tab pane tree (see Restore section).
- **No named/saved layout presets in 0.9** (deferred; pairs naturally with the
  restore-tree later).
- **tmux `-CC` is out of scope for 0.9** — designed-for, not built.

## Current architecture (what changes)
Today (`SessionArea.swift`): `SessionManager` holds a flat
`sessions: [TerminalSession]` + `selectedID`. A tab = one session. The area
branches three ways: empty state, `MultiExecView` (a `LazyVGrid` of *all*
sessions when `multiExecActive`), or `TabBar` + the one selected
`TerminalPane` in an `HSplitView` (with the optional SFTP pane). Everything
keys off `sessions`/`selectedID`: `TabBar`, close logic, the Enter-to-close key
monitor, zoom/find/SFTP (`selected`), and restore (`currentWorkspace`).

The refactor introduces a **Tab** that owns a **pane tree**, and reroutes those
consumers through the active pane.

## Model
```
final class Tab: Identifiable, ObservableObject {
    let id = UUID()
    @Published var root: PaneNode          // tree of this tab's panes
    @Published var activePaneID: UUID      // focused leaf — drives find/zoom/SFTP/close/broadcast
    @Published var broadcastArmed = false  // MultiExec, per-tab now
}

indirect enum PaneNode: Identifiable {
    case leaf(TerminalSession)
    case split(id: UUID, orientation: Orientation, children: [PaneNode], fractions: [CGFloat])
    enum Orientation { case horizontal, vertical }
}
```
- `SessionManager` moves from `sessions: [TerminalSession]` + `selectedID` to
  `tabs: [Tab]` + `selectedTabID`. The flat live-session set (for lifecycle) is
  derived by walking every tab's leaves.
- **Active-pane** tracking replaces `selected`: `selectedTab.activePaneID` is
  the focused terminal that find/zoom/SFTP/close/broadcast act on.

## Rendering (`SessionArea` rewrite)
A recursive `PaneTreeView(node:)`:
- `.leaf(session)` → the existing `TerminalPane` (unchanged), plus a thin focus
  ring on the active pane and a per-pane broadcast opt-in chip when armed.
- `.split(h, …)` → `HSplitView` of child views; `.vertical` → `VSplitView`.
This one view replaces *both* today's single-pane `HSplitView` and the whole
`MultiExecView` grid. The SFTP pane stays a sibling of the active leaf.

## MultiExec, unified
- Arming broadcast (`broadcastArmed` on the tab) shows the loud orange banner
  across the tab; keystrokes in any included pane mirror to the others — the
  existing `mirrorUserInput`/`multiExecTargets` machinery, rescoped from
  "all sessions" to "the active tab's included leaves."
- Per-pane include toggle + protected-host confirmation move from
  `MultiExecTile` onto pane chrome (a small corner control).
- `connectAll(group, multiExec: true)` now opens the group as **one tab split
  into N panes, armed** — the "launch a fleet and drive it, visually" workflow,
  which is the novel differentiator.

## Commands / keybindings
- **⌘D** split active pane vertically (new pane right), **⌘⇧D** horizontally
  (new pane below); "split at tab top-level" variant later if wanted.
- **⌘⌥←/→/↑/↓** move focus between panes.
- **⌘W** closes the active *pane* (closes the tab when it's the last pane).
- Existing find/zoom/Enter-to-close retarget to the active pane.

## What a new split connects to (LOCKED: local shell)
A new pane opens **a local shell** — zero-friction, never blocks on a network
connect, matches every other terminal's default. **Duplicate active** (same
host, new connection) and **pick a host** are available via a split menu /
modifier, not the default gesture.

## Restore (extend, don't replace)
`WorkspaceSnapshot` grows a tree form: each tab persists its `PaneNode`
structure (leaf = `host(id)` | `localShell`, plus split orientation/fractions)
and `activePaneID` position. The existing pure planner extends to rebuild a
tree; `restore` walks it, creating panes and re-splitting. Flat v1 snapshots
still decode (a flat list = a tab of single-leaf tabs). Broadcast stays
disarmed on restore, as today.

## Files touched
- **New** `Models/PaneNode.swift` (+ `Tab`), `Views/PaneTreeView.swift`.
- `Services/SessionManager.swift` — tabs/active-pane model; split/close/focus;
  rescope broadcast to the active tab; derive the live-session set.
- `Views/SessionArea.swift` — recursive render; delete `MultiExecView` grid
  (fold into the tree) but keep the macro/broadcast command bars as tab chrome.
- `Views/TabBar.swift` — tabs of trees, not sessions.
- `Models/WorkspaceSnapshot.swift` — tree form + planner extension.
- `PortsideApp.swift` — split/focus menu commands.

## Testing
- Unit: `PaneNode` split/close/focus-navigation math (pure tree ops);
  `WorkspaceSnapshot` tree round-trip + flat-v1 back-compat + planner.
- Manual (`/run`): split V/H, nested splits, focus nav, close pane vs. tab,
  arm broadcast across a split and confirm mirroring + protected-host block,
  open a host folder as an armed split, quit/relaunch → layout tree restores.

## Risks
- **Scope of the model refactor** — flat→tree touches every `sessions`/
  `selected` consumer. Mitigate: land the model + single-leaf rendering first
  (behavior-identical to today), then add splitting, then fold in MultiExec.
- `HSplitView`/`VSplitView` nesting + fraction persistence can be fiddly; may
  need a custom splitter if SwiftUI's divider dragging misbehaves when nested.
- Active-pane focus vs. SwiftTerm first-responder — wire focus explicitly.

## Prior art (research 2026-07-21)
- **tmux `-CC`**: `TmuxGateway` parses `%output`/`%layout-change`/`%window-add`/
  `%begin|%end|%error`/`%pause|%continue`; layout strings like
  `ce55,204x53,0,0{102x53,0,0,1,101x53,103,0,2}` encode the geometry tree;
  `refresh-client -C WxH` sets client size; flow control via `%pause`. Large
  lift (protocol + layout parser + flow control + terminfo). Deferred, but the
  0.9 tree model is deliberately shaped to accept it later.
- **WezTerm/Kitty/Ghostty**: direction-based `SplitPane{Up|Down|Left|Right}`,
  "split at top level" option; Ghostty renders splits with native macOS
  components (same philosophy as our sidebar); power users want named,
  cycleable layout presets (deferred here).
- **iTerm2 broadcast-input**: broadcast to panes with a red-stripe warning —
  Portside already has stronger guardrails (armed banner, per-pane opt-in,
  protected hosts), which is why folding MultiExec into the split tree is a
  genuine differentiator rather than a copy.

## Explicitly out of scope for 0.9
Named/saved layout presets; tmux `-CC` integration; per-pane working-directory
capture. All are natural follow-ups on this substrate.
