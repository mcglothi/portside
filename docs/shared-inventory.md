# Shared inventory

A team publishes its hosts to a git repository. Everyone else subscribes to
that repository, read-only. The shared hosts appear in the sidebar **beside**
your own hosts, never mixed in with them. Each source is a root of its own,
below your library.

There's no Portside account, service or forge integration. Portside runs your
own `git`: it clones the repository, fast-forwards it, and reads one file. Any
remote your git can reach will work: GitHub, GitLab, Gitea, Forgejo, a bare
repo over SSH, or a path on a NAS. Authentication is whatever your git already
uses, such as the SSH agent or a credential helper.

## Publishing

You publish from **one of your own folders**. You edit hosts there as usual,
and Portside sends your changes to the team's repository for review.

### Starting a shared inventory

Right-click a folder and choose **New Shared Inventory from Folder…**. Give
it a name, the git URL of an **empty** repository, a branch and a manifest
path. Portside publishes the folder's hosts as the first version, and
subscribes you to it, so the team's view appears as its own root. The folder
gets an ↑ badge: it now publishes to that inventory.

Portside refuses a repository that already holds an inventory, so nothing of
the team's is ever overwritten. To contribute to one, link a folder instead.

### Contributing to one that exists

Subscribe to it (File ▸ Shared Inventory…), then right-click its root and
choose **Link Folder for Publishing…**. Portside copies the team's hosts into a
folder of your own. That copy is what you edit, and it remembers which team
host each one is, so an edit publishes as a change rather than a new host.

### Publish Changes

Right-click the linked folder and choose **Publish Changes…**. Portside
fetches the team's latest version and shows the review before anything is
sent:

- **From the team since your last publish:** what teammates changed. It comes
  into your folder when you publish, while your personal settings on those
  hosts stay as they are.
- **Changed on both sides:** a host you and a teammate both changed, shown
  side by side. Choose **Mine** or **Theirs** for each one. Hosts are matched
  by identity, not by name, so a rename is one change, and two people adding
  hosts never conflict.
- **Your changes:** added, removed, and changed hosts, field by field
  (`environment: prod → staging`).
- **Left out:** personal settings that never leave your Mac: run-on-connect,
  agent and X11 forwarding, credential profiles, saved passwords and
  favourites. What's published is exactly what subscribers would keep.
- **Looks like a secret:** a token, key, or `user:password@` URL anywhere in a
  name, folder or key path blocks the publish until you remove it.

By default Portside **pushes a review branch** (`portside/<you>-<date>`) and
offers **Open Pull Request**, using the link your forge prints on push
(GitHub, GitLab, Gitea and Bitbucket all print one). Nothing reaches
subscribers until the PR is merged. For a solo or small trusted repository,
**Push Directly to main** on the folder's menu fast-forwards the branch
instead.

If a teammate pushes while your review is open, **Publish** refuses and asks
you to open Publish Changes again. The review you saw was merged against their
earlier version, and publishing it would quietly undo what they just changed.
A team manifest that exists but can't be read stops the review too. It isn't
treated as an empty inventory, which would publish every host as removed.

Renaming the linked folder, or a folder above it, keeps the link. Deleting
the linked folder removes the link: its hosts move up a level, and
publishing the folder afterwards would send each one as removed. The
subscription and the team's copy stay, and you can link a folder again.

Portside **never force-pushes**. A protected branch, or a push someone else
made first, is reported in git's own words. It uses your git setup (SSH agent
or credential helper) and never prompts. Commits carry your
`user.name`/`user.email`; if git doesn't know who you are, nothing is
committed and Portside tells you how to set it.

### Checking pull requests in CI

`Scripts/portside-inventory-check.py` is a single file with no dependencies.
Copy it into your inventory repository and it applies the same rules Portside
does: unreadable manifests, duplicate ids, values ssh would read as options,
and anything that looks like a secret fail the check. Records subscribers
would skip produce warnings. For GitHub Actions:

```yaml
name: inventory
on: pull_request
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: python3 portside-inventory-check.py portside.json
```

With branch protection requiring that check and a review, a bad or unsafe
change can't reach the branch everyone subscribes to.

## Subscribing

Choose **File ▸ Shared Inventory…**. Enter a name, the git URL, the branch,
and the manifest path, then click **Add and Pull**.

Portside pulls every source at launch, and you can pull one at any time with
**Pull Latest** on its root in the sidebar. Between pulls, Portside reads each
source from its local clone, so shared hosts still work offline. If a pull
fails, the hosts from the last good pull stay, and the source's root shows a
warning that gives the reason.

## What a source can and can't do

A manifest is someone else's file, and it arrives by `git pull`. Portside
reads it strictly and keeps only **where the hosts are**:

- **Kept:** name, folder, host, user, port, `~/.ssh/config` alias, identity
  file path, mosh preference, keepalive, environment, and the protected flag.
- **Kept: containers on an SSH host.** For these the source also sets the
  engine (docker, podman or nerdctl), the container, the shell and the
  container user. Portside connects to the host and types
  `<engine> exec -it [-u user] <container> <shell>` there. That command is
  rebuilt from those fields, never read as text. Each field must be a plain
  name:
  - **container:** what docker allows
  - **user:** a user or `uid:gid`
  - **shell:** one of `sh`, `bash`, `ash`, `dash`, `zsh`, `ksh`, `mksh` or
    `fish`, optionally in `/bin`, `/usr/bin` or `/usr/local/bin`

  Anything else skips the record.
- **Dropped:** containers with no host, Kubernetes pods, serial ports and
  telnet. A container with no host and a Kubernetes pod both run their
  commands on your Mac (Kubernetes with your kubeconfig and credential
  plugins). A serial port is a device on your Mac.
- **Dropped:** run-on-connect commands, agent forwarding and X11 forwarding.
  Each of those either acts as you, or gives the remote host a way back into
  your Mac. You can turn them on for yourself, per host.
- **Refused:** a host, alias or user that starts with `-`, or that contains
  characters a hostname or username can't contain. ssh would read such a
  value as an option.

The source's dialog shows how many records were skipped.

**History rewrites are refused.** Updates are fast-forward only. If someone
force-pushes the branch, Portside won't follow it. A force-push is exactly how
a host could be slipped into everyone's sidebar without anyone reviewing it.
The source keeps its previous contents and reports the problem. The same
goes for a pull that brings a manifest Portside can't read: the local clone is
put back to the last good commit, so the hosts are still there after a
relaunch. To accept the
new history, remove the source and add it again.

**The manifest must live inside the repository.** If the manifest path
leaves the clone, Portside refuses it, and that includes a symlink committed
to the repo.

## Your own settings on shared hosts

Right-click a shared host and choose **Your Settings for This Host…**, or use
the bulk menus. The address, user and key belong to the source and are locked.
These settings are yours, stay on this Mac, and survive pulls:

- credential profile and saved password
- environment (this replaces the source's tag)
- favourite
- protected (you can **add** protection, but you can't remove protection the
  source set)
- run-on-connect, agent forwarding, X11 forwarding

**Copy to My Hosts** turns a shared host into an ordinary editable host in
your own library.

You can't delete, move or rename a shared host. Change the repository
instead.

## Turning a source off

Each source in **File ▸ Shared Inventory…** has an on/off switch. Turning a
source off hides its hosts from the sidebar, search and agents, and Portside
stops pulling it. The local clone stays, and so do your own settings on its
hosts: favourites, credential profiles, saved passwords and environment.
Turning it back on brings its hosts back at once from the clone, then pulls.

This suits an inventory you only need some of the time, such as a customer
between engagements. Removing a source throws away your settings on its
hosts; turning it off keeps them. You can't publish to an inventory while
it's off.

## Removing a source

**File ▸ Shared Inventory…**, then the trash button. This removes the source,
its local clone, and your settings on its hosts, including any saved
passwords. The repository itself isn't touched.

## Security

A manifest holds no secrets, but it is a map of your infrastructure:
hostnames, jump hosts, which machines are production, and which are
protected. Keep the repository private. Subscribe only to sources you trust,
because anyone who can push to one decides which hosts appear in your
sidebar.

## Not yet

- Verifying signed commits or tags on a source.
- Merging shared folders and your own into one tree.
- Signed commits on publish (your git's own `commit.gpgsign` applies if set).
