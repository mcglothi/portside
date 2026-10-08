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

1. In Portside, select the hosts to share. Then choose **File ▸ Export
   Sessions…**.
2. Commit the exported file to a **private** repository. The default name is
   `portside.json` at the root of the repo.
3. To publish a change, export again and commit. The export is sorted and
   pretty-printed, so diffs stay small and show only what changed.

No secrets go into the file. Passwords stay in each person's Keychain, and
credential profile assignments are dropped on the way in.

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
- **Dropped:** anything that isn't a plain SSH host. That covers containers
  and Kubernetes pods (their commands run on your Mac), serial ports, and
  telnet.
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
The source keeps its previous contents and reports the problem. To accept the
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
- Publishing from inside Portside. Contributions go through the team's
  normal review, as a branch and a merge request.
