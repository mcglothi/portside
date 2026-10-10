# Changing what Portside stores

Gate 5 of the [road to 1.0](road-to-1.0.md) is "upgrade and downgrade are
both survivable", and the work left on it is keeping that true. This is the
pattern every change to a persisted file follows. It's written down because
the bugs it prevents have already happened once: the 0.16 audit's data-loss
P0 was one undecodable record sinking a whole library, and 0.20 fixed a
downgrade that silently dropped groups.

What's persisted: the library (`portside.json`), the local sidecar
(`portside.local.json`: workspace, appearance, terminal, logging, recents),
agent settings (`portside.agent.json`), and anything a shared inventory
carries (`portside.json` in the team repo, read by *other people's* builds).

## 1. Add, don't change

A new field is optional to decode and has a default that reproduces what the
previous release did without it.
- Decode it with `decodeIfPresent` in the type's hand-written decoder. A
  missing key must never throw.
- Choose the default for meaning, not convenience. Every 0.34 inventory
  source was on, so `InventorySource.isEnabled` defaults to `true`. A 0.34
  agent approval for editing was never asked about typing, so `canType`
  defaults from the tier it was granted, not to `true`.
- What keeps one bad record from failing the whole file differs by
  collection, and both rules have to hold:
  - **Hosts, macros, port forwards and credential profiles** are plain
    arrays. Any element that throws fails the whole library, which then goes
    to quarantine. Their decoders are tolerant field by field instead, so a
    field added to one of these types must never be required. Only identity
    (`name`, `id`) may be.
  - **Groups, inventory sources, shared overlays and publish links** are
    `LenientArray`s, so a record that can't be decoded is dropped on its own.
    Use this for a new collection whose records can be invalid on their own
    (a group without a layout isn't a group). Keep in mind that a dropped
    record is gone after the next save.

Renaming or retyping a field is a new field plus a read of the old one. Never
reuse a key with a new meaning: an older build will read it with the old one.

## 2. Prove the old file still means the same thing

Each release that adds fields gets an `UpgradeFrom<previous>Tests`
(`UpgradeFrom034Tests` is the model). Write the JSON exactly as the previous
release wrote it, as a literal in the test, decode it with the new build, and
assert that it behaves as it did then. A literal is the point: a fixture
produced by encoding with the new types would already contain the new
fields.

## 3. Rehearse against a real library

Synthetic fixtures are written by the person who wrote the migration and
share their blind spots. Before release, run the rehearsal against a copy of
a real library:

    PORTSIDE_UPGRADE_FIXTURE=/path/to/portside.json swift test --filter UpgradeRehearsal

It copies the file first and checks that nothing is lost on load and save:
hosts, macros, credential profiles, themes, port forwards, recents, the saved
workspace and the settings that moved to the sidecar. If `portside.local.json`
and `portside.history.json` sit beside the fixture, they're copied too and
count toward what has to survive. Point it at a copy of a real Application
Support folder, not just the library. The originals are never opened for
writing.

## 4. Keep a restore point for anything one-way

A migration that moves or strips data (not one that only adds a field) copies
the file aside first, as the local split does (`portside.pre-local-split.json`):
- **Once, never overwritten.** If a first attempt migrated and something went
  wrong later, the copy worth keeping is from before the first attempt.
- **New place first, old place second.** Write the destination (the sidecar),
  then strip the source, and only once the write has succeeded. A failure
  between the two leaves the data in both places and the migration reruns.
  If the destination can't be written at all, the source keeps carrying the
  data on every save until a write succeeds (`localSplitPending`). It is
  never in neither.

## 5. Know what a downgrade does

An older build ignores keys it doesn't know when it **reads**, so it opens a
newer library fine. But when it **saves**, it writes only the keys it knows,
and the newer fields are gone. When the newer build reads the file again,
each field comes back as its **default**, not as whatever the user had set.
- That's harmless only for a field whose non-default values don't matter to
  the user: a cache, or something learned and relearned automatically.
- For anything the user set, it's a silent reset. For example, a shared
  inventory switched **off** comes back **on** after a round trip through
  0.34. A restore point can't help either, because it only holds what
  existed before the upgrade.

So user-controlled settings in a new field either live where an older
build won't rewrite them (their own file, as saved filters do) or are
listed in the changelog as reset by a downgrade.

Shared inventories make this sharper, because the team's file is read and
written by whatever build each member runs. An older build reads a newer
team file fine and ignores the fields it doesn't know. If it **publishes**,
it writes the file from what it knows, so those fields are gone for
everyone. Its publish review can't warn about this, since it compares only
the fields it knows. Until publishing preserves fields it doesn't
recognise, members of a team should publish from the same release or a
newer one. A field added to shared entries should say in the changelog that
older publishers drop it.

## Checklist for a PR that touches a persisted type

- [ ] New fields decode with `decodeIfPresent` and a meaning-preserving default
- [ ] No new field is required on a host, macro, forward or profile
- [ ] A new collection of independent records is a `LenientArray`
- [ ] No key reused with a new meaning
- [ ] `UpgradeFrom<previous>Tests` has a literal from the last release
- [ ] One-way migrations keep a once-only restore point and write the new place first
- [ ] The changelog says what a downgrade loses, if anything, and whether older publishers drop it
- [ ] Rehearsed with `PORTSIDE_UPGRADE_FIXTURE` before the release
