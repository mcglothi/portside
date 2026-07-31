#!/bin/bash
# Per-file ratchet on Swift 6 strict-concurrency warnings.
#
# The package is on swift-tools 5.9 (Swift 5 language mode), so none of these
# are errors yet — but every one is an error under Swift 6, and there are 248
# of them across 15 files. That migration is a real piece of work, so this
# doesn't demand it be done; it demands the number not move without saying so.
#
# Per file, deliberately, not a single total: a total lets 10 warnings fixed in
# SessionManager silently pay for 10 new ones in TunnelManager, which is
# exactly the drift the ratchet exists to catch.
#
# When you change the warning count in either direction, regenerate:
#   Scripts/strict-concurrency-check.sh --update
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

BASELINE=".github/strict-concurrency-baseline.txt"
# A unique scratch dir per invocation: a fixed path means two concurrent runs
# delete and build into each other's tree.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/portside-strict.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
LOG="$WORK/build.log"
CURRENT="$WORK/current.txt"

# Always from scratch. An incremental build only re-emits warnings for the
# files it actually recompiled, so every untouched file reads as zero — which
# looks like sweeping progress, and would have `--update` write a baseline of
# mostly-zeroes over the real one. Slower, but a ratchet that lies is worse
# than no ratchet.
echo "==> Building with -strict-concurrency=complete (clean)"
if ! swift build -Xswiftc -strict-concurrency=complete \
        --scratch-path "$WORK/build" > "$LOG" 2>&1; then
    echo "FAIL: the strict-concurrency build did not succeed. Warning counts" >&2
    echo "from a failed build are meaningless — a build that dies early emits" >&2
    echo "no warnings at all, which would read as a clean sweep." >&2
    echo "" >&2
    cat "$LOG" >&2
    exit 1
fi

# Repo-relative paths, not basenames: two Swift files can share a name in
# different directories, and keying by basename would silently pool their
# budgets so a regression in one could hide under a fix in the other.
grep -E '^/.*warning:' "$LOG" | sort -u \
    | grep -oE '^/[^:]+\.swift' \
    | sed "s|^$PWD/||" \
    | sort | uniq -c | awk '{print $2" "$1}' | sort > "$CURRENT"

TOTAL="$(awk '{s+=$2} END {print s+0}' "$CURRENT")"
echo "==> $TOTAL strict-concurrency warnings"

if [ "${1:-}" = "--update" ]; then
    cp "$CURRENT" "$BASELINE"
    echo "==> Baseline updated. Commit $BASELINE alongside the change."
    exit 0
fi

if [ ! -f "$BASELINE" ]; then
    echo "FAIL: $BASELINE is missing. Generate it with --update." >&2
    exit 1
fi

# Exact match required, in both directions.
#
# Over baseline is the obvious failure. Under baseline fails too, and that is
# the part that makes this a ratchet rather than a ceiling: leaving slack means
# a file that drops 110 -> 108 still passes at 109 later, so the improvement is
# silently spent instead of held. Failing forces the fix and the tightened
# baseline to land in the same commit.
STATUS=0
STALE=0
while read -r file count; do
    [ -z "$file" ] && continue
    was="$(awk -v f="$file" '$1==f {print $2}' "$BASELINE")"
    was="${was:-0}"
    if [ "$count" -gt "$was" ]; then
        echo "FAIL: $file has $count strict-concurrency warnings, baseline $was" >&2
        STATUS=1
    elif [ "$count" -lt "$was" ]; then
        echo "STALE: $file is down to $count from $was" >&2
        STALE=1
    fi
done < "$CURRENT"

# A file that dropped off the list entirely is an improvement too.
while read -r file was; do
    [ -z "$file" ] && continue
    if ! awk -v f="$file" '$1==f {found=1} END {exit !found}' "$CURRENT"; then
        echo "STALE: $file is now clean (baseline $was)" >&2
        STALE=1
    fi
done < "$BASELINE"

if [ "$STALE" -ne 0 ]; then
    echo "" >&2
    echo "Baseline is stale — warnings were fixed but not locked in." >&2
    echo "Run: Scripts/strict-concurrency-check.sh --update" >&2
    echo "and commit $BASELINE with the fix." >&2
    STATUS=1
fi

if [ "$STATUS" -ne 0 ] && [ "$STALE" -eq 0 ]; then
    echo "" >&2
    echo "New strict-concurrency warnings were introduced. Either fix them, or" >&2
    echo "if they're genuinely unavoidable, raise the baseline deliberately." >&2
fi
exit "$STATUS"
