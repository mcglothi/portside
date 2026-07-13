#!/usr/bin/env python3
"""Regenerates Sources/Portside/Resources/BundledThemes.json from the
mbadolato/iTerm2-Color-Schemes repo (MIT licensed).

Downloads the curated scheme list below, converts each .itermcolors plist to
Portside's TerminalTheme JSON shape, and writes them sorted by name. Run from
anywhere; paths are resolved relative to this script.

    python3 Scripts/update_bundled_themes.py
"""

import json
import plistlib
import sys
import urllib.parse
import urllib.request
from pathlib import Path

RAW_BASE = "https://raw.githubusercontent.com/mbadolato/iTerm2-Color-Schemes/master/schemes/"

# (repo filename without extension, display name in Portside)
CURATED = [
    ("Atom One Dark", "One Dark"),
    ("Atom One Light", "One Light"),
    ("Ayu", "Ayu"),
    ("Ayu Light", "Ayu Light"),
    ("Ayu Mirage", "Ayu Mirage"),
    ("Catppuccin Frappe", "Catppuccin Frappe"),
    ("Catppuccin Latte", "Catppuccin Latte"),
    ("Catppuccin Macchiato", "Catppuccin Macchiato"),
    ("Catppuccin Mocha", "Catppuccin Mocha"),
    ("Dracula", "Dracula"),
    ("Everforest Dark Med", "Everforest Dark"),
    ("GitHub Dark Default", "GitHub Dark"),
    ("GitHub Light Default", "GitHub Light"),
    ("Gruvbox Dark", "Gruvbox Dark"),
    ("Gruvbox Light", "Gruvbox Light"),
    ("Kanagawa Wave", "Kanagawa Wave"),
    ("Monokai Remastered", "Monokai"),
    ("Night Owl", "Night Owl"),
    ("Nord", "Nord"),
    ("Nord Light", "Nord Light"),
    ("Oceanic Next", "Oceanic Next"),
    ("Rose Pine", "Rosé Pine"),
    ("Rose Pine Dawn", "Rosé Pine Dawn"),
    ("Rose Pine Moon", "Rosé Pine Moon"),
    ("Snazzy", "Snazzy"),
    ("TokyoNight", "Tokyo Night"),
    ("TokyoNight Day", "Tokyo Night Day"),
    ("TokyoNight Storm", "Tokyo Night Storm"),
    ("iTerm2 Solarized Dark", "Solarized Dark"),
    ("iTerm2 Solarized Light", "Solarized Light"),
    ("Zenburn", "Zenburn"),
]


def component_hex(color: dict) -> str:
    return "#%02X%02X%02X" % tuple(
        round(color[f"{ch} Component"] * 255) for ch in ("Red", "Green", "Blue")
    )


def convert(data: bytes, name: str) -> dict:
    plist = plistlib.loads(data)
    ansi = [component_hex(plist[f"Ansi {i} Color"]) for i in range(16)]
    return {
        "name": name,
        "foreground": component_hex(plist["Foreground Color"]),
        "background": component_hex(plist["Background Color"]),
        "cursor": component_hex(plist["Cursor Color"]),
        "ansi": ansi,
    }


def main() -> int:
    themes = []
    for filename, display in CURATED:
        url = RAW_BASE + urllib.parse.quote(f"{filename}.itermcolors")
        try:
            with urllib.request.urlopen(url, timeout=30) as resp:
                themes.append(convert(resp.read(), display))
            print(f"  ok  {display}")
        except Exception as e:  # noqa: BLE001 — report which theme failed
            print(f"FAIL  {display}: {e}", file=sys.stderr)
            return 1

    themes.sort(key=lambda t: t["name"].lower())
    out = Path(__file__).resolve().parent.parent / "Sources/Portside/Resources/BundledThemes.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(themes, indent=2, ensure_ascii=False) + "\n")
    print(f"Wrote {len(themes)} themes to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
