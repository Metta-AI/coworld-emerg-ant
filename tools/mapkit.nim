## mapkit — a CLI for authoring interesting-but-fair CTF maps.
##
## A peer to `tools/map_editor.nim`: it never reimplements geometry, it drives
## the same sim procs (generateMapAttempt, mapSpecJson/mapFromSpecJson,
## validateGeneratedMap, mapDiagnostics, buildArenaObstacles) plus the shared
## `map_render` rasterizer. The working document is a `mapSpec` JSON file.
##
## Claude's loop:
##   mapkit generate --style caves --seed 7 -o m.json
##   mapkit render   m.json -o m.png            # then LOOK at the PNG
##   mapkit validate m.json                     # fair + connected? (exit code)
##   mapkit metrics  m.json                     # interesting? (cover, sightlines)
##   $EDITOR m.json                             # nudge leftObstacles by hand
##   ...repeat until it looks good AND validates.
##
## Fairness is entirely the sim's job: generators emit a one-half/quadrant seed
## set, the sim mirrors it, carves protected floor, and validates. See
## docs/ENV_VARIATION.md and docs/MAPKIT.md.

import
  std/[os, random, strformat, strutils, tables],
  pixie,
  ../src/ctf/[sim, mapgen_styles],
  map_render

type CliError = object of CatchableError

proc fail(msg: string) {.noreturn.} =
  raise newException(CliError, msg)

# --- argument parsing --------------------------------------------------------

type Args = object
  positionals: seq[string]
  flags: Table[string, string]
  params: Table[string, string]  ## repeated --param k=v
  bools: Table[string, bool]

proc parseArgs(argv: seq[string]): Args =
  result.flags = initTable[string, string]()
  result.params = initTable[string, string]()
  result.bools = initTable[string, bool]()
  var i = 0
  while i < argv.len:
    let a = argv[i]
    if a == "--param":
      inc i
      if i >= argv.len: fail("--param needs k=v")
      let kv = argv[i].split('=', 1)
      if kv.len != 2: fail("--param expects k=v, got: " & argv[i])
      result.params[kv[0]] = kv[1]
    elif a.startsWith("--"):
      let body = a[2 .. ^1]
      if body.contains('='):
        let kv = body.split('=', 1)
        result.flags[kv[0]] = kv[1]
      elif i + 1 < argv.len and not argv[i + 1].startsWith("--"):
        result.flags[body] = argv[i + 1]
        inc i
      else:
        result.bools[body] = true
    elif a.startsWith("-") and a.len == 2:
      # short flag: -o value
      let key = if a == "-o": "out" else: a[1 .. ^1]
      inc i
      if i >= argv.len: fail("flag " & a & " needs a value")
      result.flags[key] = argv[i]
    else:
      result.positionals.add a
    inc i

proc flag(a: Args, key, default: string): string =
  a.flags.getOrDefault(key, default)

proc reqFlag(a: Args, key: string): string =
  if key notin a.flags: fail("missing required --" & key)
  a.flags[key]

proc intFlag(a: Args, key: string, default: int): int =
  if key in a.flags: a.flags[key].parseInt else: default

# --- param application -------------------------------------------------------

proc applyParams(p: var StyleParams, params: Table[string, string]) =
  for key, raw in params:
    template asInt: int = raw.parseInt
    template asFloat: float = raw.parseFloat
    case key
    of "period": p.period = asInt
    of "prob": p.prob = asFloat
    of "clusterMin": p.clusterMin = asInt
    of "clusterMax": p.clusterMax = asInt
    of "radMin": p.radMin = asInt
    of "radMax": p.radMax = asInt
    of "jitter": p.jitter = asInt
    of "cell": p.cell = asInt
    of "fillProb": p.fillProb = asFloat
    of "steps": p.steps = asInt
    of "birth": p.birth = asInt
    of "death": p.death = asInt
    of "blobScale": p.blobScale = asFloat
    of "wallThick": p.wallThick = asInt
    of "braid": p.braid = asFloat
    else: fail("unknown --param: " & key)

# --- placement region --------------------------------------------------------

proc placementRegion(base: CtfMap): MapRect =
  ## The seed region, inset only enough to clear the perimeter wall, keep a
  ## touch off the home border, and stop short of the symmetry seam. It spans
  ## nearly the full HEIGHT on purpose: the validator rejects any unbroken
  ## horizontal sightline, so cover must reach top and bottom. Bases need no
  ## wide margin here — the sim carves protected floor out of any shape that
  ## overlaps a flag ring, spawn pocket, or capture lane.
  let
    sr = mapSeedRegion(base)
    vMargin = 2    ## flush to the perimeter wall so cover reaches the edge rows
    hMargin = 40   ## a little off the home border (carve still protects bases)
    seam = 20      ## short of the center seam (where a shape meets its image)
  case base.symmetry
  of symNone:
    ## Full-board: no symmetry seam. Span the whole width inset by hMargin off
    ## BOTH home borders (a symNone author supplies real geometry; this is only
    ## the tool's default cover extent).
    MapRect(x: sr.x + hMargin, y: sr.y + vMargin,
            w: max(1, sr.w - 2 * hMargin), h: max(1, sr.h - 2 * vMargin))
  of symMirror, symRot180:
    MapRect(x: sr.x + hMargin, y: sr.y + vMargin,
            w: max(1, sr.w - hMargin - seam), h: max(1, sr.h - 2 * vMargin))
  of symRot90:
    # rot90: the quadrant's right AND bottom edges are the map's center lines.
    # Keep the x-side seam (anchors stay off the central flag ring), but let the
    # region reach nearly to the center ROW so the vertical anchors chain all the
    # way down — their identity+rot180 images then tile every horizontal row with
    # no center-band gap (and the rot90/rot270 images cover the columns).
    MapRect(x: sr.x + hMargin, y: sr.y + vMargin,
            w: max(1, sr.w - hMargin - seam), h: max(1, sr.h - vMargin))
  of symQuadMirror:
    # quad-mirror: reflections never rotate a shape into cross-coverage, so
    # the quadrant itself must cover the border COLUMNS as well as the edge
    # rows — the validator scans vertical sightlines on these maps. Flush to
    # the perimeter on the left exactly like the top (the protected-floor
    # carve still guards the corner/arm bases); keep both center seams.
    MapRect(x: sr.x + vMargin, y: sr.y + vMargin,
            w: max(1, sr.w - vMargin - seam), h: max(1, sr.h - vMargin))

const styleSalt = 0x9E3779B1  ## decorrelate the style stream from the map seed.

const QuadCenterStrip = 230
  ## Half-width of the seam-centered column strip on quad-mirror boards where
  ## mapkit anchors never go and the NATIVE generator's center furniture is
  ## kept instead: the flag ring's carve dominates that strip, and authored
  ## anchors dodging it kept sealing the center off.

proc quadColumnAnchors(base: CtfMap, region: MapRect, seed: int):
    seq[ArenaShape] =
  ## Quad-mirror boards must break VERTICAL sightlines too (the sim
  ## validator scans columns on them; reflections never rotate a style's
  ## row anchors into column cover the way rot90 does). The styles ship
  ## `verticalAnchors` for rows; this is its transpose, authored here as
  ## tool policy: one thin horizontal bar per column band, bars overlapping
  ## in x so their union (plus the mirrorX images) covers every column, each
  ## bar's y drawn INSIDE the validator's scan band so every bar counts.
  ## Same dashed-double-wall pattern as `quadRowAnchors`, transposed: two
  ## horizontal walls full of door gaps, staggered in x so together they
  ## block every column while each alone stays passable. (The earlier
  ## carve-aware chained bars kept collapsing onto one row and formed an
  ## edge-to-edge wall — the route validator failed every seed.)
  var r = initRand(seed xor 0x51D3_BA22)
  const
    Thick = 12
    SegW = 96
    Door = 58     ## door gap between segments (> the 26px route minimum)
  let
    loY = max(region.y, base.sightlineLoY)
    hiY = min(region.y + region.h - Thick, base.sightlineHiY - Thick)
  if hiY <= loY:
    return
  ## Both walls hug the TOP of the scan band. Their mirrorY images land at
  ## the band's bottom, so the four lines read wall/wall ... open middle ...
  ## wall/wall: the middle of the board stays an open corridor and N<->S
  ## routes only ever thread the two aligned-door pairs. (Walls placed
  ## mid-band interleave with their own images around the center row and
  ## seal the bottom half — doors never line up.) The 64px separation and
  ## the y2 cap keep both the inter-wall corridor and the gap to the mirror
  ## images route-wide even after ridge bulge.
  let
    y1 = loY + r.rand(0 .. 12)
    y2 = min(y1 + Thick + 34 + r.rand(0 .. 12), (base.height - 2 * Thick - 28) div 2)
  if y2 > hiY or y2 <= y1 + Thick + 26:
    return
  ## Segments stop short of the CENTER STRIP: the flag ring's carve erases
  ## mid-band wall there, and anchor segments dodging the ring were sealing
  ## the center into a box. The strip's columns are covered by the native
  ## generator's own center furniture, which `cmdGenerate` keeps.
  for (yHome, phase) in [(y1, 0), (y2, (SegW + Door) div 2)]:
    var x = region.x - (SegW + Door) + phase
    while x <= base.width div 2 - QuadCenterStrip:
      let
        left = max(region.x, x)
        right = min(base.width div 2 - QuadCenterStrip, x + SegW)
      if right > left:
        ## Per-segment carve-aware y: over the corner home boxes the home
        ## row is protected floor (the carve would erase the segment and
        ## reopen those columns), so walk candidate rows deeper in the band
        ## and keep the first that mostly survives. Away from the corners
        ## the home row wins immediately and the wall stays a clean line.
        var
          bestY = yHome
          bestKept = -1
        for y in [yHome, hiY, (loY + hiY) div 2]:
          var kept = 0
          var sx = left
          while sx < right:
            if not mapProtectedFloorAt(base, sx, y + Thick div 2):
              inc kept
            sx += 4
          if kept > bestKept:
            bestKept = kept
            bestY = y
          if kept * 4 >= (right - left) * 3:
            break
        if bestKept > 0:
          result.add rectShape(
            MapRect(x: left, y: bestY, w: right - left, h: Thick))
      x += SegW + Door

proc quadRowAnchors(base: CtfMap, region: MapRect, seed: int):
    seq[ArenaShape] =
  ## The styles' own row anchors (`verticalAnchors`) draw their x blind in a
  ## mid-field band that is safe on 2-team boards — but a quad-mirror
  ## corners/plus board runs protected capture lanes THROUGH that band, the
  ## carve erases whatever lands on them, and the seam/top rows reopen. This
  ## is the carve-aware replacement, the exact transpose of
  ## `quadColumnAnchors`: one thin vertical bar per row band, chained to the
  ## center seam so the mirrorY fold covers the bottom half's rows.
  ## Chained tall bars are a trap here: the carve-aware x choice keeps
  ## collapsing to the same narrow buildable window, and overlapping bars at
  ## one x are a floor-to-ceiling wall — the route validator then fails on
  ## EVERY seed. Instead do what the native 4-team generator does: two
  ## DASHED walls (door gaps a cog fits through) whose segments stagger in
  ## y, so together they still block every row.
  var r = initRand(seed xor 0x2B7E_1516)
  const
    Thick = 12
    SegH = 110    ## wall segment height
    Door = 84     ## door gap between segments (> the 26px route minimum)
  let
    loX = max(region.x, base.sightlineLoX)
    hiX = min(base.width div 2 - QuadCenterStrip,
      min(region.x + region.w - Thick, base.sightlineHiX - Thick))
  if hiX <= loX:
    return
  ## Spread toward the band's edges: the walls plus their ridge bulge need a
  ## route-wide corridor between them, and thirds of this narrow band leave
  ## too little after jitter.
  let
    span = hiX - loX
    x1 = loX + span div 5 + r.rand(-10 .. 10)
    x2 = hiX - span div 5 + r.rand(-10 .. 10)
  if x2 - x1 < Thick + 26:
    return
  for (xHome, phase) in [(x1, 0), (x2, (SegH + Door) div 2)]:
    ## The second wall's segments sit half a period lower, so its walls
    ## cover the first wall's doors (and vice versa): every row is blocked
    ## by one of the two, yet each wall alone is full of doors.
    var y = region.y - (SegH + Door) + phase
    while y <= base.height div 2:
      let
        top = max(region.y, y)
        bot = min(base.height div 2 + SegH div 2, y + SegH)
      if bot > top:
        ## Per-segment carve-aware x, the transpose of the column walls'
        ## carve dodge: segments overlapping a corner home box would be
        ## erased and reopen their rows, so walk candidates deeper into
        ## the band and keep the first that mostly survives.
        var
          bestX = xHome
          bestKept = -1
        for x in [xHome, hiX, (loX + hiX) div 2]:
          var kept = 0
          var sy = top
          while sy < bot:
            if not mapProtectedFloorAt(base, x + Thick div 2, sy):
              inc kept
            sy += 4
          if kept > bestKept:
            bestKept = kept
            bestX = x
          if kept * 4 >= (bot - top) * 3:
            break
        if bestKept > 0:
          result.add rectShape(
            MapRect(x: bestX, y: top, w: Thick, h: bot - top))
      y += SegH + Door

type Box = tuple[x0, y0, x1, y1: int]

proc orbitBoxes(base: CtfMap, shape: ArenaShape): seq[Box] =
  ## Bounding boxes of a seed shape and every image the map's symmetry will
  ## stamp — collision tests against symmetric feature sets (med kits,
  ## trenches) must see the whole orbit or right-half collisions slip by.
  let
    b = shapeBounds(shape)
    w = base.width
    h = base.height
  let
    mx: Box = (w - 1 - b.x1, b.y0, w - 1 - b.x0, b.y1)
    my: Box = (b.x0, h - 1 - b.y1, b.x1, h - 1 - b.y0)
    r180: Box = (w - 1 - b.x1, h - 1 - b.y1, w - 1 - b.x0, h - 1 - b.y0)
  case base.symmetry
  of symNone: @[b]              # no symmetry group: the orbit is the shape itself
  of symMirror: @[b, mx]
  of symRot180: @[b, r180]
  of symQuadMirror: @[b, mx, my, r180]
  of symRot90:
    ## rot90 maps are square, so the quarter-turn box maps stay exact.
    let
      r90: Box = (w - 1 - b.y1, b.x0, w - 1 - b.y0, b.x1)
      r270: Box = (b.y0, w - 1 - b.x1, b.y1, w - 1 - b.x0)
    @[b, r90, r180, r270]

proc keepFeatureClearance(base: var CtfMap) =
  ## Neither the native generator nor the styles check terrain against the
  ## maps' ITEM features: med-kit spawn points are drawn without an
  ## open-floor test, and trenches are placed against the NATIVE terrain
  ## that generate replaces — so kits and pits can end up under rock. Drop
  ## every seed shape whose orbit crowds a med-kit candidate or overlaps a
  ## trench. Dropping whole seed shapes keeps the map exactly team-fair
  ## (a shape's images vanish with it); any cover or sightline the drop
  ## reopens is the validator's to veto.
  const
    KitClear = 30   ## kit pickup range (12) + cog body + a step of slack
    PitClear = 6
  var items: seq[tuple[x, y: int]]
  for kit in base.medKitCandidates:
    items.add (kit.x, kit.y)
  ## Grenade corners are never nudged by the sim; shields and spray cans
  ## are, but a nudged pickup jammed against a rock still reads as "on the
  ## obstacle" in previews — clear them all.
  for point in base.grenadeSpawnPoints():
    items.add point
  items.add base.shieldSpawnPoints()
  items.add base.plasmaArcSpawnPoints()
  var kept: seq[ArenaShape]
  for shape in base.leftObstacles:
    var collides = false
    for b in orbitBoxes(base, shape):
      for item in items:
        if item.x >= b.x0 - KitClear and item.x <= b.x1 + KitClear and
            item.y >= b.y0 - KitClear and item.y <= b.y1 + KitClear:
          collides = true
          break
      if collides:
        break
      for pit in base.trenches:
        let p = shapeBounds(pit)
        if p.x0 - PitClear <= b.x1 and p.x1 + PitClear >= b.x0 and
            p.y0 - PitClear <= b.y1 and p.y1 + PitClear >= b.y0:
          collides = true
          break
      if collides:
        break
    if not collides:
      kept.add shape
  base.leftObstacles = kept

proc markWindows(base: var CtfMap, seed, count: int) =
  ## Glass windows for style terrain. The native generator marks its own
  ## obstacles before `generate` replaces them, so the marks die with the
  ## native set; re-apply the same policy to the style shapes — biased to
  ## the midline band where sightlines matter, count capped like the sim's.
  if count <= 0 or base.leftObstacles.len == 0:
    return
  var r = initRand(seed xor 0x6A09_E667)
  var preferred, rest: seq[int]
  for i, shape in base.leftObstacles:
    let b = shapeBounds(shape)
    if abs((b.y0 + b.y1) div 2 - base.center.y) < 90:
      preferred.add i
    else:
      rest.add i
  r.shuffle(preferred)
  r.shuffle(rest)
  let ranked = preferred & rest
  for i in 0 ..< min(count, ranked.len):
    base.leftObstacles[ranked[i]].window = true

# --- commands ----------------------------------------------------------------

proc readSpec(path: string): CtfMap =
  if not fileExists(path): fail("no such spec file: " & path)
  mapFromSpecJson(readFile(path))

proc cmdGenerate(a: Args) =
  let
    style = parseStyle(a.reqFlag("style"))
    seed = a.intFlag("seed", 1)
    trenches = a.bools.getOrDefault("trenches", false)
    symmetry = a.flag("symmetry", "")
    teams =
      if "teams" in a.flags: a.intFlag("teams", 2)
      elif symmetry in ["rot90", "quadmirror"]: 4
      else: 2
  var overrides = MapGenOverrides(
    size: a.flag("size", ""),
    symmetry: symmetry,
    layout: a.flag("layout", ""),
    endzone: a.flag("endzone", ""),
    windows: -1,
    # --pits N locks the trench count (0..64, sim-validated); --trenches
    # alone keeps the sim's density draw.
    pits: a.intFlag("pits", if trenches: -1 else: 0),
    pitDensity: -1,
  )
  var base = generateMapAttempt(seed, overrides, teams)
  let region = placementRegion(base)
  var params = defaultParams(style)
  if base.symmetry == symQuadMirror:
    ## Quad boards replicate every seed FOUR ways (vs the 2-team mirror's
    ## two) and spend part of the cover ceiling on the column anchors below,
    ## so the organic fill is thinned to keep the validated budget. Explicit
    ## --param overrides still win (applied after).
    case style
    of styleScatter: params.prob = params.prob * 0.62
    of styleCaves: params.fillProb = params.fillProb * 0.9
    of styleMaze: params.wallThick = 12; params.braid = 0.5
    of styleBsp: params.wallThick = 12; params.cell = 340
    ## The styles' own row anchors draw blind in a mid-field band that a
    ## quad-mirror corners/plus board runs its capture lanes through: the
    ## contiguous ridge lands right at the lane funnels and walls the
    ## quadrant off (route validator fails on every seed). Replaced by the
    ## carve-aware quadRowAnchors below.
    params.noAnchors = true
  applyParams(params, a.params)
  let nativeShapes = base.leftObstacles
  base.leftObstacles = generateShapes(style, seed xor styleSalt, region, params)
  if base.symmetry == symQuadMirror:
    ## The seam-centered strip belongs to the NATIVE generator: its center
    ## furniture blocks the flag ring's columns while staying passable —
    ## every authored-anchor scheme tried there either reopened the columns
    ## (carved) or sealed the center into a box. Style shapes clear out of
    ## the strip; the native shapes that live there are kept.
    let stripX = base.width div 2 - QuadCenterStrip
    var kept: seq[ArenaShape]
    for shape in base.leftObstacles:
      if shapeBounds(shape).x1 < stripX:
        kept.add shape
    base.leftObstacles = kept
    for shape in nativeShapes:
      if shapeBounds(shape).x1 >= stripX:
        base.leftObstacles.add shape
    base.leftObstacles.add quadColumnAnchors(base, region, seed)
    base.leftObstacles.add quadRowAnchors(base, region, seed)
  keepFeatureClearance(base)
  ## Windows draw 2..4 on 2-team maps (1..2 on quads) like the sim; --windows
  ## locks the count.
  var wr = initRand(seed xor 0x517C_C1B7)
  let windowsDraw =
    if base.symmetry in {symRot90, symQuadMirror}: 1 + wr.rand(0 .. 1)
    else: 2 + wr.rand(0 .. 2)
  markWindows(base, seed, a.intFlag("windows", windowsDraw))
  let spec = mapSpecJson(base)
  let outPath = a.flag("out", "")
  if outPath.len == 0:
    echo spec
  else:
    writeFile(outPath, spec)
    stderr.writeLine(
      &"generated {style} seed={seed} {base.width}x{base.height} " &
      &"{base.symmetry} shapes={base.leftObstacles.len} -> {outPath}")

proc cmdRender(a: Args) =
  if a.positionals.len == 0: fail("render needs a spec path")
  let
    gameMap = readSpec(a.positionals[0])
    outPath = a.flag("out", a.positionals[0].changeFileExt("png"))
    diagnostics = a.bools.getOrDefault("diagnostics", false)
  var overlays = {overlayProtected, overlayPickups}
  if diagnostics:
    overlays.incl {overlaySightlines, overlayReachability, overlaySeedRegion}
  let options = MapRenderOptions(
    maxDimension: a.intFlag("max", 0),
    overlays: overlays,
    pickupKinds: {pickupMedKitActive, pickupMedKitCandidate})
  renderMap(gameMap, options).image.writeFile(outPath)
  stderr.writeLine(&"rendered {a.positionals[0]} -> {outPath}")

proc printMetrics(gameMap: CtfMap) =
  let diag = mapDiagnostics(gameMap, {})
  echo &"size:          {gameMap.width}x{gameMap.height} {gameMap.symmetry}"
  echo &"endzone:       {gameMap.endzone} radius={gameMap.endzoneRadius}"
  echo &"seed obstacles:{gameMap.leftObstacles.len}"
  echo &"full obstacles:{buildArenaObstacles(gameMap).len}"
  echo &"trenches:      {gameMap.trenches.len}"
  echo &"cover permille:{diag.coverPermille} (min {diag.minCoverPermille})"
  echo &"open sightlines:{diag.openSightlineRows.len} scanned rows"
  echo &"center reachable:{diag.centerReachable}"
  echo &"unreachable teams:{diag.unreachableTeams}"
  echo &"red home on open floor:{diag.redHomeOnOpenFloor}"

proc cmdValidate(a: Args) =
  if a.positionals.len == 0: fail("validate needs a spec path")
  let
    gameMap = readSpec(a.positionals[0])
    reason = validateGeneratedMap(gameMap)
  printMetrics(gameMap)
  if reason.len == 0:
    echo "PASS"
    quit(0)
  else:
    echo "FAIL: " & reason
    quit(1)

proc cmdMetrics(a: Args) =
  if a.positionals.len == 0: fail("metrics needs a spec path")
  printMetrics(readSpec(a.positionals[0]))

proc cmdPuddles(a: Args) =
  ## Patch paint puddles into an existing pinned spec: place --count splats
  ## against the spec's FINAL terrain (obstacles, trenches, base pockets all
  ## already in the file), replacing any puddles the spec carries. --count 0
  ## strips them. Placement is best-effort like the generator's: a crowded
  ## board ships with as many as fit, and the line printed reports the real
  ## number.
  if a.positionals.len == 0: fail("puddles needs a spec path")
  var gameMap = readSpec(a.positionals[0])
  if "count" notin a.flags: fail("missing required --count")
  let count = a.intFlag("count", 0)
  ## Default seed re-derives from the map's own genSeed (salted so the
  ## stream never replays the generator's), keeping the patch deterministic
  ## with no extra bookkeeping.
  let seed = a.intFlag("seed", gameMap.genSeed xor 0x5D1A_7E5)
  placePuddles(gameMap, count, seed)
  let outPath = a.flag("out", a.positionals[0])
  writeFile(outPath, mapSpecJson(gameMap))
  stderr.writeLine(
    &"placed {gameMap.puddles.len}/{count} puddles seed={seed} -> {outPath}")

proc cmdMirror(a: Args) =
  if a.positionals.len == 0: fail("mirror needs a spec path")
  let
    gameMap = readSpec(a.positionals[0])
    full = buildArenaObstacles(gameMap)
  echo &"seed set: {gameMap.leftObstacles.len} shapes"
  echo &"expanded: {full.len} shapes (symmetry {gameMap.symmetry})"

const usage = """
mapkit — author interesting-but-fair CTF maps

  mapkit generate --style bsp|caves|maze|scatter [--seed N] [--size ...]
                  [--symmetry mirror|rot180|rot90|quadmirror]
                  [--endzone column|disc|square]
                  [--teams 2|4] [--trenches] [--pits N] [--windows N]
                  [--param k=v ...] [-o spec.json]
                  (rot90/quadmirror imply --teams 4; quadmirror boards are
                  rectangular; --pits locks the trench count, --windows the
                  glass count)
  mapkit puddles  spec.json --count N [--seed S] [-o out.json]
                  # patch paint puddles into a pinned spec (2-team maps only;
                  # replaces existing puddles, --count 0 strips them)
  mapkit render   spec.json [-o out.png] [--diagnostics] [--max N]
  mapkit validate spec.json      # metrics + PASS/FAIL, non-zero exit on FAIL
  mapkit metrics  spec.json      # cover / sightlines / reachability
  mapkit mirror   spec.json      # seed-set vs expanded obstacle counts
"""

when isMainModule:
  let argv = commandLineParams()
  if argv.len == 0 or argv[0] in ["-h", "--help", "help"]:
    echo usage
    quit(0)
  let a = parseArgs(argv[1 .. ^1])
  try:
    case argv[0]
    of "generate": cmdGenerate(a)
    of "puddles": cmdPuddles(a)
    of "render": cmdRender(a)
    of "validate": cmdValidate(a)
    of "metrics": cmdMetrics(a)
    of "mirror": cmdMirror(a)
    else:
      stderr.writeLine("unknown command: " & argv[0])
      echo usage
      quit(2)
  except CliError as e:
    stderr.writeLine("mapkit: " & e.msg)
    quit(2)
  except CtfError as e:
    stderr.writeLine("mapkit: " & e.msg)
    quit(1)
