#!/usr/bin/env python3
"""Validate a Portside shared-inventory manifest before it's merged.

Copy this file into your inventory repository and run it in CI on every pull
request, so a broken or unsafe manifest never reaches the branch everyone
subscribes to:

    python3 portside-inventory-check.py portside.json

It applies the same rules Portside itself does when reading a shared inventory
and when publishing one:

  errors (exit 1)
    - the file isn't a Portside sessions export
    - two hosts share an id
    - a host, ssh alias or user that Portside would refuse to pass to ssh
      (anything that could be read as an option, or holds characters a host
      name or user can't)
    - anything that looks like a secret: passwords in URLs, private keys,
      GitHub/GitLab/Slack/AWS tokens, `password: ...`, long random strings

  warnings
    - records subscribers will skip (only SSH hosts are shared)
    - personal settings subscribers will ignore (run-on-connect, forwarding,
      credential profiles, saved-password flags, favourites)

No dependencies beyond the Python standard library. `--json` prints the
per-host verdicts as JSON (used by Portside's own tests to keep this script
and the app in agreement).
"""
import json
import re
import sys

HOST_CHARS = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:_")
USER_CHARS = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-\\")

SECRET_PATTERNS = [
    (r"[A-Za-z][A-Za-z0-9+.-]*://[^/\s:@]+:[^@\s]+@", "contains a URL with a password in it"),
    (r"-----BEGIN [A-Z ]*PRIVATE KEY-----", "contains a private key"),
    (r"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}", "contains a GitHub token"),
    (r"\bgithub_pat_[A-Za-z0-9_]{20,}", "contains a GitHub token"),
    (r"\bglpat-[A-Za-z0-9_-]{16,}", "contains a GitLab token"),
    (r"\bxox[abprs]-[A-Za-z0-9-]{10,}", "contains a Slack token"),
    (r"\bAKIA[0-9A-Z]{16}\b", "contains an AWS access key"),
    (r"(?i)\b(password|passwd|pwd|secret|token)\s*[:=]\s*\S+", "looks like it contains a password"),
]


def secret_reason(value):
    for pattern, why in SECRET_PATTERNS:
        if re.search(pattern, value):
            return why
    for token in re.split(r"[\s/]+", value):
        if len(token) >= 32:
            classes = sum([any(c.isupper() for c in token), any(c.islower() for c in token),
                           any(c.isdigit() for c in token)])
            if classes == 3 and len(set(token)) >= 16:
                return "contains a long random-looking string"
    return None


def has_control(s):
    return any(ord(c) < 32 or 0x7F <= ord(c) <= 0x9F for c in s)


def safe_host(h):
    return 0 < len(h) <= 253 and not h.startswith("-") and all(c in HOST_CHARS for c in h)


def safe_user(u):
    return len(u) <= 64 and not u.startswith("-") and all(c in USER_CHARS for c in u)


def clean(v):
    v = (v or "").strip()
    return v or None


# Mirrors SharedManifest.sharedContainer: a shared container's exec is typed
# into the remote shell, so each field must be a plain name.
CONTAINER_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,254}")
CONTAINER_USER = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,63})?")
PLAIN_SHELLS = {"sh", "bash", "ash", "dash", "zsh", "ksh", "mksh", "fish"}
ENGINES = {"docker", "podman", "nerdctl"}


def plain_shell(s):
    return any(s.startswith(d) and s[len(d):] in PLAIN_SHELLS
               for d in ("", "/bin/", "/usr/bin/", "/usr/local/bin/"))


def container_problem(target):
    """Why a shared container target can't be kept, or None."""
    if not isinstance(target, dict):
        return "has no container"
    name = (target.get("name") or "").strip()
    shell = (target.get("shell") or "").strip()
    user = (target.get("user") or "").strip()
    if target.get("engine", "docker") not in ENGINES:
        return "engine %r isn't docker, podman or nerdctl" % target.get("engine")
    if not CONTAINER_NAME.fullmatch(name):
        return "container name %r isn't a plain container name" % name
    if shell and not plain_shell(shell):
        return "shell %r isn't a plain shell (sh, bash, ...)" % shell
    if user and not CONTAINER_USER.fullmatch(user):
        return "container user %r isn't a plain user or uid:gid" % user
    return None


def verdict(entry):
    """Whether subscribers keep this record, and why not if they don't."""
    if not isinstance(entry, dict) or not isinstance(entry.get("name"), str):
        return "skip", "unreadable record"
    kind = entry.get("kind", "host")
    if kind not in ("host", "container"):
        return "skip", "only SSH hosts and containers on them are shared (this is %s)" % kind
    host, alias, user = clean(entry.get("hostname")), clean(entry.get("sshAlias")), clean(entry.get("user"))
    if kind == "container":
        if host is None and alias is None:
            return "skip", "a container on the publisher's Mac isn't shared, only one on an SSH host"
        problem = container_problem(entry.get("container"))
        if problem:
            return "error", problem
    if host is None and alias is None:
        return "error", "has neither a host nor an ssh alias"
    if host is not None and not safe_host(host):
        return "error", "host %r can't be passed to ssh safely" % host
    if alias is not None and not safe_host(alias):
        return "error", "ssh alias %r can't be passed to ssh safely" % alias
    if user is not None and not safe_user(user):
        return "error", "user %r can't be passed to ssh safely" % user
    key = clean(entry.get("identityFile"))
    if key is not None and has_control(key):
        return "error", "identity file path contains control characters"
    return "keep", None


PERSONAL = [("runOnConnect", "run-on-connect"), ("forwardAgent", "agent forwarding"),
            ("forwardX11", "X11 forwarding"), ("credentialProfileID", "credential profile"),
            ("savePassword", "saved password"), ("isFavorite", "favourite")]


def check(doc):
    errors, warnings, rows = [], [], []
    entries = doc.get("entries") if isinstance(doc, dict) else None
    if not isinstance(entries, list):
        return ["not a Portside sessions export (no entries list)"], [], []
    seen = set()
    for i, e in enumerate(entries):
        name = e.get("name", "record %d" % i) if isinstance(e, dict) else "record %d" % i
        v, why = verdict(e)
        secrets = []
        if isinstance(e, dict):
            ident = e.get("id")
            if ident in seen:
                errors.append("%s: duplicate id %s" % (name, ident))
            seen.add(ident)
            for field, label in (("name", "name"), ("folder", "folder"), ("identityFile", "identity file")):
                why_secret = secret_reason(str(e.get(field) or ""))
                if why_secret:
                    secrets.append("%s %s" % (label, why_secret))
            for key, label in PERSONAL:
                val = e.get(key)
                if val not in (None, False, "") and v == "keep":
                    warnings.append("%s: %s will be ignored by subscribers" % (name, label))
        if v == "error":
            errors.append("%s: %s" % (name, why))
        elif v == "skip":
            warnings.append("%s: skipped by subscribers, %s" % (name, why))
        for s in secrets:
            errors.append("%s: %s" % (name, s))
        rows.append({"name": name, "verdict": v, "secret": bool(secrets)})
    for f in doc.get("folders") or []:
        why_secret = secret_reason(str(f))
        if why_secret:
            errors.append("folder %r %s" % (f, why_secret))
    return errors, warnings, rows


def main(argv):
    as_json = "--json" in argv
    paths = [a for a in argv if not a.startswith("--")]
    if len(paths) != 1:
        print(__doc__.strip().splitlines()[0])
        print("usage: portside-inventory-check.py [--json] MANIFEST")
        return 2
    try:
        with open(paths[0], encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as exc:
        print("error: can't read %s: %s" % (paths[0], exc))
        return 1
    errors, warnings, rows = check(doc)
    if as_json:
        print(json.dumps({"errors": errors, "warnings": warnings, "hosts": rows}, indent=2))
    else:
        for w in warnings:
            print("warning: " + w)
        for e in errors:
            print("error: " + e)
        kept = sum(1 for r in rows if r["verdict"] == "keep")
        print("%s: %d hosts, %d errors, %d warnings" % (paths[0], kept, len(errors), len(warnings)))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
