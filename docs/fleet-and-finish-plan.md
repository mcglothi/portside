# 0.16 — Fleet & Finish

Three related pushes in one release: make a large host inventory
*surveyable*, make connection history real, and give the app a visual identity
of its own. Sequenced deliberately — see "Why this order" at the end.

The driving case throughout is a **900+ host imported inventory**, where the
library is currently navigable but not surveyable: you can find a host, but you
cannot see what's tagged, what has credentials, or what you haven't touched in
six months.

---

## Phase 1 — Inventory tooling

### 1a. Sidebar Expand All / Collapse All

Smallest item, immediate value on a deep folder tree.

`HostOutlineView` already calls `outline.expandItem(nil, expandChildren: true)`,
so the mechanism exists; this exposes it. Add to the sidebar's toolbar menu and
the folder context menu. Expansion state already persists within a session and
is reconciled by folder path, so no model change.

### 1b. Bulk-tag environment

Set `HostEnvironment` (prod/staging/dev/personal/none) across a multi-selection
or a whole folder.

This is deliberately a near-copy of work already in the tree:

- `SessionStore.setSavePassword(_:ids:)` and `setFavorite(_:ids:)` are the exact
  shape needed — add `setEnvironment(_:ids:)` beside them (guard on "did
  anything actually change" before `save()`, as they do).
- `addCredentialProfileMenu(menu, forSelection:)` in `HostOutlineView` is the
  submenu pattern; add an `addEnvironmentMenu` alongside it.
- Wire into **both** `buildEntryMenu` (multi-selection branch) and
  `buildFolderMenu`, which is where the credential-profile bulk action already
  appears.

No new model, no migration.

### 1c. Inventory coverage view

The headline of the phase, and the thing no other terminal does.

Answers "what in my fleet is neglected?" across four axes:

- no environment tag
- no credential profile (and no credentials of its own)
- no saved password where one is expected
- not connected to in 90+ days (**depends on Phase 2's history** — see note)

**Decision: a sidebar destination, not a sheet.** The existing sidebar is
already a `Hosts / Macros / Tools` segmented switcher (`SidebarSection`), so
coverage belongs as a peer destination rather than a modal over the host list —
it's a place you go to work for a while, not a dialog you dismiss. A sheet would
also make the natural "fix it from here" flow (select offenders → bulk-apply)
awkward.

Each row is a *gap*, not a host: "42 hosts have no environment tag", expanding
to the list, with the Phase 1b bulk actions available inline. The point is to
make a big bulk pass **verifiable** rather than guessed at.

> **Ordering note:** stale-host detection needs per-host last-connected data,
> which Phase 2 introduces. Build coverage with the first three axes, and add
> the staleness axis when Phase 2 lands rather than blocking on it.

---

## Phase 2 — Connection history

Grow today's capped 20-entry recents list into a real, searchable, browsable
history with its own view.

- **Model**: a persisted history of connections (host id, timestamp, outcome),
  stored tolerantly in `SessionStore.Document` like every other addition.
  Existing `recents` must keep decoding — see the tolerant-Codable precedent in
  `TerminalAppearance` and `WorkspaceSnapshot`.
- **Privacy**: a "clear history" action, and a way to exclude protected hosts
  from being logged at all. Worth treating as a real requirement, not a
  checkbox — this is a record of what infrastructure someone touched and when.
- **Frecency-ranked Quick Connect**: blend frequency and recency so a host hit
  constantly outranks one touched once yesterday. Pure ranking logic → keep it
  a free function so it unit-tests without the store.
- **Browsable recently-closed tabs**: reopen any of the last N closed
  tabs/layouts, not just the single most recent (⇧⌘T today). The restore
  planner already rebuilds a `PaneNode` tree from a snapshot, so a closed tab is
  a snapshot to keep rather than something new to model.
- **Stale-host detection**: surface hosts untouched in 90+ days; feeds the
  Phase 1c coverage view.

---

## Phase 3 — Visual pass

**App-level appearance (light / dark / follow system)**, distinct from the
terminal color theme.

Locked with Tim: the setting lives **next to the terminal theme in Settings ▸
Appearance, clearly separated** — adjacent so the relationship is obvious, but
explicitly independent. A dark terminal inside a light app (or the reverse) is a
normal preference and must stay possible; the two must never be coupled.

Implementation is `NSApp.appearance` driven from a persisted enum on
`TerminalAppearance` (tolerant Codable, default = follow system).

Then the broader pass:

- density and spacing consistency
- empty states (the file browser, coverage view, history all need real ones)
- sidebar and tab-strip chrome
- iconography consistency

### Why this order

The visual pass goes **last on purpose**. Phases 1 and 2 add several new views;
styling first means restyling them afterwards. Phase 2 precedes the visual work
for the same reason but must follow Phase 1 only loosely — its one hard
dependency is the other direction (1c's staleness axis wants 2's data).

---

## Testing notes

- `CredentialStore` is **not** test-isolated — it wraps the real Keychain with
  no seam. Any new `SessionStore` path must not reach it from the test-seam
  init (`fileURL:seedsFromSSHConfig:`). This has bitten the project once
  already, destroying a real Keychain entry.
- Prefer pure functions for ranking/coverage computation so they test without
  a store or a GUI, as `WorkspaceSnapshot`'s planner does.
- Back up `~/Library/Application Support/Portside/portside.json` before any
  GUI testing pass; opening sessions persists a workspace into the real library.
