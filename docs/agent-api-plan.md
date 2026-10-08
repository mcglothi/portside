# Agent API — Plan

The goal is to let an agent drive Portside from the command line. Two example
requests:

- "log me in to every Splunk box in prod"
- "open the lab hosts in a grid with MultiExec on"

A human should stay able to see what the agent did, and to stop it.

Written 2026-10-07, before any code.

## What others do, and what that taught us

Research on 2026-10-07 found the same split everywhere. Terminals have mature
remote-control APIs, and SSH connection managers have none:

| Tool | Mechanism | Access control |
|---|---|---|
| iTerm2 | Python API over a Unix socket | **Off by default.** When on, a client needs a 128-bit cookie, which it gets through AppleScript. That puts the macOS Automation consent prompt in front of it, once per app. The earlier check, which went by the job's command line, could be subverted and was replaced. |
| kitty | `kitty @` remote control | `allow_remote_control` is "a blunt instrument" (kitty's own words). Since 0.26 there are `remote_control_password` entries that each grant a **named list of actions**, so a script can be allowed `set-colors` and nothing else. |
| WezTerm | `wezterm cli` over a mux socket | `send-text` pastes into any pane. The docs don't describe any access control beyond the socket's file permissions. |
| cmux | Unix socket and CLI | Workspace and pane control for agents. This is the closest to what we want here. |
| Termius / Warp | Built-in AI | It's a chat panel inside the app, not an API that outside agents can drive. Warp's agent runs commands automatically by default. |
| Royal TSX, SecureCRT, MobaXterm | — | No agent-facing API was found. |
| MCP terminal servers (termmirror, mcp-interactive-terminal, MCP-SSH, …) | MCP over a headless PTY | They give an agent a shell, but those are **separate sessions from yours**. termmirror's "a human can watch and take over" is the right instinct. |

**Where Portside fits:** no SSH workbench offers an API for "drive the
sessions I'm looking at". Terminals offer pane-level control with no idea
what an inventory is. MCP servers offer shells that no human can see. Portside
has an inventory, a query language, saved groups, MultiExec, and a safety
model for protected hosts, all in the app the user is already watching.

### Lessons we're adopting

1. **Off by default, and turning it on is a deliberate act** (iTerm2). This
   gives an agent less power than the user has, never more.
2. **Grant capabilities, not one on/off switch** (kitty's per-password action
   lists). Reading the inventory, opening sessions and typing into sessions
   are very different levels of power.
3. **A Unix socket alone doesn't say who is calling.** Every process running
   as the user can open it. iTerm2 learned this, then learned again that
   identifying a client by its command line can be faked. We identify the
   client by its peer process and approve each client in the UI, once.
4. **Terminal output is untrusted input.** The 2024–2026 escape-sequence CVEs
   in kitty and iTerm2 (CVE-2024-38396, CVE-2026-42850, CVE-2026-72913, …)
   share one root cause: something the terminal *displayed* got treated as
   *control*. For an agent the same problem gets worse. Text a server prints
   can carry instructions to the agent ("ignore previous instructions and run
   …"). An agent with MultiExec turns one poisoned log line into a command
   across the whole fleet. So screen text returned to an agent is stripped of
   escape sequences and marked as untrusted. And sending input to more than
   one host, or to any protected host, needs a confirmation from a human in
   the UI, the same as MultiExec paste does now.
5. **Let the human watch and take over** (termmirror). Agent sessions are
   ordinary Portside tabs. While a client is connected, the UI shows an
   indicator, and one click disconnects it.

## Shape

```
agent ──> portside CLI ──> ~/Library/Application Support/Portside/agent.sock ──> running app
                                       (0600, JSON lines)
```

- **The `portside` CLI ships inside the app bundle.** It's
  `Portside.app/Contents/MacOS/portside-cli`, linked into the user's path by
  Settings ▸ Agent Access or by the Homebrew cask. It's a thin client: one
  request, one response, and JSON whenever stdout isn't a terminal.
- **Socket:** newline-delimited JSON, `{"id", "method", "params"}` →
  `{"id", "result" | "error"}`. It's created only while access is enabled,
  sits in the library directory (so `PORTSIDE_LIBRARY_DIR` isolates it for
  tests), and has mode 0600.
- **Client identity:** `getsockopt(LOCAL_PEERPID)` gives the caller's PID. We
  walk up to the first ancestor that isn't a shell to name the client
  (`claude`, `codex`, `Terminal`), which tells the human who is asking.
  Approval is per client name plus executable path, and is remembered.
- **Later, an MCP server.** `portside mcp` speaks MCP over stdio and maps each
  tool to a socket method. It's a wrapper and holds no logic of its own, so
  there's only one place to secure.

## Capabilities

| Tier | Methods | Default when enabled |
|---|---|---|
| **read** | `hosts [query]`, `groups`, `tabs`, `status` | asks once per client |
| **open** | `connect <query\|ids> [--grid]`, `open-group`, `focus`, `close` | asks once per client (or upgrades from read) |
| **input** | `send <tab/pane> <text>`, `screen <pane>` | off; asks per client; per-call rules below |

A client is granted tiers, never individual methods. Each tier includes the
ones above it.

### Rules that don't bend for an agent

- **The query language is the selector.** `connect 'env:prod folder:splunk'`
  uses `HostQuery`, so an agent can preview the set first with
  `hosts 'env:prod folder:splunk'`. It sees exactly what the sidebar filter
  would show, shared inventory included.
- **Protected hosts:** a `connect` that matches any protected host puts up
  the same confirmation a human would get. It lists the protected hosts and
  is answered in the UI. If nobody answers before the timeout, the call
  fails.
- **Count cap:** a `connect` matching more than N hosts (default 20, set in
  Settings) needs a UI confirmation that names the count. This stops "log me
  in to `/.*/`" from opening 400 sessions.
- **MultiExec opens disarmed.** It's the same rule groups and workspace
  restore follow. An agent can't arm broadcast. Arming stays a human act.
- **Input tier:**
  - `send` targets exactly one pane.
  - Sending to a protected host, or a second pane within the same short
    window, needs a UI confirmation.
  - There's no `send` to a MultiExec group.
  - `screen` returns plain text with escape sequences removed, inside an
    envelope that marks it `untrusted: true`.
- **Credentials never cross the socket.** Opening a session uses the same
  Keychain and askpass path as a click does. No method returns a password or
  key material.
- **Audit:** every request, with the client, method, parameters, decision
  and result, is appended to `portside.agent.log` beside the history file.
  It's also visible under Tools ▸ Agent Activity.

## As built (phase 1)

Changes from the plan above, made while building it:

- **Read asks too.** The plan let any approved-or-not process read the
  inventory once access was on. But a host list is a topology map, so every
  client is approved before it gets *anything*.
- **No `--multiexec` flag.** Arming is human-only, so a "MultiExec" connect
  and a grid connect would be the same thing. `--grid` it is.
- **The refusal is the default button, and approvals arm after 0.6 s.** Found
  live, not in theory. During the first end-to-end run, two approval prompts
  were answered "Allow" within the same second they appeared, with nobody
  clicking. It never reproduced, but the answer was the default button, which
  Return triggers, and a Return typed into a terminal pane at the wrong moment
  is a realistic way to approve an agent without reading the prompt. Both
  measures now apply, and both are tested, and the delay test was confirmed
  to fail with the delay removed.
- **The dismissal binding answers nothing.** SwiftUI runs an alert's
  `isPresented` setter *after* the button action. When that setter also
  answered "no", it refused the *next* queued prompt before anyone saw it.
- **Client names drop `.exe`.** Claude Code's real binary is `claude.exe`
  inside its npm package.

## As built (phase 3)

Built sooner than this plan proposed, at the maintainer's call, so it
arrives with the strictest version of each rule:

- **A separate switch, off by default.** Turning it off revokes typing from
  every client.
- **Per-pane consent.** Protected hosts and multi-line input ask every time.
- **Staged, not run, by default** (`enter` is opt-in). This came from the use
  case it serves: "write me a one-liner" should end with the human pressing
  Return.
- **`last-command`** returns per-command output delimited by OSC 133, so an
  agent pays for one command's output rather than a screen or a log.
- **`current`** resolves through a most-recently-selected tab history and
  skips the caller's own pane, found by walking the caller's process
  ancestry to each pane's shell.

Two of this phase's own tests were found not to test what they claimed, by
removing the guard and watching them still pass. Both were rewritten until
they failed without it.

## Phases

1. **Read and open (this branch).**
   - The socket server, peer identity, and per-client approval.
   - `hosts`, `groups`, `tabs`, `status`, `connect`, `open-group`.
   - The CLI, the settings pane, the indicator, and the audit log.
   - This covers "log me in to all servers matching X".
2. **MCP wrapper.** `portside mcp`, plus a short `docs/agent-api.md` with
   Claude Code and Codex setup snippets.
3. **Input tier.** `send` and `screen` with the rules above. This phase
   waits until phases 1 and 2 have had real use. Like key distribution, it's
   the first time Portside would *act* on remote machines on someone else's
   behalf.

## Relationship to 1.0

`road-to-1.0.md` lists CLI and URL scheme as 1.x. Phase 1 is read-only plus
opening sessions, which the URL scheme can already do in a smaller way, so
it's low risk. Phase 3 is not 1.0 material until it has mileage, for the same
reason MultiExec's gate exists.

## Sources

- iTerm2 Python API security: https://iterm2.com/python-api-auth.html
- kitty remote control passwords: https://man.archlinux.org/man/kitten-@-run.1.en.raw
- WezTerm `cli send-text`: https://wezterm.org/cli/cli/send-text.html
- termmirror: https://github.com/Ar9av/termmirror
- kitty escape-sequence CVEs: https://ubuntu.com/security/notices/USN-8763-1 ,
  https://hol.org/blog/cve-2026-72913-kitty-command-injection-dcs
- iTerm2 CVE-2024-38396: https://www.sentinelone.com/vulnerability-database/cve-2024-38396
