# mapkit — LLM-authored, interesting-but-fair CTF maps

`tools/mapkit.nim` is a CLI for generating and hand-editing CTF maps in the
native `mapSpec` format. It is a peer to the [map editor](designs/map-editor.md)
service: it never reimplements geometry, it drives the same sim procs
(`generateMapAttempt`, `mapSpecJson`/`mapFromSpecJson`, `validateGeneratedMap`,
`mapDiagnostics`, `buildArenaObstacles`) plus the shared `map_render`
rasterizer. **Fairness is entirely the sim's job** — generators emit a
one-half/quadrant seed set, the sim mirrors it, carves protected floor, and the
validators gate the result. Generators never reason about fairness.

Terrain styles live in `src/ctf/mapgen_styles.nim`; each is a pure
`(rng, region, params) -> seq[ArenaShape]` that fills the placement band with
CTF's native shapes (rect / disc / diamond). No sim change, no replay risk.

## Build

```bash
nim c -d:release -o:/tmp/mapkit tools/mapkit.nim
```

## The loop

```bash
mapkit generate --style caves --seed 7 -o m.json   # generate a candidate
mapkit render   m.json -o m.png                     # then LOOK at the PNG
mapkit validate m.json                              # fair + connected? (exit code)
mapkit metrics  m.json                              # cover / sightlines / reachability
$EDITOR m.json                                      # nudge leftObstacles by hand
# ...repeat until it looks good AND validates.
```

`generate` picks a seed that draws size/endzone/clearances, then replaces the
obstacle set with the chosen style's output. Because raw generation passes the
validator ~55–65% of the time, the intended workflow is **generate several
seeds, keep the ones that pass, then hand-edit** — `leftObstacles` in the JSON
is a plain array of shapes, and symmetry keeps every edit fair.

## Styles

| Style | Terrain | Key `--param` knobs |
|---|---|---|
| `bsp` | rooms + corridors (rect walls, doored) | `cell` (room size), `wallThick` |
| `caves` | cellular-automata organic cover (curved **blob polygons**) | `cell`, `fillProb`, `steps`, `birth`, `death`, `blobScale` |
| `maze` | recursive-backtracker lattice (thin walls) | `cell`, `wallThick`, `braid` |
| `scatter` | clumped boulder/pillar field | `period`, `prob`, `clusterMin/Max`, `radMin/Max`, `jitter` |

Override any style param with repeated `--param k=v` (e.g.
`--param cell=280 --param braid=0.3`).

## How fairness is guaranteed

- **Symmetry** — a style fills only the seed half (or the top-left quadrant
  on rot90/quadmirror); the sim expands it into an exactly team-fair whole via
  `buildArenaObstacles`. Quad-mirror boards also get thin column-anchor bars
  (the transpose of the styles' row anchors) because their validator scans
  VERTICAL sightlines too.
- **Carve** — the sim subtracts any shape overlapping a flag ring, spawn
  pocket, or capture lane, so generators never special-case protected floor.
- **Validators** — `validate` runs the real `mapDiagnostics`: cover budget
  (40–170 permille), no unbroken horizontal sightline, corridor connectivity,
  endzone gates. Non-zero exit on failure.

Every style adds a light backbone of **staggered vertical anchors** in a safe
mid-field x band. A horizontal sightline spans the full width, so scattered
cover alone leaves open lanes; the anchors block every row without forming a
continuous wall (which would fail connectivity), and sit clear of the protected
floor so the carve never reopens a lane.

## Export

A finished `mapSpec` drops straight into a game: set the config's inline map
spec, or feed the JSON into the curated pool. See
[ENV_VARIATION.md](ENV_VARIATION.md) for every map/gameplay knob a level can
vary.
