# Agent Access

Agent Access lets a program on your Mac (Claude Code, Codex, or your own
scripts) list your hosts and open sessions in the Portside window you're
already looking at. It goes through the `portside` command.

```
portside hosts 'env:prod folder:splunk'            # what would match?
portside connect 'env:prod folder:splunk' --grid   # open them, one grid
```

So you can tell an agent *"log me in to every Splunk box in prod"* and watch
it happen in Portside. The agent never types into those sessions, and it
can't arm MultiExec.

## Setting it up

1. **Settings ▸ Agents ▸ Allow agents to use Portside.** Until you turn this
   on, the socket doesn't exist.
2. **Install in ~/.local/bin** puts `portside` on your PATH. The command lives
   inside the app, so it updates along with Portside.
3. Tell your agent about it. For Claude Code, add a line to `CLAUDE.md`:

   ```
   Portside (my SSH workbench) is driven with the `portside` CLI — run
   `portside --help`. Preview with `portside hosts '<query>'` before
   `portside connect '<query>'`.
   ```

## As MCP tools

`portside mcp` runs an MCP server on stdio, which gives an agent Portside's
tools directly instead of shelling out. For Claude Code:

```
claude mcp add portside -- /Applications/Portside.app/Contents/MacOS/portside-cli mcp
```

Settings ▸ Agents shows this command with the right path, ready to copy.

| Tool | Does |
|---|---|
| `portside_status` | Version, access level, counts |
| `portside_list_hosts` | Hosts matching an optional query |
| `portside_list_groups` | Saved groups |
| `portside_list_tabs` | Open tabs and their panes |
| `portside_connect` | Opens hosts by query or ids, optionally as a grid |
| `portside_open_group` | Opens a saved group |
| `portside_focus_tab` | Brings a tab forward |
| `portside_close_tab` | Closes a tab (marked destructive) |

Each tool is one request to the same socket, so everything below applies to
the tools exactly as it applies to the command. The tools are annotated, with
read-only tools as `readOnlyHint` and closing as `destructiveHint`, so clients
that auto-approve read-only tools can do so safely. The tool descriptions tell
the agent to preview with `portside_list_hosts` first. They also say that the
user may be asked, and that a declined call is final and shouldn't be retried.

## Commands

| Command | What it does |
|---|---|
| `portside status` | Shows the app version, your access level, and counts |
| `portside hosts [QUERY]` | Lists hosts, both your own and shared ones, with their source |
| `portside groups` | Lists saved groups |
| `portside tabs` | Lists open tabs and their panes, connected or not |
| `portside connect QUERY [--grid]` | Opens the matching hosts: one tab each, or one grid |
| `portside connect --ids ID,ID` | Opens hosts by the ids that `hosts` printed |
| `portside open-group NAME` | Opens a saved group |
| `portside focus TAB` / `close TAB` | Selects or closes a tab, by id or by title |
| `portside last PANE [--count N]` | Shows the last command(s) in a pane, with exit code and output |
| `portside screen PANE [--lines N]` | Reads a pane's screen as plain text |
| `portside send PANE TEXT [--enter]` | Types into a pane, staged at the prompt unless you add `--enter` |
| `portside send PANE --key KEY` | Presses enter, tab, escape, ctrl-c or ctrl-d |

`PANE` can be a pane id from `tabs`, a host name (when only one pane shows
it), or `current`, which means the pane you're looking at. `current` never
resolves to the pane the agent itself is running in. So if Claude runs in a
split beside your SSH session, `current` is the SSH session, not Claude.

`QUERY` uses the sidebar filter syntax: plain words, `env:prod`, `folder:lab`,
`kind:ssh`, `is:protected`, a leading `-` to exclude, and `/regex/`. An empty
query is refused rather than meaning "everything".

Output is a table in a terminal and JSON when piped, or always JSON with
`--json`.

Exit codes:

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Error |
| 2 | Declined, refused, or timed out in the app |
| 3 | Portside isn't running, or Agent Access is off |

## What asks you first

- **A program's first use.** Portside names the program (for example
  `claude`) and shows its executable path. You choose **Read only**, **Read
  and open**, or **Don't Allow**. The answer is remembered, and you can revoke
  it in Settings ▸ Agents. If you refuse, the program can't ask again for 10
  minutes.
- **Any protected host**, every time, by name.
- **More hosts than your limit at once.** The default is 20, and you can
  change it in Settings ▸ Agents.
- **Closing a tab the agent didn't open.**

The request waits while you decide. If nobody answers within two minutes, the
answer is no.

**Don't Allow and Cancel are always the default buttons**, so Return or
Escape always refuses. For the first moment after a prompt appears, Portside
also ignores approvals, so a Return you were already typing into a terminal
can't approve something you haven't read.

## Typing and reading: the conversation workflow

This is what the API is built around. Portside has an SSH session open, an
agent is in a chat beside it, and you ask things like:

- *"What am I looking at?"* The agent reads `current` with `last` or
  `screen`.
- *"Why did that fail?"* `last` returns just that command's output and exit
  code.
- *"Write me a one-liner to find the ten largest files here."* The agent
  types it at your prompt **without running it**, and you read it and press
  Return.

Typing has its own switch, **Settings ▸ Agents ▸ Allow agents to type into
sessions**, which is off by default. Turning it off takes typing back from
every program and stops the output capture. While it's on:

- **Each pane asks the first time** before an agent can type into it or read
  it. A protected host, and any multi-line text, ask **every** time, the same
  as a MultiExec paste.
- **Staged by default.** Text goes to your prompt and you press Return. The
  agent runs something itself only when it sends `enter`, and the tool
  descriptions tell it to do that only when you asked.
- **Never at a password prompt.** A local prompt shows on the terminal itself
  (echo off while still reading a line). A password prompt on the remote side
  of ssh can't be seen that way, so the pane's last line is checked too
  (`password:`, `passphrase`, `[sudo]`, `verification code`). A match means
  refusal. That check can only refuse, never allow, so a false positive just
  costs you typing the command yourself.
- **Never broadcast.** Agent input goes through the path that doesn't mirror
  to MultiExec peers, even in an armed tab.
- **Control characters are dropped from text**, so escape sequences can't
  ride in. Named keys (`ctrl-c` and so on) are the only way to send one.
- An **"Agent typing" badge** shows on the pane for a few seconds after each
  send.

### Reading cheaply

`last` is the efficient read. Shell integration marks where each command
starts and ends, so Portside keeps the last five commands' output, stripped of
escape codes and capped at 32 KB each, keeping the end. An agent gets
`df -h → exit 0 → 12 lines` for a few hundred tokens. It doesn't scrape a
screen or re-read a transcript. This needs shell integration on the host
(Settings ▸ Terminal). Without it, `screen` reads the visible screen and
scrollback instead.

Session logs are deliberately not offered to agents. They're the whole
history, which is expensive to read and rarely what the question is about.

**Everything an agent reads from a session is marked untrusted.** It's what a
remote machine printed, and it can say anything, including text written to
look like instructions to the agent. The results say so in the data itself,
and the tool descriptions tell the agent to treat it only as data.

## What an agent can never do

- **Arm MultiExec.** A grid opens with every pane a member and broadcast off.
  Arming stays your decision.
- **Type or read without the typing switch on**, or into a pane you
  haven't allowed.
- **See a credential.** Connections go through the same Keychain path as a
  click does, and no command returns a password or key.

## Seeing what happened

- While Agent Access is on, a ✦ icon sits in the toolbar. It lights up after
  any request. Click it to see recent activity, or to turn Agent Access off.
- Every request is logged to `portside.agent.log` beside your library: which
  program, what it asked for (including any text it typed, cut off at 200
  characters), and the outcome. Open it from the ✦ icon's **View Log**, or
  from Settings ▸ Agents. It filters, and can show only refusals and errors.

## What the approval is, and isn't

- The socket accepts only your own user: its file mode is 0600, and the peer's
  uid is checked.
- Which of your programs is asking is worked out from the connecting process's
  parents. Approval keys on the program's name, because Claude Code's real
  executable moves on every update.
- That makes approval about **consent and visibility**: you see who wants in,
  and you decide. It is not a wall against malware already running as you,
  which could just as easily edit your library file. What protects the fleet
  is the per-action prompts above, which are answered in the app and never
  over the socket.
