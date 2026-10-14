# Kitty image guard: PR #63 review and fixes

Last Updated: 2026-10-13

Review of `7a654c3` reproduced two errors through real SwiftTerm and
AppKit-generated PNGs: a 4097×1 PNG was rejected with `f=100` but accepted with
`f=+100`, `f=0100`, or `f=00000100`; a standalone incomplete `f=100;iVBO`
command (without `m=1`) made the next independent 32×32 PNG fail.

Both cancelled CI runs, [38496774737](https://github.com/mcglothi/portside/actions/runs/38496774737)
and [38494941381](https://github.com/mcglothi/portside/actions/runs/38494941381),
last started `KeyRotatorScriptTests.testTheGuardHoldsUnderEveryShell`.
They do not establish a Kitty decoder hang or macOS 15 Foundation difference.
The shell harness is handled separately in PR #66.

## Fix

The guard parses `f` and `m` in constant space with Swift's signed decimal
semantics, including arbitrary leading zeros and overflow. Values commit at
their delimiter: the last ASCII value wins (empty and malformed integers reset
to defaults); non-ASCII values leave an earlier entry alone. The relevant
character keys (`a`, `t`, `o`) follow the same dictionary rules.

A transfer marker mirrors SwiftTerm's pending transaction, including raw images
and headers already allowed or refused. Continuation keys cannot restart an
image check. Only dispatched `m=1,t=d` commands retain it; final chunks and
deletion reset it. Aborted APCs neither create nor consume a pending transfer.
ESC, BEL, and ST dispatch, including an empty first chunk with no semicolon or
with a trailing comma. Deletion starts a distinct transaction even with `m=1`.

Once refused, every remaining payload byte becomes padding, across chunks.
The retained encoded prefix ends before the header byte that caused refusal.
A regression simulates a decoder more permissive than Foundation: remove **all**
internal padding, restore legal trailing padding, and feed the result to real
SwiftTerm. Neither PNG nor JPEG can be recovered, including a valid image hidden
after premature padding. This tests rejection without relying on Foundation
stopping at the first padding byte. No macOS 15 execution is claimed.

## Validation and falsification

Local host: macOS 27.0.1, Swift 6.4. Full suite: 1389 tests, 19 skipped, zero
failures (165.9 seconds). Strict-concurrency ratchet: exactly 168, passed.
The 18 Kitty tests include the original seven and eleven new regressions.
After restoring all mutations, the final focused suite passed: 56 tests across
KittyImageSizeTests, TerminalImageGuardTests, InlineImageSizeTests,
TerminalFuzzTests, and TerminalStreamIntegrityTests.

Each rule below was removed separately and the relevant real-terminal
regression run. All final mutants compiled and failed assertions; none timed
out. Initial gaps for the empty header ending in a comma and byte preservation
on deletion were filled, and those mutations repeated. Source was restored
after each experiment. Counts are assertion failures, not failing test methods.

| Removed rule | Assertion failures |
| --- | ---: |
| numeric-format | 9 |
| numeric-more | 6 |
| ascii-discard | 5 |
| last-invalid-wins | 6 |
| dispatch-only | 16 |
| more-gate | 18 |
| direct-gate | 1 |
| delete-reset | 2 |
| final-clear | 1 |
| header-without-separator | 3 |
| pending-reuse | 3 |
| persistent-refusal | 4 |

## Upstream report draft: explicit image admission policy

SwiftTerm 1.16.0 (`3917686ea5f5527c5451aaf371bd90bf3618aa71`) owns Kitty
control parsing, pending transfer assembly, base64 decoding, decompression, and
ImageIO admission. Portside currently duplicates protocol semantics in a stream
guard to enforce its tighter image policy.

Request an explicit policy/callback in SwiftTerm to reject transmission modes
and compression before file access/decompression, and check encoded image
headers or raw dimensions before ImageIO/image allocation. Apply the policy to
the original control of the assembled transfer; on rejection return an
appropriate Kitty error and clear pending state deterministically. Limits
should be configurable for the embedding application's trust boundary.

This replaces stream corruption with a direct rejection contract and avoids
parser-version and Foundation-decoder assumptions. The guard fix is a
mitigation, not an upstream implementation. This report is a draft for
follow-up; it has not been submitted upstream.
