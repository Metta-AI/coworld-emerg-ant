# Paint Puddles — hazard blobs with a 10%/sec damage roll

Confirmed design (2026-08-07). Static mapgen-placed paint puddles: standing in
one gives a 10% chance per full second of occupancy to take 1 damage.
Config-gated, off by default — no GameVersion bump, no fixture regen.

## Decisions (confirmed with daveey)

- **Origin: static map features.** Mapgen scatters puddles like it does
  trenches — fixed hazard blobs, symmetric per team, pinned into replays.
  NOT formed by weapon paint (stains stay cosmetic).
- **Off by default.** A `mapPuddles` count knob (like `mapPits` COUNT mode);
  the default path is byte-identical, so no GV bump and all six fixtures
  pass unchanged (the handicaps/paint-flood pattern).

## Mechanic

- Every full **second (TargetFps = 24 ticks) of continuous occupancy** — the
  player's center inside any puddle (`puddleIndexAt`, mirroring
  `trenchIndexAt`) — rolls `rng.pick(100) < puddleDamagePct` (default 10).
- A hit deals **1 damage** through `absorbDamage` (shield soaks first), emits
  a tier-2 `Damage` event with `weapon = "puddle"`, and adds a floating "-1"
  pop. Death goes through `killPlayer(i, -1, cause = "dissolved in a paint
  puddle")` — the environmental-death `cause` parameter from the paint-flood
  design (commit 1937627, re-introduced here since that branch is unmerged).
- The per-player `puddleTicks` counter resets on exit, death, and respawn.
  Continuous means continuous: dipping out and back restarts the second.
- Puddles do NOT slow movement, block shots, or affect vision — pure
  damage-over-time floor hazard, visually loud, mechanically simple.

## Placement (mapgen)

- `CtfMap.puddles: seq[ArenaShape]`; `ArenaPuddles` global installed by
  `selectCtfMap`, like `ArenaTrenches`.
- `MapGenOverrides.puddles` (config key `mapPuddles`): -1 default = none,
  0..64 requested count. COUNT mode only (no density mode — YAGNI).
- A `PuddleSize` (64px) square blob. Placement samples random left-half
  centers from the map rng with bounded retries; accept when the dig AND its
  symmetry image sit on open floor (`rectOnOpenFloor`), clear of trenches,
  other puddles, and each team's spawn pocket / flag ring. Odd count anchors
  one puddle at the exact map center (its own image), like the odd center
  pit. Runs AFTER trench finalize so overlap checks see the final trench set.
- 2-team maps only: `symRot90`/`symQuadMirror` with `mapPuddles > 0` raises,
  same as trenches.
- **Spec pinning:** `mapSpecJson` gains a `"puddles"` array (shape nodes,
  both halves, already symmetrized); `mapFromSpecJson` reads it back with
  absent-key = none, so every pre-puddle pinned spec and replay loads
  verbatim.

## Determinism / no-GV-bump gating

- RNG for the damage roll draws ONLY while someone stands in a puddle; zero
  puddles = zero extra draws = byte-identical sim.
- `puddleTicks` is NOT mixed into gameHash (mixing a new always-0 field would
  change every existing replay's hash chain). Determinism is still covered:
  hp/lives/position are hashed, and keyframe scrub restores `puddleTicks`
  exactly via the flatty `simBytes` snapshot (runtime-only, not a stored
  format).
- Config echo emits `mapPuddles`/`puddleDamagePct` only when the mode is on
  (flood-pattern echo gating), keeping the default `configJson` byte-stable.

## Visibility

- **Board art:** each puddle renders as an irregular magenta/violet paint
  blob (team-neutral — not any team's paint) baked into the map layer, edge
  noise in the trench-art style so it reads organic, not a debug rect.
- **Stated markers:** one invisible 1x1 init-snapshot marker per puddle,
  `puddle <x0>,<y0> <x1>,<y1>` (inclusive bbox corners), exactly the
  trench-marker pattern (own reserved object/sprite pool, width 64).
- **RULES.md:** a Puddles section (mechanics + marker contract).

## Tests

- `tests/test_puddles.nim`: deterministic recipe (`mapSeed` + `mapPuddles`);
  asserts placement count/symmetry/pinning round-trip, occupancy counter
  reset behavior, damage roll determinism (fixed seed), shield-first
  absorption, death via cause, and gameHash run-to-run stability.
- Existing fixtures re-verified unchanged (knob off) via the full
  `tests.nim` single binary.
