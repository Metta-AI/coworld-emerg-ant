# Compact endzones: deep bases, disc/square zones, wilderness all around (2026-07-30)

Confirmed with daveey. Adds a second terrain archetype to the generator: the
base sits well off the home edge, the endzone is a **disc or square around the
base** instead of a full-height border column, and the freed border strip
becomes playable wilderness that wraps all the way behind the base.

## Decisions (locked)

1. **Full mechanic, not paint.** The capture zone, protected floor, respawn
   draw, endzone glow, pickups and the validators all follow the shape. A
   carrier scores by getting *inside* the zone from any direction.
2. **Drawn per seed + lockable.** Every generated 2-team map draws an endzone
   shape (50% classic column, 25% disc, 25% square). `mapEndzone`,
   `mapEndzoneRadius` and `mapBaseDepth` lock the draws, like `mapWindows` /
   `mapPits`. (In the event the existing 20 pool seeds all still validated
   first-attempt and came out 8 column / 5 disc / 7 square, so `map_pool.nim`
   was left alone; `gen_map_pool.nim` gained a shape quota for the next
   re-curation.)
3. **Open flank.** Terrain wraps the whole zone and a validator requires a
   passable route *behind* the base that does not cross the endzone, plus four
   open cardinal gates into the ring.
4. **No GameVersion bump.** The hand-authored arenas keep `ezColumn` and
   identical geometry; every column-shaped generated map stays bit-identical
   (proof below). Only new shapes are new behavior.
5. **2-team (`layoutSides`) only in this pass.** 4-team corner/plus layouts
   already own their own endzone geometry; a compact endzone requested on them
   raises a config error rather than half-working.

## Model

`CtfMap` gains three fields, all defaulting to today's behavior:

| field | meaning | classic |
|---|---|---|
| `endzone: EndzoneShape` | `ezColumn` / `ezDisc` / `ezSquare` | `ezColumn` |
| `endzoneRadius: int` | scoring radius (disc) or half-extent (square) around the anchor; 0 on columns | `0` |
| `homeDepth: int` | permille of the half-field the anchor sits back from center; **larger = closer to the edge** | `700` |

`axisHomeLo/Hi` take `homeDepth` (`center - center*depth/1000`); at 700 the
integer arithmetic is identical to the current `*7 div 10`, so no anchor moves.

`captureZone()` returns the anchor-centered box for both compact shapes, plus
`disc`/`radius` for the round one — squares need no new predicate because the
box *is* the square. Protected floor (never walled) is the same shape inflated
by 6px, mirroring today's 210-vs-206 column/threshold gap.

### Draw

A **side RNG** (`seed xor const`) draws shape, depth and radius, so the main
draw stream is untouched and every column map generates exactly as before.

- shape: column 1/2, disc 1/4, square 1/4
- `homeDepth` 520..620 → the base sits ~50-110px further from the edge
- `endzoneRadius` 110..140 px, scaled by the size class

Compact maps also move the obstacle span from `captureClear + 50` to
`ArenaBorder + 34` (the wilderness) and draw 6..8 columns instead of 4..6 to
hold the field density over the wider span. Both are re-parameterizations of
existing draws — they consume the same RNG.

An **apron** of `radius + 60` keeps drawn obstacles (and sightline-repair
plugs) off the ring, so the base always has room to be approached; without
it the open-flank validator rejected roughly 70% of compact draws.

### Validators (compact only)

- cover budget measured over the whole non-protected interior (the 4-team
  definition) instead of the historical x-band
- horizontal sightlines scanned border-to-border, not column-to-column
- **NEW** four cardinal gates 17px outside the ring must be open floor in the
  main connected component
- **NEW** backfield bypass: a flood fill from behind the base, forbidden to
  enter the endzone, must reach the map center

Red-side checks only; mirror/rot180 hands Blue the exact image.

### Runtime

Capture (`inCaptureZone`), respawn (`randomEndzonePosition`) and the endzone
fade strip are already capture-zone-driven and inherit the shape for free. New
work: one `disc` branch in `endzoneColorAt` (line at the ring, ember easing
inward — same language as the diagonal corner zones), a compact branch in
`shieldSpawnPoints` / `plasmaArcSpawnPoints` (inside the zone, above and below
the pedestal, guaranteed walkable), and the three new fields in `mapSpecJson` /
`mapFromSpecJson` so replays pin the geometry.

## Proof obligations — results

- **29/29 column maps byte-identical.** Seeds 1001-1060 hashed via
  `tools/dump_map_specs.nim` before and after (endzone keys stripped): every
  seed that draws `ezColumn` hashes the same and still validates.
- **`arena` / `arena-large` unchanged**: `ezColumn`, `teamHomeX(Red) == 186`,
  `teamHomeX(Blue) == 1049` — pinned by test.
- **Compact draws land 29/31 first-attempt** over that seed range (the two
  rejects are field-side gates blocked by a column; the generator re-rolls).
  An apron of `radius + 60` keeps terrain off the ring — without it the
  open-flank invariant rejected ~70% of draws.
- **Pool**: the existing 20 curated seeds all still validate first-attempt
  and now serve 8 column / 5 disc / 7 square, so `map_pool.nim` did not need
  re-curating. `gen_map_pool.nim` carries a 10/5/5 shape quota for the next
  re-curation.
- **Tests**: `tests/test_endzone_shapes.nim` — arenas untouched, both shapes
  deterministic and valid, base further from the edge, ring scores from
  every side (and the border strip does not), no wall inside the zone while
  real cover exists behind the base, flanks open on every compact pool seed,
  a sealed backfield is rejected, disc respawn draws stay inside the ring,
  stepped episode determinism, spec round-trip (including a legacy spec with
  the keys absent), and six bad configs that must fail loudly.
- Full suite green (321 checks, release + debug compile); `vet` clean.
- Art verified by baking the board: `tools/dump_endzone_bake.nim gen:1005`.
