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
import shutil
import subprocess
import sys
from pathlib import Path

LIBRARY = Path.home() / "Library/Application Support/Portside/portside.json"

# Only the labels with an unambiguous text form. Arrows and F-keys were dropped
# on import rather than inlined, so there is nothing to recover for those.
NAMED_KEYS = {
    "SPACE": " ",
    "TAB": "\t",
    "RETURN": "\n",
    "ENTER": "\n",
    "ESCAPE": "\x1b",
    "ESC": "\x1b",
}


def portside_running():
    try:
        return subprocess.run(["pgrep", "-x", "Portside"],
                              capture_output=True).returncode == 0
    except OSError:
        return False


def repair(text):
    """Returns (new_text, changed). Longest names first so ESCAPE beats ESC."""
    out, changed = text, False
    for name in sorted(NAMED_KEYS, key=len, reverse=True):
        if name in out:
            out = out.replace(name, NAMED_KEYS[name])
            changed = True
    return out, changed


def classify(text):
    """`damaged`, `ambiguous`, or `clean`.

    A macro with a key name and no real whitespace is damaged: nobody types
    `yumSPACEupdate` deliberately. One that has both is left alone.
    """
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
