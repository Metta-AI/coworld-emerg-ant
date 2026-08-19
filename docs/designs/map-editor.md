# Map Editor Design

A visual editor for CTF / Paintbot maps that reads and writes the existing
`mapSpec` JSON format, with the Nim sim as the single source of truth for all
geometry, derivation, and validation.

Status: **All three phases implemented.** Inspection, editing, and diagnostics
all work; every goal below is met. See Rollout at the end for what each phase
covers.

## Problem

Today a map comes from exactly one place: the seeded procedural generator
(`generateMapAttempt` / `generateCtfMap` in `src/ctf/arena.nim`). You get a map
by naming a seed and a handful of override knobs, then looking at the result.
There is no way to author terrain directly, no way to adjust a generated map,
and no way to see *why* a candidate layout fails validation beyond a one-line
reason string.

That costs us in three places:

- **Curation.** `tools/gen_map_pool.nim` scans seeds upward and keeps the first
  twenty that validate under size/shape quotas. Pool curation is "scan and
  hope", not design.
- **Diagnosis.** When a map plays badly, the only lever is a different seed.
  There is no way to take a nearly-good map and fix the one lane that ruins it.
- **Representation.** Any future search over terrain (evolutionary or
  otherwise) needs a phenotype that is not a seed, because seeds are unstable
  across generator versions — widening the size draw from three classes to five
  re-dealt every seed and forced a pool re-curation (`arena.nim:1328`).
  `mapSpec` is already that stable representation; nothing produces one by hand.

## Goals

1. Load any map — pool entry, generator seed, or saved `mapSpec` — and render it
   accurately, including everything the sim derives rather than stores.
2. Edit the authored geometry: obstacles, trenches, med kits, and the tier-1
   parameters (dimensions, symmetry, layout, endzone, clearances).
3. Run the real play-quality validators live, and show *where* a map fails, not
   just that it failed.
4. Export a `mapSpec` JSON that the server already knows how to consume.
5. Never fork the geometry code. The editor must not be able to disagree with
   the sim about what is a wall.

## Non-goals

- **Placing shields, plasma arcs, or grenades.** These are derived, not stored:
  only Red's point is chosen, and every other team's is its image under the
  map's own symmetry (`shieldSpawnPoints` / `plasmaArcSpawnPoints`, `sim.nim:44`
  and `:74`), specifically so no team's pickup sits in terrain the others' do
  not get. Making them placeable is a sim change, not an editor feature.
- **Editing room labels.** `defaultCtfRooms` re-derives them on load; the spec
  does not even carry them.
- **Replacing the generator or the curated pool.** The editor is a peer to them.
- **Shipping in the game server binary.** This is `tools/` curation tooling,
  like `render_map_pool.nim`.
- **Collaborative or multi-user editing.** Local, single-user, one file.
- **Any use of `async`/`await` in Nim.** See Architecture. This is a backend
  architecture rule and does **not** extend to the browser, where `async`/`await`
  is idiomatic and clearer than promise chains; the UI uses it throughout.

## Constraints

- **Nim owns the geometry.** `inShape`, `mapWallAt`, `isProtectedFloor`, the
  symmetry expansion, and the validators carry subtleties that a reimplementation
  would silently re-break: doubled coordinates so a rot90 board measures against
  its true axis at `(side-1)/2`; `int64` in the diagonal test because the
  intermediate overflows `int32` on wasm; integer-offset sampling in the diamond
  predicate because a half-pixel offset breaks exact mirror symmetry. These are
  team-fairness invariants, and their failure mode is subtle unfairness rather
  than a visible crash.
- **No new production dependencies.** Everything needed is already in
  `nimby.lock`.
- **No async.** Per the project's standing rule. Resolved by mummy, below.
- **Integer pixel geometry.** Every coordinate in the spec is an `int`. The
  editor must expose exact numeric entry, not drag-only manipulation.

## Architecture

**A local Nim HTTP service (mummy) plus a static browser UI.** The browser draws
and captures intent; every geometric question is answered by the Nim service
calling the same procs the game calls.

`mummy` (0.4.7) is already in `nimby.lock` alongside its companions `webby` and
`urlly`. It is a **synchronous, thread-pool** HTTP + WebSocket server — handlers
are ordinary blocking procs — which satisfies the no-async rule with an existing
dependency. No new deps, no new concurrency model.

### Alternatives considered

| Approach | Why not |
| --- | --- |
| Reimplement geometry in JavaScript | Guaranteed drift on fairness-critical predicates. Rejected outright. |
| Compile the geometry module to wasm, pure static page | Better interaction feel and no server process. More build complexity, and the repo's wasm path (`tools/build_replay_viewer.sh`) is currently replay-only. **Revisit if render latency proves bad** — the API contract below is designed so the client does not care which backs it. |
| Native desktop app (`windy` + `pixie`, both already deps) | Zero drift and simplest of all, but worst for sharing a map with a reviewer. The pool-review workflow is already a browser page. |

### Components

- `src/ctf/arena.nim` — gains `mapDiagnostics`; `validateGeneratedMap` becomes a
  thin consumer of it. **No behavior change.**
- `tools/map_render.nim` *(new)* — the map rasterizer, extracted from
  `render_map_pool.nim` so the editor and the pool renderer cannot drift.
- `tools/render_map_pool.nim` — refactored to use the shared rasterizer.
- `tools/map_editor.nim` *(new)* — the mummy service implementing the API below.
- `tools/map_editor/` *(new)* — `index.html`, `editor.js`, `editor.css`. Plain
  files, no build step, matching the existing `client/` convention.
- `tests/test_map_editor.nim` *(new)* — parity and round-trip tests.

## The `mapSpec` format

Unchanged. `mapSpecJson` / `mapFromSpecJson` (`arena.nim:2185`–`2287`) already
round-trip everything authorable; rooms are re-derived on load.

```json
{
  "name": "...", "genSeed": 0,
  "width": 1235, "height": 659,
  "flagRing": 70, "captureClear": 210,
  "spawnClearW": 70, "spawnClearH": 130,
  "gunRange": 1050,
  "symmetry": "mirror|rot180|rot90",
  "layout": "sides|corners|plus",
  "endzone": "column|disc|square",
  "endzoneRadius": 0, "homeDepth": 700,
  "medKitSpawns": [[x, y]], "medKitCandidates": [[x, y]],
  "trenches": [[x, y, w, h]],
  "leftObstacles": [ ... ]
}
```

Obstacles come in exactly four forms, each with an optional `"window": true`
glass flag (blocks movement, bullets, and spray; transparent to fog-of-war):

- `{"kind":"rect","x":_,"y":_,"w":_,"h":_}`
- `{"kind":"disc","cx":_,"cy":_,"r":_}` — L2 ball
- `{"kind":"diamond","cx":_,"cy":_,"r":_}` — L1 ball
- `{"kind":"diagonal","x0":_,"y0":_,"x1":_,"y1":_,"t":_}` — a segment of
  perpendicular thickness `t`. The generator and both hand-authored arenas only
  ever emit 45° segments, but `inShape` implements general point-to-segment
  distance and **the format accepts any angle**. Do not add a 45° constraint;
  the editor may offer 45° snapping as a convenience. A zero-length diagonal is
  degenerate but safe — the predicate is multiplication throughout, with no
  division by the squared length — and collapses to a small filled square.

### Two conventions the editor must hide

- `leftObstacles` is a **seed set** — one half of a sides map, roughly one
  quadrant of a rot90 map — expanded by `buildArenaObstacles`. `trenches` are
  **full-map and already symmetrized**.

  An earlier draft of this document said the editor should place a trench once
  and "write each trench plus its image." **That was wrong and is retracted**:
  computing the image means reproducing `mirrorX` / `rot180` in JavaScript,
  which contradicts this design's central rule that the browser never owns
  geometry. Until a Nim-side canonicalization exists, **Phase 1 treats trenches
  and med-kit points as read-only** — rendered, labeled, and exported verbatim,
  but not editable. Authoring them is Phase 2 work and is blocked on a service
  operation that expands a seed placement into its symmetry images. Note also
  that `finalizeTrenches` never places trenches on rot90 maps at all.

- **`seedRegion` is advisory, not a fence.** It marks where new shapes are
  placed by default and where authoring is conventional. It must **not** hard-block
  edits outside itself, because the generator itself authors past the band: the
  rot90 slot band runs to `cy + 60`, sixty pixels beyond the horizontal
  midline (`arena.nim:1484`). An editor that refused to move such a shape could
  not edit generator output.
- **The protected-floor carve is invisible but load-bearing.** Any shape is
  subtracted wherever it overlaps the flag ring, spawn pockets, or capture
  approaches. The editor must render the *carved* result, never the authored
  rectangle, or users will draw shapes that do not appear.

## API contract

Frozen here so the UI and the service can be built independently. All bodies are
JSON. Errors return HTTP 200 with `{"ok": false, "error": "<CtfError message>"}`
— a malformed spec is an expected editing state, not a transport failure.

### `POST /api/map`

The single hot path: one call per (debounced) edit.

```jsonc
// request
{
  "spec": { /* mapSpec object */ },
  "render": {
    "maxDimension": 1600,          // server downscales to fit; 0 = native
    "overlays": ["protected", "pickups", "spin", "seedRegion",
                 "sightlines", "reachability"]
  }
}

// response
{
  "ok": true,
  "png": "<base64>",
  "renderScale": 0.498,            // spec px -> image px, for hit-testing
  "validation": {
    "valid": false,
    "reason": "open horizontal sightline at y=412",
    "coverPermille": 88,
    "minCoverPermille": 74,
    "coverPermilleMin": 40,        // the validator's bounds, so the client can
    "coverPermilleMax": 170,       // show "88 (valid 40-170)" without hardcoding
    "openSightlineRows": [412, 416, 420],
    // the x band the scan covers; a wider rule would overclaim
    "sightlineXRange": {"xLo": 215, "xHi": 1020},
    "unreachableTeams": ["blue"],
    "centerReachable": true,
    // these three are otherwise recoverable only by parsing `reason` prose
    "redHomeOnOpenFloor": true,
    "endzoneFlankChecked": true,
    "rearGateReachesCenterWithoutEndzone": true,
    "endzoneGates": [{"name": "behind", "state": "sealed", "x": 41, "y": 329}]
  },
  "derived": {
    "teamCount": 2,
    "center": {"x": 617, "y": 329},
    "seedRegion": {"x": 0, "y": 0, "w": 617, "h": 659},
    "anchors":   [{"team": "red", "x": 185, "y": 329}],
    // Full CaptureZone fields: a `diag` corner zone or a `disc` compact zone
    // cannot be drawn from the bounding box alone.
    "captureZones": [{"team": "red", "xLo": 0, "xHi": 245,
                      "yLo": 0, "yHi": 658,
                      "diag": false, "cornerX": 0, "cornerY": 0,
                      "diagLimit": 0,
                      "disc": false, "anchorX": 185, "anchorY": 329,
                      "radius": 0}],
    "pickups": {
      "grenade":   [[50, 50]],
      "shield":    [[50, 494]],
      "plasmaArc": [[50, 164]],
      "medKitActive":    [[617, 219]],
      "medKitCandidate": [[617, 219]]
    },
    "spinningDiamonds": [{"cx": 565, "cy": 252, "r": 30}],
    "authoredObstacleCount": 34,   // len(leftObstacles)
    "expandedObstacleCount": 68    // after symmetry expansion
  }
}
```

`overlays` are composited into the returned PNG server-side, so the client stays
dumb about geometry. `derived` carries only what the client needs to draw
interactive handles and labels.

**Coordinate invariant.** Image pixel `(0, 0)` is spec pixel `(0, 0)`; there is
no border or padding, and both axes use exactly `renderScale`. The scale is
`min(1, maxDimension / max(width, height))` with output dimensions
`ceil(dim * scale)`. Clients convert pointer positions by dividing by
`renderScale` and clamping to map bounds.

Pickup coordinates are the map's **nominal** spawn points. At sim start
`placeWalkablePickups` nudges each to the nearest walkable floor, so on a hostile
hand-authored map the play position can differ. Label them as nominal.

**Resource limits** (service-side, not geometry validation): request bodies cap
at 2 MiB (oversized returns HTTP 413, not an `ok:false` lint result); width and
height cap at 6500 and total area at 25,000,000 px, which admits every supported
size class including `colossal` (6422×3427 and 4992×4992) while refusing
accidental multi-gigabyte allocations. `GET /api/pool/{index}` rejects
out-of-range indices rather than inheriting `poolCtfMap`'s wrapping, so UI bugs
surface instead of silently aliasing entry 0.

### `POST /api/generate`

Seed the editor from the generator.

```jsonc
// request
{"seed": 1001, "teams": 2, "overrides": { /* MapGenOverrides fields */ },
 "validated": true}   // true = generateCtfMap (retries), false = one raw attempt
// response
{"ok": true, "spec": { ... }}
```

`overrides` uses the same field names as `MapGenOverrides` (`sim_types.nim:775`).
Omitted fields take their unlocked sentinel (`""`, `0`, or `-1` for
`windows` / `pits` / `pitDensity`).

### `POST /api/symmetry` (Phase 2)

Expands seed-region placements into their full symmetry orbits, so the browser
never reproduces `mirrorX` / `rot180` / `rot90Point`. Called on drop and on
numeric commit, not per mousemove.

```jsonc
// request — the spec supplies width/height/symmetry/layout.
// Both arrays are required; send [] for the one you are not placing.
{"spec": { ... }, "trenches": [[250,110,56,56]], "medKits": [[617,219]]}

// response — one orbit per input, in the same order, original first
{"ok": true,
 "trenches": [[[250,110,56,56], [929,493,56,56]]],
 "medKits":  [[[617,219], [617,439]]]}
```

The fields are named for what they carry rather than for their shape
(`rects`/`points`), because the rot90 rule below is trench *policy*, not
geometry — inferring "this rectangle is a trench" from its shape would leave the
endpoint unable to grow a second rectangular concept. A future third placement
kind adds a field.

Orbits are **deduplicated**, so an orbit holds *up to* two entries under
`mirror` and `rot180` and *up to* four under `rot90`. A placement that is its own
image collapses: a point on the vertical centre line of an odd-width mirror
board, a rect centred on both axes under rot180, the exact centre point or a
centred square under rot90 (one entry), or a centred non-square rect under rot90
(two). Generate the orbit with the canonical integer transforms and dedupe by
whole-value comparison rather than special-casing the parities — that respects
the half-pixel rot90 axis automatically.

The underlying geometry proc stays general; bounds and policy are enforced at the
request boundary, consistent with `validateMapRect`'s existing rule that a rect
must lie wholly inside the map.

**Trenches are refused on rot90 maps.** `finalizeTrenches` never places them
there and `generateMapAttempt` raises `Trenches are not supported on 4-team maps
yet`, so the editor must disable trench authoring on 4-team maps with that
reason rather than silently writing a four-way expansion the generator would
never produce.

**Med-kit authoring semantics.** `medKitCandidates` is the authored set and
`medKitSpawns` is the active subset. The editor authors *candidate orbits* and
toggles which are active; `medKitSpawns` must always be a subset of
`medKitCandidates`. Note `resetMedKits` silently falls back to hardcoded centre
thirds when fewer than two spawns are present, so the editor should warn rather
than let a map ship into that fallback.

### `GET /api/pool` and `GET /api/pool/{index}`

`{"seeds": [1001, ...], "count": 20}` and `{"ok": true, "spec": {...}}`.

### `GET /` and `GET /static/*`

The editor page and its assets.

## Nim-side changes

### `mapDiagnostics`

`validateGeneratedMap` currently computes the cover masks, the sightline scan,
the chamfer distance transform, the flood fill, and the endzone gate checks, then
throws all of it away and returns the first failure as a string. The editor needs
the intermediate results, and duplicating them is exactly the drift risk this
design exists to avoid.

Extract them:

```nim
proc mapDiagnostics*(gameMap: CtfMap): MapDiagnostics
proc mapValidationReason*(diagnostics: MapDiagnostics): string
proc mapSeedRegion*(gameMap: CtfMap): MapRect
```

`validateGeneratedMap` keeps its exact signature and becomes
`mapValidationReason` applied to diagnostics. This is a pure refactor:
**every seed must validate identically before and after.**

Three constraints on the shape of `MapDiagnostics`, learned during planning:

- **Preserve the early exits.** `validateGeneratedMap` currently returns before
  running the distance transform and flood fill when cover or sightlines already
  fail, and `generateCtfMap` calls it up to 100 times per map. Diagnostics must
  be collected in stages with a first-failure mode, or pool curation and map
  generation get materially slower.
- **Masks are opt-in.** Retaining `maxWall`, `minWall`, the eroded corridor mask,
  and the reachability mask is four `seq[bool]` of `w*h` — about 22 MB on a
  `giant` board and 88 MB on `colossal`. Callers wanting only the scalar summary
  must not pay that.
- **Gate results are structured.** `seq[string]` cannot distinguish
  `"endzone gate behind is off the map"` from `"... is sealed"`, and the rear-flank
  route (`"no route around the endzone from behind the base"`) is a separate
  invariant from the four gates. Keep them distinct internally; the service
  flattens for JSON.

`mapSeedRegion` is shared rather than recomputed per consumer: the service
reports it in `derived` and the renderer tints it, and two implementations would
produce exactly the visual/derived disagreement this editor exists to prevent.

### Pure float geometry helpers (prerequisite)

`tools/render_map_pool.nim` works only because `loadCtfMap` **installs** a map
into process-wide globals (`MapWidth`, `ArenaObstacles`, …) which
`obstacleWallAtF` and `isArenaWindowPixel` then read (`render_map_pool.nim:81`,
`arena.nim:2544`–`2611`). That is unusable for a service rendering arbitrary
specs: mummy is multi-threaded, and installing per request would race.

So the extraction requires factoring the float protected-floor and shape-wall
predicates into pure `CtfMap`-parameterized helpers, with the installed-map
versions kept as thin wrappers. **Nothing on the render path may touch installed
globals.** This is a hard prerequisite, not a cleanup.

### Shared rasterizer

`tools/render_map_pool.nim` already draws floor / stone / glass with protected
zones tinted, pedestals dotted, med-kit points marked, and trenches shaded. Move
that into `tools/map_render.nim` with an options record for scale and overlay
selection, and have both the pool renderer and the editor call it.

## Validation and testing

- **Refactor parity (required).** `validateGeneratedMap` must return byte-identical
  strings before and after the `mapDiagnostics` extraction across a seed sweep of
  1000–2000 for both `teams: 2` and `teams: 4`, captured as a checked-in fixture.
  Compare strings directly, not hashes, so wording, numbers, and **failure
  precedence** are all pinned. This is the test that makes the refactor safe.

  Coverage note: 4-team generation forces `ezColumn` and *raises* on compact
  endzones (`arena.nim:1385`, `:1406`), so an earlier draft of this document
  asking for all three endzone shapes at `teams: 4` described something
  impossible. Assert all three shapes across the 2-team half of the sweep and
  both layouts (`corners`, `plus`) across the 4-team half.
- **Spec round-trip.** For every pool map: `mapSpecJson` → `mapFromSpecJson` →
  `mapSpecJson` is identical, and the rebuilt `CtfMap` compares equal.
- **Render parity.** The shared rasterizer must reproduce `render_map_pool.nim`'s
  current output for all twenty pool maps.
- **API smoke.** Each endpoint returns well-formed JSON for a valid spec, and
  `{"ok": false, ...}` with a useful message for a malformed one.
- **Manual.** The editor's render of each pool map matches `docs/pool-review.html`.

## Risks

| Risk | Mitigation |
| --- | --- |
| ~~Render latency on oversize boards makes editing feel bad~~ **CLOSED — measured** | Measured against a release build, one full `POST /api/map` round trip including PNG encode and base64: standard (1235×659) 49 ms, large 79 ms, huge 126 ms, giant (3211×1713) **226 ms** preview / 349 ms native. Comfortable with the existing debounce. The wasm alternative was written in as the escape hatch and is **not needed** — the shared rasterizer paints per-shape bounding boxes instead of scanning every shape per pixel, which is the same change that took a full pool render from ~35 s to ~3 s. Re-measure if the rasterizer stops being bbox-painted. |
| An invalid hand-authored map reaches the league | `mapFromSpecJson` deliberately runs only `validateMap` (bounds/compat), **not** the play-quality validators — replays must load maps recorded under older rules, so this stays. The editor warns loudly on export instead, and export of an invalid map requires explicit confirmation. |
| The `mapDiagnostics` refactor changes generation | Parity sweep above; it is the gating test for the whole project. |
| Scope creep toward a general level editor | Phases below are shippable independently; stop after any of them. |

## Rollout

- **Phase 1 — Inspector (read-only). DONE.** Shared rasterizer
  (`tools/map_render.nim`), `mapDiagnostics`, the service
  (`tools/map_editor.nim`), and a UI (`tools/map_editor/`) that loads
  pool/seed/spec and renders with overlays and the lint panel. Trenches and
  med kits render read-only.
- **Phase 2 — Editing. DONE.** Shape create/select/move/resize/delete with numeric
  inspection, the tier-1 parameter panel with live re-derivation, trench and
  med-kit placement, load/save spec JSON.

  Was blocked on one Nim addition, now landed. Authoring a trench or med kit means placing
  it once in the seed region and deriving its symmetry image(s), and that
  expansion must happen in Nim — doing it in JavaScript would reproduce
  `mirrorX` / `rot180` in the browser and break this design's central rule. The
  needed operation is the general form of what `finalizeTrenches` and
  `teamImagePoint` already do:

  ```nim
  proc symmetryImages*(gameMap: CtfMap, rect: MapRect): seq[MapRect]
  proc symmetryImages*(gameMap: CtfMap, point: MapPoint): seq[MapPoint]
  ```

  Each returns the full orbit including the original, deduplicated — see the
  `POST /api/symmetry` section above for the exact orbit sizes and the rot90
  trench policy.

  Undo/redo belongs here, not in Phase 3: editing is unusable without it, and
  Phase 1 deliberately shaped the store around transaction boundaries so it
  could land with the editing work rather than after it.

  Two Phase 1 gaps this phase must also close, both found during Phase 2 plan
  review:

  - There is **no authored-obstacle list**. Phase 1 planned one and shipped only
    marker listings. It is the canonical selection route for a shape that
    protected-floor carving has made partly or wholly invisible, so editing
    needs it.
  - The viewport **refits on every document revision** (`updateFromState` calls
    `fit()` when `renderedDocumentRevision` changes). Correct when a revision
    change means a new map; fatal once every edit bumps the revision. Split load
    identity from edit revision so only loads refit.

- **Phase 3 — Diagnostics and polish. DONE.** The remaining half of goal 3: the
  validators already say *that* a map fails, and the server already composites
  `sightlines` / `reachability` overlays, but a failure is still a sentence in a
  panel rather than a place on the board.

  - **Anchor each failure to the board.** `open horizontal sightline at y=412`
    should be selectable and draw a rule at y=412, bounded to
    `validation.sightlineXRange` — a full-width rule would claim the validator
    checked ground it never looked at. An unreachable team is located by its
    `derived.anchors` entry; the browser must **not** shade the unreachable
    region, because the reachability mask is deliberately retained server-side
    and the composited `reachability` overlay stays the full picture. Drawing a
    rule at a server-supplied `y` is annotation, not geometry, so this stays
    inside the architecture rule; deriving *which* rows are open would not.
  - **Editing ergonomics.** Arrow-key nudge (1 px, 10 px with Shift) and optional
    grid snapping, for authoring at exact integer coordinates.
  - **A legend** for the diagnostic overlays, which currently rely on the reader
    knowing what each tint means.

## Open questions

1. Does an edited map get a path into the curated pool, or does it stay an
   artifact humans review and paste into a config? Deferred: export the spec,
   decide later.
2. Should the generator gain tier-2 overrides (per-column family / period /
   phase) so generated and authored maps meet in the middle? Not needed for the
   editor — `mapSpec` already spans the full space — but it is the natural next
   step if search over terrain becomes a goal.
