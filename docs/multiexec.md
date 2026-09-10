# MultiExec — one command, many hosts

MultiExec sends what you type to several hosts at once. That is a small feature
to describe and a large one to get wrong, so most of this page is about the
guardrails rather than the broadcasting.

The short version: **arming is deliberate, staying armed is not assumed, and
every pane tells you at all times whether it is listening.**

## Arming

⇧⌘M, the toolbar button, or View ▸ Toggle MultiExec.

If the current tab has only one pane and there are other tabs open, arming
first gathers every tab into Grid View — assembling the group and arming it are
usually the same motion, so you don't have to do them as two steps.

While armed, each pane carries a status bar reading **Broadcasting** or
**Excluded**. That bar is a real bar at the bottom of the pane, not a floating
badge: an earlier version overlaid a chip on the terminal's first line, which
hid output on every pane for as long as MultiExec was up.

Broadcast is per *tab*. Arming one tab does not arm another, and the notice
explaining an automatic disarm belongs to the tab it happened to.

## Choosing which panes listen

| Action | Shortcut |
|---|---|
| Toggle the focused pane | ⌥⌘M |
| Include All | ⌥⌘A |
| Exclude All | ⌥⌘E |
| Invert Selection | ⌥⌘I |

Also on the armed banner, and under View ▸ MultiExec Panes. Clicking a pane's
status bar toggles that pane.

Excluding the pane you are focused on moves focus to the first pane that *is*
broadcasting, so the next thing you type reaches the group rather than
disappearing into a pane nobody is listening to. You can still click into an
excluded pane and type at it deliberately — that's useful, and it's the
difference between choosing to be there and landing there by accident.

A pane whose session has ended is not a broadcast target. Only running panes
receive.

## Protected hosts

A host marked **protected** in its editor never joins a broadcast through a
bulk action. Include All and Invert Selection deliberately skip it, and say so
in their tooltips.

Sweeping a protected host *out* is always allowed — the guardrail exists in one
direction only. The one way a protected host joins a broadcast is you toggling
that specific pane, which is the whole point of marking it.

This is what to use for the production database that lives in the same folder
as everything else.

## Pasting

Typing is self-limiting: a mistake is one keystroke wide and you watch it land.
Pasting is the opposite — a lot of already-committed input arriving at once, on
every included host simultaneously. It is the one input path where the gap
between what you meant and what ran can be arbitrarily large.

So a paste into an armed broadcast is confirmed first when it is **more than
one command** or **larger than 512 characters**, naming every host it would
reach and showing what would run.

A single command — text with at most one trailing newline — pastes without
asking. That is the shape of nearly every useful paste, and prompting on it
would only train the confirmation away until nobody reads it.

Nothing is confirmed when the broadcast would reach exactly one pane. The
hazard being guarded is fan-out; one pane is your own session and your own
business.

**Return cancels the confirmation rather than accepting it.** The reflex that
got you there — hit paste, hit Return — must not be able to approve it.

## Automatic disarm

Arming asserts two things: *these panes are in a state I have checked*, and *I
want one command to reach all of them.* Anything that invalidates the first
half invalidates the arming. Re-arming costs one keystroke; a mistaken
broadcast cannot be taken back, so the safe direction is not a close call.

Portside disarms by itself when:

- **A pane reconnects.** The replacement is a fresh shell. It may be at a login
  prompt, in a different directory, or — if DNS or a jump host moved underneath
  it — on a different machine.
- **The Mac changes network.** Established connections survive the change and
  only new ones follow the new route, so coming off a VPN or moving between
  office and home Wi-Fi can leave `prod-db` pointing somewhere else while the
  panes look untouched.
- **The Mac wakes from sleep.** Everything on the far side of every connection
  had an unbounded amount of time to change while nobody was watching.

Each says which of these happened, on the tab it happened to. Re-arming clears
the notice.

## Groups always open disarmed

A saved group reopens assembled and ready, with arming still a separate,
deliberate act. Restoring a workspace at launch behaves the same way — nothing
comes back already broadcasting.

## Macros

Running a macro while armed sends it to every included pane. Unarmed, it goes
to the focused pane only. The same rule, and the same guardrails, as typing.

## Per-host results

Under the command bar, the last broadcast lists what each host reported: the
command, a one-line summary, and a row per pane.

**Every row is an observation, never an inference.** Results come from the
OSC 133 shell-integration markers the command timeline already reads, which
means a host only appears as finished because it said so:

| Row | Means |
|---|---|
| ✅ / ❌ Finished, exit *n* | The shell reported this command and its status. |
| ⏳ Running since… | The shell reported it started, and has not reported an end. |
| … Sent — waiting | Delivered; this pane has reported boundaries before, so a result is expected. |
| ❓ Can't be observed — … | Delivered, and nothing is coming. The bar says how to fix it — see below. |
| ⑂ A different command finished here | Something else ran in that pane. Its exit status is **not** reported as the broadcast's. |

A host cannot be observed for one of two reasons, and the bar names the fix
for whichever applies rather than leaving you to work it out:

- **Command recording is off.** No host can report, because the command
  timeline is never allocated. One switch fixes every row: Settings ▸ Terminal
  ▸ Record commands, then reconnect. The bar offers the button.
- **That pane has never reported a command boundary.** The usual cause is a
  host without shell integration. Install it permanently from the file
  browser's ⋯ menu ▸ Install…, or switch on Settings ▸ Terminal ▸ "Set up
  directory tracking on connect" to have Portside type it into each SSH
  session instead. Either way the pane has to reconnect.

A pane sitting in `vim` or a pager reports nothing either, and looks the same
from here — the keystrokes arrive and no command boundary is ever emitted.

These rows say so rather than sitting on "waiting", because a row that waits
forever eventually gets read as though it went fine.

Results belong to the tab that sent them: arming two tabs and broadcasting in
one does not put its hosts on the other.

When the shell reports a boundary without naming the command — bash's `DEBUG`
trap cannot always supply it — the row says the result was matched by timing
rather than presenting it as confirmed.

Running a macro while armed reports the same way.

## What it does not do

- **No guarantee that what ran is what you sent.** The rows above report what
  hosts said, and a host that says nothing is shown as silent, not as
  successful. A pane mid-prompt, in a pager, or in vim receives the same
  keystrokes as everything else and will do whatever that means for them.
- **No ordering or synchronisation.** All included panes receive at once. A
  host that is slow, paging, or wedged simply lags.
- **No retry.** A host that did not answer is shown as not having answered and
  is left alone. If one host was disconnected, its pane is not a target —
  which is why the status bars are always visible rather than on hover.

For anything where you need to know what ran and what came back, a real
orchestration tool is the right answer. MultiExec is for the case where you are
watching.

---

*Status: describes 0.22. If a guardrail here surprises you in practice — too
strict, not strict enough, or explaining itself badly — that's worth an
[issue](https://github.com/mcglothi/portside/issues/new/choose); several of
these thresholds were set by one person's judgement and would benefit from
more.*
