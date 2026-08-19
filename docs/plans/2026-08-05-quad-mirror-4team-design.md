# Quad-mirror symmetry: rectangular 4-team maps (GV39)

## Goal

4-team (corners/plus) maps are rot90-only today, and rot90 requires a square
board — so a 4-team map cannot be the classic 1235×659 rectangle. This change
adds `symQuadMirror`: the generator authors ONE quadrant (top-left) and the sim
completes it by reflecting across both center axes, giving 4 congruent
quadrants on a RECTANGULAR field. Motivated by the paintbot campaign wanting
all 100 tiles on same-shape rectangular medium maps, including its 4ffa cells.

## The symmetry

Seed quadrant: top-left. Images: `mirrorX` (x → w-1-x), `mirrorY` (y → h-1-y,
new helper mirroring `mirrorX` exactly with x↔y, w↔h), and `rot180`
(= mirrorX∘mirrorY). D2/Klein-four group — reflections preserve congruence
exactly, like the 2-team `sides` mirror. Teams land in the four corners
(corners layout) or arm mouths (plus layout) as mirror images of Red's
placement; allied pairs [[0,2],[1,3]] sit diagonal. Unlike rot90, the group is
axis-preserving: spawn pockets never transpose W↔H, and a rectangle is legal.

## Team → image mapping

Red = identity (top-left / west), Blue = mirrorX (top-right / east),
Green = mirrorY (bottom-left / south on plus: mirrorY of west arm is... see
below), Yellow = rot180 (bottom-right). For `layoutPlus` on a rectangle the
four arm mouths are W (Red, identity), E (Blue, mirrorX), N (Green, mirrorY of
S... ) — concretely the anchor table is authored explicitly per layout instead
of walking an orbit: `teamAnchor` computes Red's anchor then applies the
team's image transform via `teamImagePoint`.

## Exact-fairness rules (from the impact map)

- **Doubled coordinates**: the reflection axes sit at (w-1)/2, (h-1)/2 —
  centerOffset2/arenaCenterOffset2 must use the rot90-style doubled form
  `(2x-(w-1), 2y-(h-1))` for quad-mirror, never the integer-center form.
- **STRICT-STRADDLE pointInPolygon** already commutes with integer x- and
  y-reflections; no new boundary convention.
- **Spinning diamonds**: the spin set must be closed under the group → use the
  cross closure (near either axis), same as rot90. Spin DIRECTION flips once
  per reflection: dir = sign(2cx-(w-1)) * sign(2cy-(h-1)) — mirror-image
  neighbors counter-rotate, the rot180 image co-rotates. (Highest-risk silent
  unfairness site; dedicated test.)
- **Trenches**: stay refused on quad-mirror for now (like rot90) — the guards
  flip from `symmetry == symRot90` to `teamCount == 4` semantics deliberately;
  enabling 4-team trenches is a separate change.

## Touch list

1. `sim_types.nim`: append `symQuadMirror` AFTER `symRot90` (flatty ordinal
   stability), GV38→GV39 changelog entry.
2. `arena.nim`: `mirrorY` helpers (rect/shape); `buildArenaObstacles` arm;
   `symmetryImages` (rect+point) arms; `teamImagePoint`; `teamAnchor` (no
   orbit walk); `spawnPocketHalf` (axis-preserving); `validateMap` (allow
   corners/plus + quadMirror on rectangles); `centerOffset2`/
   `arenaCenterOffset2`; `isSpinningDiamond` cross closure;
   `diamondSpinFrame` per-axis direction; sightline repair fold (mirrorY row
   fold + add a vertical-column scan for quad-mirror); `generateMapAttempt`
   4-team branch (accept `mapSymmetry: "quadmirror"`, rectangular shell);
   `mapSpecJson`/`mapFromSpecJson` "quadmirror" string.
3. `sim_state.nim`: spawnAimBrads/spawnFlipH — verify corners/plus aims for
   mirrored (not rotated) quadrants.
4. Tools: `map_render.nim` seed region (top-left quadrant), `mapkit.nim`
   (--symmetry quadmirror implies teams 4-capable), map_editor orbit endpoint.
5. Tests: obstacle-orbit congruence, per-team anchor/endzone mirror-exactness,
   protected-floor pixel equality across quadrants, diamond spin direction,
   mapSpec round-trip, validator pass on a generated rectangular 4-team map,
   four_team suite on quad-mirror.
6. GameVersion bump GV39 → re-record all six fixtures (see
   [[gameversion-fixture-regen]] memory / AGENTS.md).

## Default behavior

The 4-team seed draw keeps rot90/square as the default; `mapSymmetry:
"quadmirror"` (config/mapkit) opts a map in. Existing replays and pool maps
are untouched; new terrain only. (The GV bump is for the new wire enum value
+ fixture re-record hygiene, not a behavior change to old seeds.)
