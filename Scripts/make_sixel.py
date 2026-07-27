#!/usr/bin/env python3
"""Encode a PNG as a Sixel image.

Exists so `docs/demo/portside-logo.six` can be regenerated from the app icon
without asking anyone to install libsixel or ImageMagick. Deliberately
dependency-free: it decodes the PNG with `zlib` and nothing else.

    python3 Scripts/make_sixel.py icon.png > out.six

Two details are load-bearing rather than stylistic:

* **Every band is terminated.** SwiftTerm 1.15.0 crashes on a final band that is
  wider than every terminated band before it — see `SixelStreamGuard`. Portside
  repairs that on the way in, but a file we publish should not be relying on the
  workaround, because people will `cat` it into other terminals.
* **Fully transparent pixels are left unpainted** rather than filled, so the
  icon's rounded corners take the terminal's own background instead of arriving
  with a white box around them.
"""

import struct
import sys
import zlib

# Sixel colour components are 0-100, not 0-255.
SIXEL_SCALE = 100 / 255


def decode_png(data):
    """Returns (width, height, rows) with rows as lists of (r, g, b, a)."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")

    width = height = depth = colour = None
    idat = bytearray()
    pos = 8
    while pos < len(data):
        length, tag = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if tag == b"IHDR":
            width, height, depth, colour = struct.unpack(">IIBB", body[:10])
        elif tag == b"IDAT":
            idat += body
        elif tag == b"IEND":
            break
        pos += 12 + length

    if depth != 8 or colour not in (2, 6):
        raise ValueError(f"need 8-bit RGB or RGBA, got depth={depth} colour={colour}")

    channels = 4 if colour == 6 else 3
    raw = zlib.decompress(bytes(idat))
    stride = width * channels
    rows, previous = [], bytearray(stride)

    at = 0
    for _ in range(height):
        filter_type = raw[at]
        line = bytearray(raw[at + 1:at + 1 + stride])
        at += 1 + stride
        # PNG line filters, per spec: each byte is predicted from its left
        # neighbour (a), the byte above (b), and above-left (c).
        for i in range(stride):
            a = line[i - channels] if i >= channels else 0
            b = previous[i]
            c = previous[i - channels] if i >= channels else 0
            if filter_type == 1:
                line[i] = (line[i] + a) & 0xFF
            elif filter_type == 2:
                line[i] = (line[i] + b) & 0xFF
            elif filter_type == 3:
                line[i] = (line[i] + (a + b) // 2) & 0xFF
            elif filter_type == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 0xFF
        previous = line
        rows.append([
            tuple(line[x * channels:x * channels + channels]) + ((255,) if channels == 3 else ())
            for x in range(width)
        ])
    return width, height, rows


def quantise(rows, levels=32):
    """Snaps colours to a cube so the palette fits Sixel's 256 registers.

    32 levels per channel puts the app icon at 178 entries — comfortably under
    the limit, and enough for its navy gradient. A coarser 6 fit in 17 entries
    but banded the gradient into visible stripes, which is the first thing you
    notice in a screenshot.
    """
    step = 255 / (levels - 1)
    palette, indexed = {}, []
    for row in rows:
        out = []
        for r, g, b, a in row:
            if a < 128:
                out.append(None)  # transparent: left unpainted
                continue
            key = (
                round(round(r / step) * step),
                round(round(g / step) * step),
                round(round(b / step) * step),
            )
            if key not in palette:
                palette[key] = len(palette)
            out.append(palette[key])
        indexed.append(out)
    return palette, indexed


def encode(width, height, palette, indexed):
    out = ["\x1bPq", f'"1;1;{width};{height}']
    for (r, g, b), index in palette.items():
        out.append(
            f"#{index};2;{round(r * SIXEL_SCALE)};"
            f"{round(g * SIXEL_SCALE)};{round(b * SIXEL_SCALE)}"
        )

    for top in range(0, height, 6):
        band = indexed[top:top + 6]
        present = {i for row in band for i in row if i is not None}
        for index in sorted(present):
            bits = []
            for x in range(width):
                value = 0
                for dy, row in enumerate(band):
                    if row[x] == index:
                        value |= 1 << dy
                bits.append(chr(63 + value))
            out.append(f"#{index}" + run_length(bits))
            out.append("$")  # back to column 0 for the next colour in this band
        out.append("-")      # terminate the band -- always, including the last
    out.append("\x1b\\")
    return "".join(out)


def run_length(chars):
    """`!<count><char>` for runs of four or more, which is where it pays off."""
    out, run_char, count = [], chars[0], 1
    for ch in chars[1:] + [None]:
        if ch == run_char:
            count += 1
            continue
        out.append(f"!{count}{run_char}" if count >= 4 else run_char * count)
        run_char, count = ch, 1
    return "".join(out)


def trim_transparent(rows):
    """Drops fully transparent borders.

    An app icon carries margin inside its canvas, which in a terminal is just
    blank lines above and below the mark.
    """
    def opaque(row):
        return any(a >= 128 for *_, a in row)

    top, bottom = 0, len(rows)
    while top < bottom and not opaque(rows[top]):
        top += 1
    while bottom > top and not opaque(rows[bottom - 1]):
        bottom -= 1
    rows = rows[top:bottom]
    if not rows:
        return rows

    width = len(rows[0])
    left, right = 0, width
    while left < right and all(row[left][3] < 128 for row in rows):
        left += 1
    while right > left and all(row[right - 1][3] < 128 for row in rows):
        right -= 1
    return [row[left:right] for row in rows]


def main():
    args = sys.argv[1:]
    trim = "--trim" in args
    args = [a for a in args if a != "--trim"]
    if len(args) != 1:
        sys.exit(f"usage: {sys.argv[0]} [--trim] <image.png>")
    width, height, rows = decode_png(open(args[0], "rb").read())
    if trim:
        rows = trim_transparent(rows)
        height = len(rows)
        width = len(rows[0]) if rows else 0
    palette, indexed = quantise(rows)
    if len(palette) > 256:
        sys.exit(f"palette too large ({len(palette)}); lower `levels`")
    sys.stdout.write(encode(width, height, palette, indexed))


if __name__ == "__main__":
    main()
