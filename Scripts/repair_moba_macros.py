#!/usr/bin/env python3
"""Repair macros imported from MobaXterm before the key-name fix.

The importer used to append MobaXterm's key *labels* verbatim, so a space came
through as the literal word `SPACE` and `yum update -y` became
`yumSPACEupdateSPACE-y`. Re-importing the file does not fix an affected macro:
`SessionStore.addImported` skips any macro whose name already exists, by design,
so the broken copy stays. This repairs them in place instead.

    python3 Scripts/repair_moba_macros.py            # dry run, prints a report
    python3 Scripts/repair_moba_macros.py --apply    # writes, after a backup

**Quit Portside first.** It holds the library in memory and rewrites the file
when anything changes, so edits made underneath a running app get overwritten.
The script refuses to write while it sees the app running.

Only macros that are *unambiguously* damaged are touched: one containing a key
name but no real whitespace could not have been typed that way by hand. Anything
containing a key name *and* real spaces is reported for you to look at rather
than rewritten, because `echo SPACE` is a legitimate macro.
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

LIBRARY = Path.home() / "Library/Application Support/Portside/portside.json"

# MobaXterm's own format escapes, for characters that collide with its
# delimiters: `|` separates tokens, `:` separates fields, `=` splits name from
# sequence, `;` starts a comment. French names — PTVIRG is *point-virgule*,
# DBLDOT is *deux-points*. These are unambiguous: no macro types them by hand.
FORMAT_ESCAPES = {
    "__DBLQUO__": '"',
    "__PTVIRG__": ";",
    "__PIIPE__": "|",
    "__EQQUAL__": "=",
    "__DBLDOT__": ":",
}

# Key labels with an unambiguous text form. Arrows and F-keys were dropped on
# import rather than inlined, so there is nothing to recover for those.
NAMED_KEYS = {
    "SPACE": " ",
    "TAB": "\t",
    "RETURN": "\n",
    "ENTER": "\n",
    "ESCAPE": "\x1b",
    "ESC": "\x1b",
    "PIPE": "|",
    "COLON": ":",
}

CTRL = re.compile(r"Ctrl\+([A-Za-z])")

# Labels seen in the wild that have no safe automatic text form. Reported after
# a repair rather than rewritten: BACK is probably backspace, but "probably" is
# not good enough to rewrite somebody's command with.
RESIDUAL_LABELS = [
    "DELETE", "INSERT", "PGUP", "PGDN", "HOME", "END", "ALTGR",
]

# Backspace, applied rather than recorded — see `apply_backspaces`.
BACKSPACE_LABELS = ("BACKSPACE", "BACK")


def portside_running():
    try:
        return subprocess.run(["pgrep", "-x", "Portside"],
                              capture_output=True).returncode == 0
    except OSError:
        return False


def apply_backspaces(text):
    """Applies BACK/BACKSPACE labels as deletions, left to right.

    `/BACKBACK` at the end of a line means the person typed `/` and then hit
    backspace twice, so it and the space before it go.

    Less safe here than in the importer, where the label is a whole field and
    can be matched exactly. By the time text reaches this script it is all one
    string, so a macro genuinely containing BACKUP would lose its U. The dry run
    prints every before/after for exactly this reason — read them.
    """
    out, i = [], 0
    while i < len(text):
        for label in BACKSPACE_LABELS:  # longest first
            if text.startswith(label, i):
                if out:
                    out.pop()
                i += len(label)
                break
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def repair(text):
    """Returns (new_text, changed). Longest names first so ESCAPE beats ESC."""
    out = text
    for token, literal in FORMAT_ESCAPES.items():
        out = out.replace(token, literal)
    for name in sorted(NAMED_KEYS, key=len, reverse=True):
        out = out.replace(name, NAMED_KEYS[name])
    out = CTRL.sub(lambda m: chr(ord(m.group(1).upper()) - 64), out)
    # Last, so the deletions land on decoded characters rather than on the
    # middle of an escape token.
    out = apply_backspaces(out)
    return out, out != text


def classify(text):
    """`damaged`, `ambiguous`, or `clean`.

    A format escape is unambiguous on its own — nothing types `__DBLQUO__` by
    hand — so its presence alone means damaged.

    A bare key *name* is weaker evidence, because `echo SPACE is a word` is a
    legitimate macro. Those only count as damaged when the text has no real
    whitespace at all, which is the signature of every space having become a
    word. Otherwise the macro is reported for a human to look at.
    """
    if (any(token in text for token in FORMAT_ESCAPES)
            or CTRL.search(text)
            or any(label in text for label in BACKSPACE_LABELS)):
        return "damaged"
    if not any(name in text for name in NAMED_KEYS):
        return "clean"
    return "ambiguous" if any(c.isspace() for c in text) else "damaged"


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--apply", action="store_true", help="write the changes")
    parser.add_argument("--library", type=Path, default=LIBRARY)
    args = parser.parse_args()

    if not args.library.exists():
        sys.exit(f"no library at {args.library}")

    document = json.loads(args.library.read_text())
    macros = document.get("macros", [])
    if not macros:
        print("No macros in the library — nothing to do.")
        return

    fixed, ambiguous = [], []
    for macro in macros:
        text = macro.get("text", "")
        state = classify(text)
        if state == "damaged":
            new_text, _ = repair(text)
            fixed.append((macro.get("name", "?"), text, new_text))
            macro["text"] = new_text
        elif state == "ambiguous":
            ambiguous.append((macro.get("name", "?"), text))

    print(f"{len(macros)} macros; {len(fixed)} to repair, "
          f"{len(ambiguous)} need a look, {len(macros) - len(fixed) - len(ambiguous)} fine.\n")

    for name, before, after in fixed:
        print(f"  {name}")
        print(f"    before: {before!r}")
        print(f"    after:  {after!r}")

    residual = []
    for macro in macros:
        found = [w for w in RESIDUAL_LABELS if w in macro.get("text", "")]
        if found:
            residual.append((macro.get("name", "?"), found, macro.get("text", "")))

    if residual:
        print("\nStill contain something that looks like a MobaXterm key label.")
        print("Not guessed at — check these by hand:\n")
        for name, found, text in residual:
            print(f"  {name}  [{', '.join(found)}]")
            print(f"    {text!r}")

    if ambiguous:
        print("\nLeft alone — these contain a key name *and* real spaces, so they may")
        print("be intentional. Check them by hand:\n")
        for name, text in ambiguous:
            print(f"  {name}: {text!r}")

    if not fixed:
        return

    if not args.apply:
        print("\nDry run. Re-run with --apply to write.")
        return

    if portside_running():
        sys.exit("\nPortside is running — quit it first, or your edits get "
                 "overwritten the next time it saves.")

    backup = args.library.with_suffix(".json.before-macro-repair")
    shutil.copy2(args.library, backup)
    args.library.write_text(json.dumps(document, indent=2, ensure_ascii=False))
    print(f"\nRepaired {len(fixed)} macros. Backup: {backup}")


if __name__ == "__main__":
    main()
