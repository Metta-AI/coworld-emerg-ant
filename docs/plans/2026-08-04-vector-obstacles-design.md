# Vector (curved / organic) obstacles — design

Add curved, organic-looking obstacles to CTF maps without making line-of-sight
or navigation any more expensive, and without a new runtime geometry model.

Status: **implemented (GV37).** `shapePolygon` is live for both obstacles and
trenches; mapkit's `caves` style emits organic blob polygons. Sibling to
[map-editor.md](../designs/map-editor.md) and [MAPKIT.md](../MAPKIT.md).

## Problem

CTF obstacles come in exactly four analytic shapes: `rect`, `disc`, `diamond`,
`diagonal` (`ArenaShape`, `sim_types.nim:678`). That vocabulary is rectilinear
and blocky. When mapkit's generators want organic terrain — caves, blobs,
winding ridges — they can only approximate it with clusters of overlapping
discs, which read as "lumps and bars", not landscape (see the caves gallery).
An LLM authoring "interesting" maps is boxed in by the shape set.

We want curves (rounded blobs, winding walls, superellipse boulders) — but CTF
runs in a wasm replay viewer where per-tick cost and cross-platform determinism
both matter, so "just add Béziers to the collision test" is not automatically
safe.

## Key insight: the runtime is already a bitmap

The hot path never touches the analytic shapes:

- `isWall` is `sim.wallMask[mapIndex(x, y)]` — an O(1) bitmap lookup
  (`sim.nim:407`).
- `lineOfSightClear` is a DDA march calling `isWall` per step — O(ray length)
  lookups, no shape math (`sim.nim:497`).
- Fog-of-war is recursive shadowcasting over the coarse 8px `FovGrid`
  (`sim.nim:1856`).

The analytic `inShape` / `mapWallAt` per-shape loop runs **only to bake
`wallMask` once at map load**, plus in the validators and render/tools
(`arena.nim:789`, `:1110`). So **obstacle-shape complexity is decoupled from
per-tick cost.** Any shape we can rasterize into `wallMask` at load is free at
runtime. Curves change the bake, never LoS or navigation.

## Approach: one `shapePolygon` primitive; flatten curves at authoring time

Rather than teach the sim about Béziers, add a single new obstacle kind — a
closed polygon of **integer** vertices — and flatten every curve to a polygon
**before it reaches the sim** (in mapkit / the editor). The on-wire `mapSpec`
then contains only polygons and the existing primitives; the sim evaluates
point-in-polygon, never a curve.

```
of shapePolygon:
  points: seq[MapPoint]   # closed ring, integer coords
```

This is the minimal change because everything downstream already funnels
through four procs, each gaining one branch:

1. **`inShape`** (`arena.nim:789`) — integer even-odd point-in-polygon test,
   done in `int64` (cross products overflow int32 for map-scale coords, exactly
   the reason `shapeDiagonal` already uses int64). Bounding-box early-out first,
   matching the diagonal case.
2. **`mirrorX` / `rot180` / `rot90`** (the symmetry transforms consumed by
   `buildArenaObstacles`, `arena.nim:827`) — transform each vertex with the same
   integer formula the other shapes use. Integer vertex transforms are
   bit-exact, so a polygon and its image rasterize to exact mirror masks; team
   fairness is preserved with no float risk.
3. **`shapeSpecNode` / `shapeFromSpecNode`** (`arena.nim:2275`, `:2300`) —
   serialize / parse the point list.
4. **`isSpinningDiamond`** (`arena.nim` :~913) — a polygon is never a spinning
   diamond → `false`.

`buildArenaObstacles`, the `wallMask` bake, every validator, and `renderMap`
consume those procs unchanged. No new runtime data structure, no change to
`isWall` / `lineOfSightClear` / FOV.

## Determinism & fairness

- **Integer everything.** Vertices are `int`; the even-odd test is integer
  `int64` arithmetic. No float evaluation on the sim path, so wasm and native
  agree bit-for-bit. Curve flattening (which *does* use floats) happens in the
  authoring tool, and its output — the integer vertex ring — is what gets pinned
  and replayed.
- **Exact mirror symmetry.** Because symmetry transforms integer vertices (not a
  re-evaluated curve), the union stays exactly mirror/rot-symmetric — the
  property the codebase guards for the diamond (integer-offset sampling) and
  diagonal (int64) tests. The even-odd predicate uses a STRICT-STRADDLE
  y-convention (`ylo < y < yhi`): counting an edge only when the scan line lies
  strictly between its endpoints is symmetric under the integer reflections the
  map uses (mirror x→w-1-x, rot180 x,y→w-1-x,h-1-y), so a polygon and its image
  rasterize to bit-identical masks. (An earlier doubled-coordinate/odd-sample
  scheme was NOT reflection-exact — sample `2x+1` and vertices `2x` reflect
  about different centers — and is rejected; a unit test asserts mirror parity.)
  Edges that merely touch the scan line at a vertex are skipped identically on
  both sides, so at worst a shape loses a 1px sliver at a y-extremum,
  symmetrically. rot90 (4-team) reuses the same predicate; polygons there are
  fair to the same 1px-symmetric tolerance.
- **Replay stability.** `mapSpec` pins the flattened polygon vertices, so
  playback rebuilds an identical `wallMask`. We pin the *vertices*, never the raw
  mask (a full-board bitmap is megabytes).

## Bake cost

Point-in-polygon is O(vertices) per pixel. A blob flattened to ~40 vertices over
a standard board, with the bounding-box early-out, is comparable to today's
per-shape disc/diagonal cost and runs once per map load. Mitigations if a
colossal board with many high-vertex polygons proves slow: (a) cap vertices per
polygon in the authoring flow; (b) scanline-fill polygons into the mask instead
of per-pixel testing (still integer, still deterministic). Start with per-pixel
`inShape` for uniformity; optimize only if a profile says so.

## Authoring side (mapkit / editor)

The win shows up here. New curve helpers in `mapgen_styles.nim` emit
`shapePolygon`s:

- **Metaball / contour blobs** — sum of radial fields thresholded into a smooth
  closed contour → genuinely cave-like cover (replaces the disc-cluster caves).
- **Superellipse boulders** — rounded-rect-to-ellipse family for scatter.
- **Catmull-Rom / quadratic-Bézier closed loops** — winding organic walls.

Each flattens to an integer ring (fixed segment count) and drops into the seed
half exactly like today's shapes; symmetry, carve, and validators are unchanged.
`renderMap` can fill the polygon with pixie for smooth visuals, or keep the
per-pixel mask look for parity with the board.

## Non-goals

- **Curved *live* geometry** (a spinning/moving curved obstacle). The spinning
  diamond is a special per-frame case; v1 polygons are static.
- **Analytic ray-vs-curve LoS / SDF sphere-marching.** Unnecessary — the runtime
  is bitmap-based — and float-heavy, so a determinism hazard. Explicitly avoided.
- **General SVG import** (arcs, holes, multi-ring paths). One closed ring per
  polygon; composite shapes = multiple polygons.
- **Changing `isWall` / `lineOfSightClear` / the FOV grid.** They stay as-is.

## Alternatives considered

| Approach | Why not |
| --- | --- |
| Rasterize arbitrary vector shapes to a mask at load, then mirror the *bitmap* for symmetry | Works, but a bigger change (a second rasterization path distinct from `inShape`) and it bypasses the existing per-shape validator/render plumbing. The polygon-primitive route reuses everything and mirrors vertices instead of pixels. |
| Analytic curve collision (Bézier distance, SDFs) in `inShape` + ray-vs-curve LoS | Float-heavy on the sim path → wasm determinism risk; and pointless since LoS already marches a bitmap. |
| Keep the four fixed shapes; approximate curves with more discs | The status quo; produces the "lumps and bars" look this design exists to fix. |

## Rollout

1. Add `shapePolygon` to `ArenaShape` + the four proc branches above. Unit-test
   `inShape` and each symmetry transform for a hand polygon, asserting exact
   mirror parity of the rasterized mask.
2. Bump `GameVersion` (wire/format change) and re-record all six fixtures per
   [the fixture rules](../../AGENTS.md) (`gameversion-fixture-regen`).
3. Add curve generators to `mapgen_styles.nim` + a `--style blob` (metaball) and
   wire mapkit to emit polygons; regenerate the gallery to confirm the organic
   look and unchanged validator pass behavior.
4. Editor: optional — a polygon draw/edit affordance (the browser still never
   owns geometry; it posts vertices, the service rasterizes).

## Decisions (were open questions)

1. **Vertex budget** — RESOLVED: soft cap `BlobMaxVerts = 48` in the authoring
   flow (`mapgen_styles.nim`); caves blobs use ~10–14.
2. **Disc-cluster caves** — RESOLVED: the `caves` emit is replaced by organic
   blob polygons; the CA structure (where cover goes) is kept. Because CTF's
   cover budget is low and doubles under symmetry, caves are a handful of
   winding rock masses plus an organic blob-ridge anchor, not a dense system.
3. **Window (glass) polygons** — allowed: the `window` flag is on the shared
   `ArenaShape` and applies to `shapePolygon` like any other kind.

## Remaining / follow-ups

- **Curved trench ART.** Trenches are shapes and polygon trenches collide/query
  correctly, but the organic rough-edge trench art is rect-only; polygon
  trenches currently fill flat. Enhancing this needs no format/GV change.
- **Superellipse boulders / `--style blob`.** The blob generator exists; a
  dedicated scatter-of-superellipses style is a small follow-up.
- **Editor polygon authoring.** The editor round-trips polygon specs but its UI
  still submits rectangles for trenches; a draw-polygon affordance is future.
