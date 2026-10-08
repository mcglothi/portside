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

## What an agent can never do

- **Arm MultiExec.** A grid opens with every pane a member and broadcast off.
  Arming stays your decision.
- **Type into a session, or read a session's screen.** This is planned as a
  separate, opt-in tier. See `agent-api-plan.md`.
- **See a credential.** Connections go through the same Keychain path as a
  click does, and no command returns a password or key.

## Seeing what happened

- While Agent Access is on, a ✦ icon sits in the toolbar. It lights up after
  any request. Click it to see recent activity, or to turn Agent Access off.
- Every request is logged to `portside.agent.log` beside your library: which
  program, what it asked for, and the outcome.

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
