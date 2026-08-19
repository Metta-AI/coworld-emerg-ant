# Heart grab radius (GV42) — case file, shipped 2026-08-10

**Status: done and merged.** PR #264 → `b368559` on `main`. GameVersion 42 is
live; `FlagPickupRange` is 34. Nothing in flight.

This is a case file rather than a design doc: the design was one constant. It
exists because the same bug already came back **twice**, and each time the
reasoning was lost — so the durable value is *why* the number is what it is,
and what enforces it.

## What shipped

`FlagPickupRange` 12 → 34 (`src/ctf/sim_types.nim`). Standing on the pedestal
takes the heart; there is no pinpoint to find.

The radius is **derived from the art**: 30px is the gem's width half-extent
(`PlantedFlagW div 2`), +4 partly covers the body half-extent (`PlayerHalf`
6) so a footprint overlapping the art counts as a touch. It is keyed to WIDTH
not height, because #261 stands the gem erect ABOVE the grab point — the art
is not vertically symmetric about it, and what a player's feet are on is the
96px pedestal disc.

Sim rule change → GameVersion bump → all six replay fixtures re-recorded.

## Why it took three tries (the part worth inheriting)

- #259 — object center sat 28px off the grab point. Unpickable at any
  precision. Fixed render-side by sinking the gem into the disc.
- #261 — restored the erect stance by padding the canvas, keeping #259's
  center contract. Also render-side.
- #264 — the radius was STILL 12px against a 60px gem on a 96px disc, a fifth
  of the art. Present the whole time; survived both fixes because the sim
  number was never questioned.

The general rule is now written up in `AGENTS.md` →
"Interaction radii must be derived from the art".

## Landmines for whoever touches this next

- **The enforcement is a test, not a type.** `sim_types.nim` cannot import
  `global.nim` (dependency runs one way), so `PlantedFlagW` is exported
  purely so `test_ctf_game.nim` can assert `FlagPickupRange >= PlantedFlagW
  div 2`. Delete that test and the bug can silently return a fourth time.
- **Two fixture traps cost real time here**, both now documented in
  `AGENTS.md` → "Replay fixtures": a recipe inherits `config.json` and can go
  stale with NO rule change (the `draw-nokill` recipe was producing a
  *winner*, 109530 ticks against a 1500-tick limit, because the barrage
  landed in the config after GV41 was cut); and a seed does NOT pin the kill
  mix, because bots are separate processes.
- **Local test recipe:** no Nim toolchain on the cubi. Build the image
  (`docker build -t ctf-build --target build .`), `docker cp` the tree in
  (bind mounts fail under podman here), then `nim c -d:release
  tests/shard_N.nim` for N in 1..4 from the repo root. 568 tests at the time
  of this change.
- **Recording fixtures needs `./bin/ctf-server` + `players/baseline/baseline.out`
  built first**, plus `nc` and `python3` in the container. Record ONE AT A
  TIME on an idle machine — the recipes' own warning is real.

## Open follow-up

Issue #266 — the other five pickups (grenade, med kit, shield, spray can,
barrier) carry the same art-vs-radius mismatch at ~2x rather than the heart's
5x. Deliberately out of GV42's scope; measurements and a suggested approach
are in the issue. Not known to be hurting anyone.
