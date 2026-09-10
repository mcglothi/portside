# Terminal Compatibility

Portside renders terminals with [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).
This matrix records what was **observed** by running real test vectors through a
live Portside terminal — not what the parser claims to accept. Each ✅ was seen
on screen; each ❌ is a confirmed gap.

Verification is per-section, not whole-file, and each section says when it was
last measured. The color, text-attribute, Unicode and control-sequence tables
below were observed on Portside 0.6.1-dev · macOS 14 · MesloLGS Nerd Font Mono
and have **not** been re-run since; treat them as the last direct observation
rather than a statement about the current build. Inline graphics were
re-measured later — see that section.

## Color

| Capability | Status | Notes |
|---|---|---|
| 24-bit truecolor (`38;2;r;g;b`) | ✅ | Smooth gradient, no visible banding. |
| 256-color palette (`38;5;n`) | ✅ | Full 216-color cube renders distinctly. |
| Grayscale ramp (232–255) | ✅ | Smooth 24-step ramp. |
| 16-color ANSI + bright | ✅ | Themed via Appearance settings. |

## Text attributes

| Capability | Status | Notes |
|---|---|---|
| Bold | ✅ | |
| Dim / faint | ✅ | |
| Italic | ✅ | Requires an italic face in the chosen font. |
| Underline | ✅ | |
| Strikethrough | ✅ | |
| Reverse video | ✅ | |
| Blink | ⚠️ | Renders; blink animation not separately confirmed. |
| Curly / colored underline (`4:3`) | ⚠️ | Draws an underline; curly styling not distinguishable at test size. |

## Unicode & glyphs

| Capability | Status | Notes |
|---|---|---|
| CJK wide characters | ✅ | Correct double-width cells. |
| Color emoji | ✅ | Rendered in color, double-width. |
| Combining marks | ✅ | `e´`, `a`` `, `n~` compose correctly. |
| Box-drawing | ✅ | |
| Powerline / Nerd Font glyphs | ✅ | With a Nerd Font (bundled MesloLGS). |

## Interaction & screen

| Capability | Status | Notes |
|---|---|---|
| Alternate screen buffer | ✅ | Full-screen TUIs (vim/less) take over and restore. |
| Mouse reporting (SGR 1006) | ✅ | Click in `vim` with `mouse=a` moves the cursor to the clicked cell. |
| Scrollback + `⌘F` search | ✅ | Configurable depth (Settings → Terminal), default 10,000 lines. |
| Cursor styles (DECSCUSR) | ✅ | Steady/blink bar/block/underline accepted. |
| OSC 8 hyperlinks | ⚠️ | Parsed and tracked by SwiftTerm; link text renders. Click-through not independently verified in this pass. |

## Inline graphics

Re-measured 2026-07-27 against SwiftTerm 1.15.0 and re-checked 2026-09-09
against the current pin, 1.16.0. **This section previously listed all three
protocols as unsupported.** That was accurate when
written — it was measured against SwiftTerm 0.6.1-dev — and has been wrong since
the dependency moved to 1.x. All three are now parsed, decoded, and handed to
the front end, which draws them.

| Capability | Status | Notes |
|---|---|---|
| Sixel graphics | ✅ | Decodes and renders. |
| iTerm2 inline images (OSC 1337) | ✅ | Base64 payload is decoded and drawn. |
| Kitty graphics protocol | ✅ | `a=T` transmit-and-display reaches the renderer. |

**The Sixel crash is fixed upstream and the workaround is gone.** SwiftTerm's
`SixelDcsHandler` measured an image in one pass and filled it in a second, but
the measuring pass only widened the image on a band terminator (`$` or `-`). A
sixel whose *final* band was wider than every terminated band before it — which
includes every single-band image of width ≥ 2 — was measured too narrow, and the
fill pass wrote past the end of the buffer. That was a `fatalError`, reachable
from nothing more than output arriving over an SSH session.

SwiftTerm commit `58915b10` ("Fix sixel crash") landed 2026-07-19, two hours and
forty-six minutes after `v1.15.0` was tagged — which is why Portside carried its
own `SixelStreamGuard` from 0.17.0. **The pin has since moved to 1.16.0, which
contains `58915b10`, and the guard was deleted.** Sixel data now goes straight
to the parser with nothing of ours in the path. Verified by confirming
`58915b10` is an ancestor of the pinned revision
(`3917686ea5f5527c5451aaf371bd90bf3618aa71`) rather than by reading the version
number alone.

Portside still advertises Sixel support in its device attributes
(SwiftTerm's `TerminalOptions.enableSixelReported` defaults to true), so
applications probe, find it, and send. Coverage lives in
`Tests/PortsideTests/InlineImageProtocolTests.swift`.

## How this was tested

Test vectors (truecolor/256/grayscale ramps, every SGR attribute, CJK/emoji/
combining/box/Powerline samples, an OSC 8 link, a Sixel block, an OSC 1337
image, and `vim` for alt-screen + mouse) were emitted into a live Portside
terminal and the rendered output was captured and inspected. To re-run, paste
the ramps and samples into any Portside tab; open `vim` and `:set mouse=a` to
check alt-screen and mouse.

The inline-graphics row was re-measured differently, and deliberately: by
feeding the escape sequences straight into a `Terminal` with a recording
delegate, in `InlineImageProtocolTests`. A rendering pass can only tell you an
image appeared; the delegate tells you the payload decoded to the right pixel
dimensions, and it re-runs on every `swift test` rather than on someone
remembering to paste vectors into a tab.
