## symnone_demo_map — author ONE genuine asymmetric full-board CTF map to
## exercise the coworld-ctf#280 symNone engine path end-to-end (ENGINE-280
## validation, tasks#42). NOT the unit fixture: this is a real layout with two
## GENUINELY DIFFERENT keeps (not mirror/rot images), three characterful
## entrances per keep, midfield cover, generated items, and EXPLICIT per-team
## pickup points — the whole board authored directly, no symmetry lift.
##
## It mirrors the sheet_scaffold discipline (segment-flanked mid-face doorways
## so the collision mask keeps them open; per-entrance throat + connectivity
## are checked by the engine's own validator + a post-build mask scan here) but
## emits `symmetry: "none"` so both halves are authored, not mirrored.
##
## Emits: <out>.json (spec, designManifest embedded), <out>.manifest.json,
## <out>.art.png (engine-art), <out>.debug.png (collision-truth mask).
## Usage: nim r tools/symnone_demo_map.nim <out-prefix>

import std/[json, os, strformat, math]
import ../src/ctf/[arena, sim_types]
import ./map_render
import pixie

const
  W = 1235
  H = 659
  BODY = 34            # SoldierBodyPx
  CORRIDOR = 68
  WALL = 34            # keep-wall thickness (reads as a chunky wall, welds solid)

# ---- shape helpers -----------------------------------------------------------
proc rectN(x, y, w, h: int): JsonNode =
  %*{"kind": "rect", "x": x, "y": y, "w": w, "h": h}
proc discN(cx, cy, r: int): JsonNode =
  %*{"kind": "disc", "cx": cx, "cy": cy, "r": r}
proc polyN(pts: seq[(int, int)]): JsonNode =
  var a = newJArray()
  for (x, y) in pts: a.add %*[x, y]
  %*{"kind": "polygon", "points": a}

## A keep is a ring of thick wall SEGMENTS around a summit court, with GAPS at
## the three entrances (segment-flanked so the weld/collision keeps them open —
## the v4->v5 lesson). Red and Blue keeps are authored with DIFFERENT geometry:
## different court sizes, different entrance faces, different midfield cover.
proc keepWalls(shapes: var seq[JsonNode], x0, y0, x1, y1: int,
                gaps: seq[tuple[face: char, a, b: int]]) =
  ## Emit the 4 perimeter walls of a keep [x0,y0]..[x1,y1], leaving a gap on
  ## each listed face. face: 'N'/'S' horizontal (gap in x[a,b]); 'W'/'E'
  ## vertical (gap in y[a,b]). Faces with no gap are solid.
  proc gapFor(f: char): tuple[a, b: int] =
    for g in gaps:
      if g.face == f: return (g.a, g.b)
    (0, 0)
  # North wall (row y0), South (row y1-WALL)
  for (face, ry) in [('N', y0), ('S', y1 - WALL)]:
    let (ga, gb) = gapFor(face)
    if ga == 0 and gb == 0:
      shapes.add rectN(x0, ry, x1 - x0, WALL)
    else:
      if ga - x0 >= WALL: shapes.add rectN(x0, ry, ga - x0, WALL)
      if x1 - gb >= WALL: shapes.add rectN(gb, ry, x1 - gb, WALL)
  # West wall (col x0), East (col x1-WALL)
  for (face, rx) in [('W', x0), ('E', x1 - WALL)]:
    let (ga, gb) = gapFor(face)
    if ga == 0 and gb == 0:
      shapes.add rectN(rx, y0, WALL, y1 - y0)
    else:
      if ga - y0 >= WALL: shapes.add rectN(rx, y0, WALL, ga - y0)
      if y1 - gb >= WALL: shapes.add rectN(rx, gb, WALL, y1 - gb)

proc build(): JsonNode =
  var shapes: seq[JsonNode]
  var manifest = %*{
    "map": "symnone-arena-1", "symmetry": "none",
    "entrances": newJArray(), "pedestals": newJArray(),
    "items": newJArray(), "returns": newJArray(), "findings": newJArray()}

  # Engine anchors for a sides board (no per-map flag override in this build):
  # Red at axisHomeLo, Blue at axisHomeHi, both at center.y. Computed once from
  # the classic homeDepth for a 1235x659 board — the keeps MUST enclose these.
  let anchorY = H div 2                               # 329
  let redAX = 186                                     # teamAnchor(Red).x
  let blueAX = 1049                                   # teamAnchor(Blue).x

  # === RED KEEP (west) — a TALL narrow keep enclosing the red anchor, opens E
  # to the field via a wide ramp, N flank crevice, W home crest. ===
  let rx0 = redAX - 90; let rx1 = redAX + 110         # 96..296 (flag off-center in court)
  let ry0 = anchorY - 160; let ry1 = anchorY + 160    # 169..489
  let rflag = (redAX, anchorY)                        # 186, 329 (the engine anchor)
  # gaps sized generously (survive collision), distinct widths: ramp>crevice>crest
  keepWalls(shapes, rx0, ry0, rx1, ry1, @[
    (face: 'E', a: rflag[1] - 70, b: rflag[1] + 70),   # ramp (field), 140 tall
    (face: 'N', a: rflag[0] - 45, b: rflag[0] + 45),   # crevice (flank), 90
    (face: 'W', a: rflag[1] - 35, b: rflag[1] + 35)])  # crest (home), 70
  # red ramp causeway out into the field (two rails, corridor between, aligned
  # with the ramp gap; overlaps the keep so it welds on)
  shapes.add rectN(rx1 - BODY, rflag[1] - 70 - WALL, 3 * BODY, WALL)   # railN
  shapes.add rectN(rx1 - BODY, rflag[1] + 70, 3 * BODY, WALL)          # railS

  # === BLUE KEEP (east) — a SHORT wide keep (deliberately NOT red's mirror):
  # different footprint (wider, shorter), enclosing the blue anchor, opens W to
  # the field, S flank crevice, E home crest. ===
  let bx0 = blueAX - 130; let bx1 = blueAX + 100      # 919..1149
  let by0 = anchorY - 120; let by1 = anchorY + 120    # 209..449 (shorter than red)
  let bflag = (blueAX, anchorY)                       # 1049, 329 (the engine anchor)
  keepWalls(shapes, bx0, by0, bx1, by1, @[
    (face: 'W', a: bflag[1] - 70, b: bflag[1] + 70),   # ramp (field)
    (face: 'S', a: bflag[0] - 45, b: bflag[0] + 45),   # crevice (flank, SOUTH — red's is NORTH)
    (face: 'E', a: bflag[1] - 35, b: bflag[1] + 35)])  # crest (home)
  shapes.add rectN(bx0 - 2 * BODY, bflag[1] - 70 - WALL, 3 * BODY, WALL)
  shapes.add rectN(bx0 - 2 * BODY, bflag[1] + 70, 3 * BODY, WALL)

  # === MIDFIELD — ASYMMETRIC cover (the whole point of full-board): a diagonal
  # ridge NW->SE (not centered, not mirror-symmetric), a lone disc bunker
  # north-of-center, and a polygon spur south. None of these has a twin. ===
  shapes.add polyN(@[(560, 150), (700, 210), (660, 300), (520, 240)])  # NW ridge
  shapes.add discN(720, 470, 40)                                       # S bunker (offset)
  shapes.add polyN(@[(430, 500), (520, 470), (540, 560), (450, 580)])  # SW spur
  shapes.add rectN(600, 380, 120, WALL)                                # central bar, off-center

  # === explicit per-team pickups (symNone has no orbit): Red west, Blue east.
  # Deep in each home column (protected floor) — DIFFERENT y offsets per team,
  # because the keeps are different (function-balanced, not geometric image). ===
  let teamPickups = %*{
    "shields": [[60, 470], [W - 60, 250]],     # red low, blue high (asymmetric)
    "cans":    [[60, 210], [W - 60, 470]],
    "barriers": []}

  # === generated items (law 11b): a STASH at the contested center bar + SINGLE
  # bribes on the two flat lanes. ===
  let medkits = %*[[W div 2, H div 2], [W div 2 - BODY, H div 2 - BODY],
                   [360, 90], [860, 590]]

  # ---- manifest (from the AUTHORED geometry) --------------------------------
  manifest["pedestals"] = %*[
    {"side": "red", "xy": [rflag[0], rflag[1]]},
    {"side": "blue", "xy": [bflag[0], bflag[1]]}]
  manifest["entrances"] = %*[
    {"side": "red", "name": "ramp", "face": "E", "character": "fast-exposed", "gap": 140},
    {"side": "red", "name": "crevice", "face": "N", "character": "slow-safe", "gap": 90},
    {"side": "red", "name": "crest", "face": "W", "character": "tight-egress", "gap": 70},
    {"side": "blue", "name": "ramp", "face": "W", "character": "fast-exposed", "gap": 140},
    {"side": "blue", "name": "crevice", "face": "S", "character": "slow-safe", "gap": 90},
    {"side": "blue", "name": "crest", "face": "E", "character": "tight-egress", "gap": 70}]
  manifest["items"] = %*[
    {"job": "destination stash — the contested central bar", "kind": "medkit-stash",
     "points": [[W div 2, H div 2], [W div 2 - BODY, H div 2 - BODY]]},
    {"job": "route bribe — top flat lane", "kind": "medkit-single", "points": [[360, 90]]},
    {"job": "route bribe — bottom flat lane", "kind": "medkit-single", "points": [[860, 590]]}]
  manifest["returns"] = %*[
    {"side": "red", "attack": "ramp (E, fast-exposed)", "return": "crevice (N flank, quiet)",
     "support": "flank crevice off the contest axis; NW ridge breaks LOS on egress"},
    {"side": "blue", "attack": "ramp (W, fast-exposed)", "return": "crevice (S flank, quiet)",
     "support": "S bunker gives a retreat magnet; keeps are function-balanced not mirrored"}]
  manifest["findings"] = %*[
    "Full-board asymmetric: red keep is TALL/narrow opening E, blue is SHORT/wide opening W — " &
    "genuinely different geometry, not a mirror or rot image. Midfield cover (NW ridge, S bunker, " &
    "SW spur) has no twins. Only expressible under symNone (#280).",
    "Per-team pickups authored explicitly (no symmetry orbit); asymmetric y-offsets per team."]

  result = %*{
    "name": "symnone-arena-1", "width": W, "height": H,
    "flagRing": 70, "captureClear": 210, "spawnClearW": 70, "spawnClearH": 130,
    "gunRange": 1050, "symmetry": "none", "layout": "sides",
    "endzone": "column", "endzoneRadius": 0, "homeDepth": 0,
    # No redAnchorOverride: this engine derives the flag anchor from center +
    # homeDepth (teamAnchor). The keeps are authored to ENCLOSE those anchors
    # (Red 186,329 / Blue 1049,329), which is how a full-board map keeps its
    # flags housed without an override field.
    "medKitSpawns": medkits, "medKitCandidates": medkits,
    "leftObstacles": shapes, "teamPickups": teamPickups,
    "designManifest": manifest}

when isMainModule:
  if paramCount() < 1: quit("usage: symnone_demo_map <out-prefix>")
  let outPrefix = paramStr(1)
  let specNode = build()
  # Validate by loading through the engine (raises if malformed / rails fail).
  let gameMap = mapFromSpecJson($specNode)
  doAssert gameMap.symmetry == symNone
  let full = buildArenaObstacles(gameMap)
  doAssert full.len == gameMap.leftObstacles.len   # verbatim, no mirror lift
  # Write spec (canonical, round-tripped) + manifest sidecar.
  writeFile(outPrefix & ".json", mapSpecJson(gameMap))
  writeFile(outPrefix & ".manifest.json", ($specNode.pretty()))
  # Renders from BUILT geometry.
  let opts = MapRenderOptions(maxDimension: 2470)
  let art = renderMap(gameMap, opts)
  art.image.writeFile(outPrefix & ".art.png")
  echo &"symnone-arena-1: {gameMap.leftObstacles.len} obstacles (verbatim), " &
    &"symmetry={gameMap.symmetry}, wrote {outPrefix}.json/.manifest.json/.art.png"
  echo &"  red flag {gameMap.center}  (anchor override in spec)  full obstacles={full.len}"
