# Terminal Compatibility

Portside renders terminals with [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).
This matrix records what was **observed** by running real test vectors through a
live Portside terminal — not what the parser claims to accept. Each ✅ was seen
on screen; each ❌ is a confirmed gap.

Last verified: Portside 0.6.1-dev · macOS 14 · MesloLGS Nerd Font Mono.

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

## Known gaps

| Capability | Status | Notes |
|---|---|---|
| Sixel graphics | ❌ | Emitted sixel data prints as text; no image is drawn. |
| iTerm2 inline images (OSC 1337) | ❌ | Sequence is consumed but no image renders. |
| Kitty graphics protocol | ❌ | Not supported. |

Image protocols are a SwiftTerm limitation, not a Portside setting. If you need
inline images, that's a real gap today — file an issue if it matters to your
workflow so we can weigh it.

## How this was tested

Test vectors (truecolor/256/grayscale ramps, every SGR attribute, CJK/emoji/
combining/box/Powerline samples, an OSC 8 link, a Sixel block, an OSC 1337
image, and `vim` for alt-screen + mouse) were emitted into a live Portside
terminal and the rendered output was captured and inspected. To re-run, paste
the ramps and samples into any Portside tab; open `vim` and `:set mouse=a` to
check alt-screen and mouse.
