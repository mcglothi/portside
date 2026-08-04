# Groups — a tab you can reopen

A group is a named tab: the panes it held and how they were arranged. Open it
and the whole grid comes back.

The case it exists for is the eight boxes you always open together. Opening
them one at a time and re-splitting the panes is a minute of work you do
several times a day, and the arrangement itself carries meaning — which host is
where is how you read the grid at a glance.

## Saving one

Three places, all doing the same thing:

- **File ▸ Save Tab as Group…**
- **The tab's context menu** — the thing you want to save is usually the tab
  you're looking at, and right-clicking it is where you'd reach.
- **A button on the MultiExec banner** — assembling a group and arming it are
  usually the same motion.

The sheet asks for a name and a folder. The folder is a path like `prod/web`,
the same shape hosts use; empty means the top level. Re-saving an existing
group offers its current folder, so overwriting one doesn't quietly move it.

## Opening one

Double-click it in the sidebar, or pick it from ⌘K. Groups appear in Quick
Connect alongside hosts, showing their pane count and folder.

**Opening a group that's already open brings that tab forward** rather than
opening a second copy. Two tabs for one group is not just clutter: closing a
group tab writes its arrangement back, so duplicates compete and whichever you
close last silently overwrites the other.

**Groups always open disarmed.** Assembled and ready, with arming still a
deliberate act — see [MultiExec](multiexec.md).

### When a host is gone

A group whose hosts you've since deleted opens the ones that remain and tells
you which are missing, wherever you opened it from. Quietly giving you a
smaller grid than you asked for is how you run a command believing it reached
the whole platform.

## Keeping one up to date

A tab opened from a group stays linked to it. Rearranging that tab and closing
it — or quitting — **writes the new arrangement back silently**. There is no
"remember to save" step.

If you'd rather checkpoint without closing, the tab's context menu offers
**Update "name"**. You shouldn't have to close something to save it.

Saving a linked tab as a *new* group relinks the tab to the new one, so
subsequent edits follow where you'd expect.

Note that a tab merged into Grid View is deliberately **not** linked to any
group it came from. A grid of several tabs is not the group any one of them
was, and inheriting the link would have closing it overwrite that group with
the merged layout.

## Organising them

Groups live in the sidebar in their folder, above the hosts, with a pane count.
They behave like hosts: drag them between folders, select them, ⌘- or
shift-click several and drag them together, and rename or delete from the
context menu. A folder's badge counts groups as well as hosts.

**Star a group** — from its row or its context menu — and it appears in a
**Groups** section on the welcome screen, next to your favourite hosts. That's
the one-click-from-cold-start case.

Renaming or deleting a folder takes its groups with it, the same as its hosts.

## Deleting

Deleting a group discards the saved arrangement. It does **not** touch the
hosts in it.

It's undoable: **Edit ▸ Undo Delete** (⌥⌘Z), or **Recently Deleted** to reach a
specific one. Both name what would come back and when it went.

## What a group stores

The pane tree — which hosts, and how they were split — plus whether the tab was
in Grid View. Groups reference hosts by id, which is why deleting a host leaves
a gap rather than a broken entry, and why a group travels with an exported
library.

Splits open evenly. Portside does not store hand-dragged divider positions,
because nothing in the UI can currently report one; a group remembers *which
panes and what arrangement*, not exact proportions.
