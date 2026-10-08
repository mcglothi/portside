# Publishing a Shared Inventory — Plan

Phase 4 (`shared-inventory-plan.md`) built the *read* side: subscribe to a
team's manifest in git, read-only, beside your own hosts. This is the *write*
side, which covers creating a shared inventory and keeping it current, without
turning Portside into a git client and without weakening anything the read
side protects.

Written 2026-10-08. The maintainer's answers to the open questions are
recorded under **Decisions**.

## What others do

| Tool | Model | What it teaches us |
|---|---|---|
| **Termius** | Cloud *team vaults*. Hosts are moved into a shared vault, with per-vault *can edit / can view*. Credentials live in the personal vault unless explicitly shared. | Users understand "move these hosts into the team's space". Keeping personal credentials separate from shared hosts is the norm. |
| **Royal TS** | A shared *document* on a file share or cloud folder, merged on save. Conflicts mostly come from sync delay. Personal *overrides* customise a shared connection without changing it. | Overrides are the same idea as our `SharedOverlay`, which confirms the read side's design. File sync with merge-on-save is where conflicts come from, and Royal's answer for teams is a server. |
| **Remote Desktop Manager** | A database-backed data source, with *check-out / check-in* locking per entry. | Locking needs a server. With plain git it would be imitation locking. Branches and review do the same job. |
| **SecureCRT 9.6** | Export a session or folder, with an option to *exclude sensitive data* (usernames, passwords). | "Export this folder, minus the personal bits" is what an enterprise tool converged on. That's step 1 of our plan. |
| **Postman** | *Fork* a collection, edit, open a *pull request* inside Postman, review the diff, merge. If the parent moved, pull its changes first. Conflicts are resolved per item (keep source / keep destination). | This is our flow, without Postman's servers: a link (the fork), Publish Changes (the PR), a per-host diff, and "the parent moved, here are both versions". |
| **Insomnia Git Sync** | Commit, push and pull in the app, with a merge view only when both sides touched the same content. Protected branches are enforced, and the common pattern is to push a feature branch and merge on the forge. Secrets aren't screened. | Show a merge view only when there's a real conflict. Respect protected branches. **Screen secrets ourselves**, because Insomnia's not doing so is a known gap. |
| **Bruno** | Plain-text collections in the repo, one file per request, *to avoid merge conflicts* and keep diffs readable. | Diff noise and merge conflicts are what make git-backed tools miserable. We get the same benefit by owning the merge: Portside writes the file and merges by host id. |
| **Tailscale GitOps** | The policy file lives in a private repo. PRs are validated by CI (`action test`) and applied on merge. Branch protection requires review. | **Validate before merge.** Ship a validator (`portside inventory check`) that a team's CI can run, so a broken or unsafe manifest never reaches `main`. |
| **Ansible / GitOps practice** | Inventory as code: PR, review, lint in CI, protected `main`, pre-commit hooks that block secrets. | The same, which confirms branch + PR as the default and a secret check before commit. |

The pattern across all of them: **a team space with review, personal bits kept
out, conflicts resolved per item, and validation before merge.** The tools
that skip review (shared files with merge-on-save) are the ones whose docs are
full of conflict advice.

## Decisions (maintainer, 2026-10-08)

- **Unit: a linked folder.** One of your folders is linked to a source. You
  edit hosts there as usual, and **Publish Changes** shows the diff and sends
  it.
- **Default: branch + pull request.** A per-source opt-in allows a direct push
  to the source's branch, for solo or small trusted repos.
- **Auth: the user's own git**, the same `/usr/bin/git` path as subscribing.
  It never prompts.
- **The repo moved since the last publish:** your changes go on top of the
  latest version, host by host. If both sides changed the same host, show both
  and let the user choose.
- **No merge or release from this work.** It goes up as a PR.

## Design

### The link

```
PublishLink {
  sourceID      // the InventorySource this folder publishes to
  folder        // a local folder path; its subtree is what's published
  directPush    // opt-in; default false
  base          // the manifest as of the last publish or pull — the merge base
}
```

- **Where it lives:** in the library, next to `inventorySources`. The base
  manifest is stored beside the clone (`sources/<id>.base.json`), because it
  can be large and changes on every publish.
- **Creating a source:** "New Shared Inventory from Folder…" on a folder's
  menu. You give a name, a git URL (which may be an empty repo), a branch and
  a path. Portside subscribes, links, and publishes the first version.
- **Linking an existing source:** "Link Folder for Publishing…" on a source's
  menu. This is for when someone else created the source.

### Two trees, on purpose

The linked folder is **yours**: editable, as it is today. The subscribed
source root stays **the team's**: read-only, showing what's actually merged.
After you publish on a branch, the team tree still shows `main`, because your
change isn't merged yet, and that's honest. Once it's merged, the next pull
brings it in.

Editing shared hosts in place in the source tree was the third option, and it
was rejected. It blurs "mine vs. the team's", which the whole read side is
built on.

### Publish Changes

1. **Fetch the source.** The same safe fetch as subscribing: no prompts, a
   timeout, and fast-forward only for the clone.
2. **Build three sides**, all keyed by **manifest id**:
   - *base*: the last publish or pull
   - *mine*: the linked folder, run through the **same sanitizer subscribers
     use**
   - *theirs*: the current remote
3. **Merge per host.** Added on one side: keep it. Removed on one side and
   untouched on the other: remove it. Changed on one side: take that change.
   **Changed on both sides, differently: a conflict.** Folders merge the same
   way.
4. **Review sheet:**
   - Added, changed (field-level before/after) and removed hosts, with the
     sanitizer's drops listed ("run-on-connect removed from web-01").
   - Conflicts are shown side by side, with "Keep mine / Keep theirs" per
     host, as in Postman.
   - The commit message is prefilled, for example "Add 2 hosts, update
     web-01".
5. **Secret check.** The manifest can't hold passwords by construction, but
   free-text fields can, such as a host name of `admin:hunter2@db`. Refuse if
   any value looks like a credential.
6. **Write and commit** in a **separate worktree**, not the subscriber clone,
   so a failed or pending publish never disturbs what the sidebar shows. Use a
   branch `portside/<user>-<yyyymmdd-hhmm>` and the user's git identity.
7. **Push:**
   - **Branch mode:** push the branch. Capture the forge's "create a pull
     request" URL from the push output (GitHub and GitLab both print one), or
     build a GitHub `compare/…?quick_pull=1` URL as a fallback. Show **Open
     Pull Request**.
   - **Direct mode:** push to the source branch, fast-forward only. A rejected
     push (someone pushed meanwhile, or the branch is protected) is reported,
     never forced.
8. **Record the new base** once the push has succeeded.

### Identity is what makes the merge work

Hosts merge by **manifest id**, never by name, so renaming a host is a change
and not a delete plus an add. The linked folder's hosts need stable manifest
ids that don't depend on their local ids:

- A local host's manifest id **is** its local UUID, which is already stable.
- Hosts that came *from* the source (copied in, or the first link adopting
  the remote) keep the remote's manifest id. The link stores a map from local
  id to manifest id for them.

### Protecting the team repo

- **The sanitizer runs before publishing**, not only when reading, so the file
  in git is exactly what subscribers see. No personal fields reach the repo at
  all.
- **The secret check refuses to commit**: password-like `user:pass@`
  patterns, PEM headers, `ghp_` / `glpat-` / `xox` token shapes, and long
  high-entropy strings in free-text fields.
- **Never `--force`.** Protected branches are respected and their errors are
  reported in git's own words.
- **A validator for CI:** `portside inventory check <file>` exits non-zero on
  an unparsable manifest, unsafe values (anything the sanitizer would drop or
  refuse), duplicate ids, or secret-looking values. The docs include a
  GitHub Actions snippet, following Tailscale's model.

### What it does not do

- No forge API, OAuth or PR creation through an API. The forge's own push link
  is enough, and it keeps "plain git only" true.
- No editing of shared hosts in place in the source tree.
- No locking. Branches and review do that job.

## Phasing within this PR

1. Manifest writer (sanitized, sorted, stable) and the three-way merge by id.
   Pure code, heavily tested.
2. Publishing git operations: worktree, branch, commit, push, PR link,
   direct-push fast-forward. Tested against local bare repos, and live against
   a private GitHub test repo.
3. The link model, persistence, and "New Shared Inventory from Folder" /
   "Link Folder".
4. The Publish Changes review sheet with conflict resolution.
5. `portside inventory check` and the docs.
