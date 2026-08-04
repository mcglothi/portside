# Host Sidebar on NSOutlineView — 0.8 Plan (closes #8)

Tracking issue: [#8 Host Selection & Movement](https://github.com/mcglothi/portside/issues/8)

## Goal
Give the Hosts sidebar native multi-selection (shift-click range, shift-arrow,
⌘A) and reliable drag-to-folder, by moving it off SwiftUI `List` onto AppKit's
`NSOutlineView`.

## Why a rewrite, not a patch
`SidebarView.hostsList` is a SwiftUI `List` with a hand-managed `Set<UUID>`
selection and manual tap gestures. The inline comment records why: native
`List(selection:)` fought the row's own click/drag handling, so drag-to-folder
was pulled and a manual selection model was adopted. That workaround can do
⌘-click toggle but structurally cannot do range selection or reliable drag —
exactly what #8 asks for. `NSOutlineView` does all of it natively.

## Scope decisions (locked)
- **Drag = folder moves only.** Drag single/multi hosts to drop into a folder
  or back to top level. Sort stays alphabetical (`FolderTree.byName`). Manual
  per-entry ordering is a deliberate non-goal for 0.8 (would need an `order`
  field on `SessionEntry`, a JSON migration, and replacing alphabetical sort
  everywhere — separate follow-up).
- **Selection = hosts only.** Folders expand/collapse and keep their own
  right-click menu, but do not enter the multi-selection set. Keeps
  "Open N Selected" / move / delete semantics clean.

## What stays unchanged
SessionStore persistence model; `FolderTree`/`FolderNode`; `SessionEditorView`
and all sheets/alerts/importers/exporters in `SidebarView`; the Macros and Tools
sections (still SwiftUI `List`); `TransportBadge`/`EnvironmentBadge`; empty-state
overlay.

## New file: `Sources/Portside/Views/HostOutlineView.swift`
`NSViewRepresentable` wrapping `NSScrollView` + `NSOutlineView`.

1. **Item model** — `final class SidebarNode` reference type: `.folder(path)` /
   `.entry(id)`. Reference identity is what NSOutlineView needs; reconcile nodes
   by stable key (folder path / entry UUID) across reloads so expansion
   survives. `autosaveExpandedItems = true` + `autosaveName`, persistent object =
   folder path → folder expansion persists across launches (bonus over today).

2. **Coordinator** = `NSOutlineViewDataSource` + delegate:
   - **Rows**: `NSHostingView` embedding a visuals-only `SessionRow` (drop the
     tap/selection gestures — selection is native now). Reuses badge views.
     `usesAutomaticRowHeights = true` for two-line entries.
   - **Selection**: `shouldSelectItem` allows entry rows only; native selection
     bound back to the existing `Set<UUID>` so the toolbar "Open N Selected"
     keeps working untouched.
   - **Drag**: `pasteboardWriterForItem` writes the entry UUID;
     `validateDrop` accepts a drop on a folder row or the root; `acceptDrop`
     moves all dragged/selected ids at once.
   - **Double-click** → connect (`doubleAction`); **Return** → connect
     selection; **Delete key** → delete selection (confirm when >1).
   - **Context menu**: native `NSMenu` in `menuNeedsUpdate` from the clicked row
     + selection, reproducing today's actions (Connect / Connect N / Edit /
     Duplicate / Move to ▸ / Delete + folder actions). SwiftUI-side actions
     (open editor sheet) invoked through closures passed from `SidebarView`.

3. **Reload**: `updateNSView` rebuilds the tree from the already-filtered
   entries, snapshots selected ids + expanded paths, `reloadData()`, restores.

## SessionStore additions
- `move(entryIDs: Set<UUID>, toFolder:)` — batch move, one `save()`.
- `delete(ids: Set<UUID>)` — batch delete, one `save()`.
Existing single-entry ops stay.

## SidebarView.hostsList
Shrinks to: SwiftUI search field + `HostOutlineView(...)` + empty-state overlay.
Existing closures (connect, edit, openSelected, folder ops) pass straight into
the representable.

## Testing
- Unit (fills a current gap — no store/folder tests exist): batch
  `move(entryIDs:)` / `delete(ids:)`; `FolderTree` reconciliation keying.
- Manual (`/run` on packaged app): shift-click range, shift-arrow, ⌘A, drag one
  host to folder, drag multi-selection to folder, drag to top level,
  context-menu move/delete/connect on multi-selection, expansion persistence
  across relaunch, filter-while-selected.

## Risk points
- `NSHostingView` row sizing/recycling jank at scroll → fall back to native
  `NSTableCellView`.
- Reload-storm on filter keystrokes → debounce or diff.
- Environment bridging (`store`/`sessions`) into coordinator → pass as plain
  refs, not `@EnvironmentObject`, inside the representable.
