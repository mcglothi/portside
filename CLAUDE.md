<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **portside** (4013 symbols, 15757 relationships, 300 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> If any GitNexus tool warns the index is stale, run `npx gitnexus analyze` in terminal first.

## Always Do

- **Run impact analysis before changing a persisted model or a widely-used
  type** — `gitnexus_impact({target: "symbolName", direction: "upstream"})` —
  and report the blast radius. See "When GitNexus earns its keep here" below for
  where this is worth doing; it is not every edit.
- **Warn the user** if impact analysis returns HIGH or CRITICAL risk before
  proceeding.
- `gitnexus_detect_changes()` before committing is useful on large or
  cross-cutting changes. It is not required for a one-file fix.
- When exploring unfamiliar code, use `gitnexus_query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `gitnexus_context({name: "symbolName"})`.

## Never Do

- NEVER edit a function, class, or method without first running `gitnexus_impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `gitnexus_rename` which understands the call graph.
- NEVER commit changes without running `gitnexus_detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/portside/context` | Codebase overview, check index freshness |
| `gitnexus://repo/portside/clusters` | All functional areas |
| `gitnexus://repo/portside/processes` | All execution flows |
| `gitnexus://repo/portside/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->

<!-- portside:start -->
## When GitNexus earns its keep here — and when it doesn't

The block above is GitNexus's own default guidance. Running impact analysis
before *every* edit is heavier than this codebase justifies; the list below is
calibrated to where it has actually paid off in Portside.

**Reach for it when:**

- **Adding a field to a persisted model.** `Macro` reports CRITICAL / 93
  impacted, which is the right prompt: `SessionStore.Document` decodes several
  of these non-optionally, so a new field can fail a whole library load rather
  than just itself. This is the shape of the 0.16 audit's data-loss P0 and of
  the 0.17 `Macro.isFavorite` near-miss.
- **Reusing a type or view name.** `EmptyStateView` was already taken by the
  welcome screen; a symbol lookup answers that in one call instead of via a
  compiler error.
- **Tracing a path through the terminal stack.** `LoggingTerminalView` →
  `SixelStreamGuard` → `super.dataReceived`, or the OSC 133 tap → `CommandTimeline`
  → transcript offsets. Several behaviours are ordering contracts rather than
  call graphs, so confirm against the code before trusting a flow.

**Don't bother when the answer isn't in our symbols:**

- **Dependency behaviour.** The 0.17 Sixel crash lived in SwiftTerm's
  `SixelDcsHandler`; it was found by reading the checkout and running probes.
- **Shell or protocol semantics.** The SFTP breakage was `bash` sourcing
  `~/.bashrc` non-interactively; the MobaXterm escapes were French key-label
  names. No graph of our code contains either.
- **Anything visual.** Appearance, empty states, window sizing, the MultiExec
  bar — all confirmed by building the app and looking at it.
- **Reading data.** The 22-of-32 mangled macros came from parsing a real
  `portside.json`, not from the index.

**The index is per-machine and goes stale.** It is gitignored, tracks the
working tree, and needs `gitnexus analyze` after significant edits. Note also
that `tree-sitter-swift` was missing from the Homebrew install and had to be
added by hand — if an index ever reports a few hundred nodes instead of a few
thousand, the Swift parser has gone missing again and the index is only seeing
docs and scripts.
<!-- portside:end -->
