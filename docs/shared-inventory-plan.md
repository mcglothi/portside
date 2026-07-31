# Groups, Backup, and Shared Inventory — Plan

Four related features that share one prerequisite. Written after the July 2026
external reviews (ChatGPT + Grok both independently reached "sync story") and a
scoping conversation.

The through-line: **Portside stays local-first and account-free.** Nothing here
introduces a Portside service, a Portside login, or a forge API. Backup and
sharing ride on infrastructure the user already has and already trusts.

## The four features

1. **Host groups** — save a selection of hosts as one named item in the
   sidebar; one click relaunches all of them in the layout you left.
2. **Portable manifest** — split what's shareable from what's machine-local.
   Prerequisite for 3 and 4; also fixes export today.
3. **Backup / multi-Mac** — put the library anywhere: iCloud Drive, Dropbox,
   a NAS mount, a git working copy.
4. **Shared inventory** — subscribe to read-only inventory published by a team
   over plain git, shown *alongside* your own sessions, never instead of them.

Ordering below is by dependency, not by value. **Groups ships first** — it
needs nothing from the others.

---

## Non-goals

- No Portside cloud, account, or vault.
- **No forge APIs.** Plain `git` only, so GitHub/GitLab/Gitea/Forgejo/bare SSH
  remotes are all equally supported by construction. No OAuth, no PATs, no
  per-forge integration to maintain. Auth is the user's existing SSH agent or
  git credential helper — the same "lean on the stack that already works"
  argument that made `/usr/bin/ssh` the right call.
- No merge engine. Shared sources are read-only and fast-forward only;
  conflicts in your *own* repo surface for you to resolve in your own git
  tools, which are better than anything shipped here.
- No secrets leave the Keychain, ever. Not in a manifest, not in a repo, not
  in a backup.

---

## Phase 1 — Host groups

The feature request: eight Splunk boxes, saved in the sidebar as "Splunk
Servers", one click to open them all back into the grid they were in.

### Why this is cheap

`WorkspaceSnapshot` already models exactly this. `TabSnapshot` is a pane tree
with orientations, split fractions, per-leaf `host(UUID)` / `localShell`, and
per-leaf MultiExec membership; `wasGridView` sits alongside. A saved group is a
**named, persisted `TabSnapshot`** plus a folder path. The restore machinery
that replays it already exists and is already tested.

### Model

```
struct SessionGroup: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String                    // "Splunk Servers"
    var folder: String                  // same path convention as SessionEntry
    var isFavorite = false
    /// The layout to reopen: pane tree, split fractions, membership.
    var layout: WorkspaceSnapshot.TabSnapshot
    var wasGridView = false
    /// Refreshed when the group's tab closes, so the group remembers the
    /// arrangement you actually left rather than the one you first saved.
    var updatedAt: Date
}
```

Lives in `SessionStore.Document` as `groups: [SessionGroup]?` — tolerant
Codable, same as every other field (see the `Macro` decoder note: a
non-optional array plus a synthesized decoder is how you fail a whole library
load).

### Launch is disarmed. Always.

`WorkspaceSnapshot` deliberately does not persist `broadcastArmed`, so restore
never auto-broadcasts into freshly reconnected hosts. **A group carries the
same rule** — it restores the split layout and per-pane membership, but always
opens disarmed. Membership without arming is exactly right: the group is
reassembled and ready, and arming stays a deliberate act.

This is the same conclusion ChatGPT reached independently for layout presets.

### Behaviour

- Create from the current tab ("Save Tab as Group…"), or from a multi-select
  in the sidebar ("Save 8 Sessions as Group…").
- Appears in the sidebar in its folder with a distinct icon; ⌘K-searchable;
  favouritable onto the welcome screen.
- Launch opens **one tab** containing the whole layout.
- **Missing members don't fail the launch.** A host that was deleted, or that
  came from a shared source no longer subscribed, is skipped and reported
  once: "Opened 6 of 8 — web-07 and web-08 are no longer in your library."
- Member refs are `EntryRef` (below), not bare `UUID`, from day one — cheap
  forward-compatibility so Phase 4 doesn't force a migration.

### Decided: silent update, with undo

Closing a group's tab silently saves the arrangement you left, matching
workspace restore rather than adding an "Update Group" step. Undo covers the
"I dragged a pane once and lost my layout" case.

Chosen to be lived with for a few days rather than argued about — if silent
turns out to be annoying rather than seamless, an explicit-update setting is
a small change from here.

---

## Phase 2 — Portable manifest

The library currently mixes three lifetimes in one file. Splitting them is a
prerequisite for everything below, and independently fixes export.

| Portable (shareable, backed up) | Machine-local (never travels) |
|---|---|
| entries, explicitFolders | workspace snapshot |
| macros | recents, connectionStats |
| groups | appearance, custom themes, font |
| **credential profile definitions** (no secrets) | terminal settings |
| forwards | window/layout state |
| key bindings? (arguable — see below) | defaultProfileID? (arguable) |

Precedent: history was pulled into `portside.history.json` because it was
churn-heavy with a different lifetime. Same argument, different axis.

### The bug this fixes today

`LibraryTransfer.Document` carries `entries`, `folders`, `macros` — **and no
credential profiles.** So an export restored on a second Mac produces sessions
referencing profiles that don't exist there. After the 0.19 import fix those
references correctly clear themselves and switch saved-password use off, which
means **every host in a restored library is unable to authenticate.**

Including profile *definitions* (name, user, identity file — never the secret)
under stable UUIDs makes the keep-if-resolves logic work across machines
instead of only same-machine restore. Passwords are re-entered once per Mac,
which is correct and shouldn't change.

This is the single highest-value item in the document and it's small.

### Git-friendliness

If the manifest is going into a repo it has to diff well:
- Stable key order (`.sortedKeys`, already used).
- **Entries sorted by a durable key** (folder, then name) rather than array
  insertion order — otherwise reordering produces noise and defeats 3-way
  merge.
- Pretty-printed, one field per line, so conflicts are line-scoped.

---

## Phase 3 — Library location + backup

**A setting, not a sync engine.** Point the library at any directory: iCloud
Drive, Dropbox, a NAS mount, a git working copy. That is most of the value of
"sync" for a fraction of the work, and it ships nothing new to trust.

### The one thing it genuinely needs: a stale-read guard

`save()` writes the whole library on every mutation. Two Macs on one synced
file means last-writer-wins: Mac A adds a host, Mac B renames a folder,
whoever saves second wins and the other change is gone silently.

Record the file's modification date at load. On save, if the on-disk date
doesn't match what was loaded, **refuse and surface it** rather than
overwrite — offer Reload, Save a Copy, or Overwrite with an explicit warning.

This is the store's existing principle extended by one case:

> a bad read can never become a bad write → *a stale read can never become a
> clobbering write*

Also worth noting in the UI: iCloud Drive plus a file an app holds open is a
known-bad combination. A short warning when the chosen directory looks like
iCloud Drive is cheap and honest.

### Git as a backup target

Once the library is a git working copy, backup is: commit, push. A thin UI
over `git status` / `add` / `commit` / `push`, shelling out to the `git` CLI —
the same pattern as `/usr/bin/ssh` and `/usr/bin/sftp`. Conflicts are surfaced,
not solved; the user's own tools are better.

---

## Phase 4 — Shared inventory, alongside your own

A team publishes a secret-free manifest to a git repo. Users **subscribe** to
it read-only. Shared hosts appear next to personal ones — never instead of.

### Sources

```
struct InventorySource: Identifiable, Codable {
    var id = UUID()
    var name: String              // "Platform Team"
    var remote: String            // any git URL — ssh://, https://, git@…
    var ref: String               // branch/tag, default "main"
    var path: String              // manifest path within the repo
    var lastPulled: Date?
    var isReadOnly = true         // v1: always
}
```

Clone into Application Support, `git pull --ff-only` on demand and on launch.
Never push. Any forge works because nothing forge-specific is used.

### Composition in the sidebar

Sources are **top-level roots**: "My Sessions", "Platform Team", "SRE Shared" —
collapsible, each with its own folder tree beneath. Deliberately not merged
into one tree in v1: merging creates real ambiguity about where a newly created
session lands and how a name collision resolves. Separate roots are
unambiguous, and merging can be added later once the model is proven.

Quick Connect and search span **all** sources, with the source shown on each
result — because that's where "alongside" actually matters day to day.

### Local overlays

A shared entry is read-only from the source, but users need their own
environment tag, credential profile, favourite flag, and run-on-connect. So:

```
resolved entry = shared entry (from source)
               + LocalOverlay keyed by (sourceID, entryID)
```

Overlay carries only: environment, credentialProfileID, isFavorite,
isProtected, runOnConnect, folder-pin. Everything else comes from the source
and updates on pull.

`SessionStore.resolved(_:)` already exists as the place where an entry gets
finished before use — overlays apply there.

`isProtected` in the overlay is worth calling out: **a user must be able to
mark a shared host protected locally even if the source didn't.** Protection is
a local safety judgement and can't require a PR to the team repo.

### Identity

`EntryRef { sourceID: UUID?, entryID: UUID }` — `nil` source means local. Used
by groups, overlays, favourites, and history. Same repo subscribed twice stays
distinct because the source id differs.

### Contributing back

Out of scope for v1. A user who wants to add a host to the team inventory does
it the way the team already reviews changes — a branch and a merge request on
their own forge. Portside can offer "Reveal manifest in Finder" and stay out of
the way.

---

## Security note — a manifest is a topology map

No secrets, but hostnames, jump chains, folder names like `prod`, and which
boxes are protected together make a very good target-selection document.

- Warn plainly when a remote is added, and say this in the docs.
- Never default to a public repo or suggest one.
- Consider verifying signed commits/tags on shared sources later — a source
  that can silently add a host to everyone's sidebar is a supply-chain
  position.

---

## Sequencing

| Phase | Depends on | Size | Ships alone? | State |
|---|---|---|---|---|
| 1. Host groups | — | S–M | Yes | **done** (model, persistence, launch, UI) |
| 2. Portable manifest | — | S | Yes (fixes export) | **done** (profiles in exports, library split) |
| 3. Library location + guard | 2 | M | Yes | **done** (override, guard, split) |
| 4. Shared sources | 2, 3 | L | No | not started |

Recommended order: **2 → 1 → 3 → 4.** The manifest fix is small, ships
immediately, and repairs a real defect in export today. Groups follow because
they're self-contained and wanted. Location and sharing build on the manifest.

### What's left in 1 and 2

**Groups — done.** Model, persistence, launch, write-back on close, and the
UI: groups sit in their folder above the hosts with a grid glyph and pane
count, double-click opens, the context menu offers open/rename/delete, and
File ▸ Save Tab as Group… captures the selected tab. A partial launch says so
rather than opening quietly smaller.

One thing surfaced and *not* fixed: split proportions are never applied when
a layout is rendered. `PaneNodeView` discards the fractions, and HSplitView
sizes by its own rules — so a restored group (or a restored workspace) reopens
with the splitter's proportions, not the ones you left. The model records and
round-trips them faithfully; nothing consumes them. Fixing it means driving
widths explicitly or replacing the split containers, which is a real change to
the pane tree and wants doing on its own.

**Manifest — done.** Exports carry credential profile definitions, and the
split has landed: `workspace`, `recents`, appearance, custom themes, terminal
and logging settings now live in `portside.local.json`, migrated out of the
library on first load. The library is what you'd back up, share or sync; the
sidecar is this Mac's window and font size, and is disposable.

Left in the library on purpose: `defaults`, `keyBindings` and the history
*settings*. Those are preferences rather than machine state — a second Mac
wanting your default SSH user and your key bindings is the likely case, not
the surprising one. Easy to move later if that turns out backwards.

Two pieces of phase 3 arrived early. `PORTSIDE_LIBRARY_DIR` already redirects
the whole library, and the **stale-read guard is now in**: a save is refused
when the file changed on disk since it was read, with reload and overwrite
both offered. So pointing the library at a synced folder is already safe from
silent clobbering.

What's left for phase 3 is the split itself — until `workspace`, `recents`,
`connectionStats`, appearance and terminal settings stop travelling with the
portable data, "put the library in Dropbox" also syncs your open tabs.

## Explicitly deferred

- Merging shared and personal trees into one namespace.
- Writing back to shared sources from inside Portside.
- Dynamic inventory providers (Ansible, EC2, k8s) — a different feature that
  reuses the `InventorySource` shape once it exists.
- Real-time sync, conflict merging, per-field three-way resolution.
