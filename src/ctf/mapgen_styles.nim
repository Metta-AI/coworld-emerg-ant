## Terrain-style generators for CTF maps.
##
## Each generator is a PURE function of (rng, placement region, params) that
## returns a LEFT-half / quadrant seed set of `ArenaShape`s. It never touches
## symmetry, protected-floor carve, endzones, or validation: those all live in
## `arena.nim` and are applied downstream when the shapes are dropped into a
## `CtfMap.leftObstacles` and the spec is loaded. That keeps every generator
## small and keeps all fairness-critical geometry in one place.
##
## The `region` passed in is the placement band (the seed region already inset
## from the home border, the map edges, and the symmetry seam). Generators keep
## every shape inside it; the seam side is where a shape meets its own mirror
## image, so cover placed near the seam becomes a central feature.

import std/[random, math]
import sim_types

const BlobMaxVerts = 48  ## soft cap on vertices per authored blob polygon.

type
  MapStyle* = enum
    styleBsp = "bsp"
    styleCaves = "caves"
    styleMaze = "maze"
    styleScatter = "scatter"

  StyleParams* = object
    ## Per-style knobs. Every field has a usable default (`defaultParams`);
    ## the CLI overrides individual fields via `--param k=v`.
    # scatter
    period*: int          ## cluster grid spacing (px)
    prob*: float          ## chance a grid cell spawns a cluster
    clusterMin*, clusterMax*: int  ## discs per cluster
    radMin*, radMax*: int ## obstacle radius range (px)
    jitter*: int          ## random offset of each disc from its cell (px)
    # caves
    cell*: int            ## cellular-automata / maze cell size (px)
    fillProb*: float      ## initial wall probability
    steps*: int           ## CA smoothing iterations
    birth*, death*: int   ## CA birth / survival neighbour thresholds
    blobScale*: float     ## emitted blob radius as a fraction of `cell`
    # maze
    wallThick*: int       ## maze wall thickness (px)
    braid*: float         ## fraction of dead-ends to open (0 = perfect maze)
    # all styles
    noAnchors*: bool      ## drop the styles' blind mid-field row anchors —
                          ## for callers (quad-mirror boards) that place their
                          ## own carve-aware anchors instead

proc defaultParams*(style: MapStyle): StyleParams =
  case style
  of styleScatter:
    StyleParams(
      period: 120, prob: 0.45, clusterMin: 1, clusterMax: 2,
      radMin: 16, radMax: 32, jitter: 40)
  of styleCaves:
    StyleParams(
      cell: 46, fillProb: 0.24, steps: 4, birth: 5, death: 4, blobScale: 0.52)
  of styleMaze:
    StyleParams(cell: 96, wallThick: 16, braid: 0.2)
  of styleBsp:
    StyleParams(
      cell: 280, wallThick: 14, jitter: 60, radMin: 60, radMax: 0, prob: 0.0)

proc parseStyle*(text: string): MapStyle =
  case text
  of "bsp": styleBsp
  of "caves": styleCaves
  of "maze": styleMaze
  of "scatter": styleScatter
  else: raise newException(ValueError, "unknown style: " & text)

# --- small helpers -----------------------------------------------------------

proc ri(r: var Rand, lo, hi: int): int =
  ## Inclusive-lo, exclusive-hi integer in [lo, hi); lo when the span is empty.
  if hi <= lo: lo else: lo + rand(r, hi - lo - 1)

proc rectShape(x, y, w, h: int): ArenaShape =
  ArenaShape(kind: shapeRect, rect: MapRect(x: x, y: y, w: w, h: h))

proc discShape(cx, cy, radius: int): ArenaShape =
  ArenaShape(kind: shapeDisc, cx: cx, cy: cy, radius: radius)

proc diamondShape(cx, cy, radius: int): ArenaShape =
  ArenaShape(kind: shapeDiamond, cx: cx, cy: cy, radius: radius)

proc clampCenter(region: MapRect, cx, cy, radius: int): (int, int) =
  ## Keep a radial shape wholly inside the placement band.
  let
    x = clamp(cx, region.x + radius, region.x + region.w - radius)
    y = clamp(cy, region.y + radius, region.y + region.h - radius)
  (x, y)

proc blobPolygon*(
    r: var Rand, region: MapRect, cx, cy, radius, verts: int
): ArenaShape =
  ## An organic closed blob: a base radius wobbled by two low-frequency
  ## sinusoids at random phase, sampled at integer vertices. Vertices are
  ## clamped into the placement band (so the whole set stays fair under the
  ## symmetry). This is what makes caves read as landscape, not stacked discs.
  let
    n = clamp(verts, 6, BlobMaxVerts)
    a2 = 0.20 + rand(r, 1.0) * 0.22
    a3 = 0.10 + rand(r, 1.0) * 0.18
    p2 = rand(r, 1.0) * TAU
    p3 = rand(r, 1.0) * TAU
  var pts = newSeq[MapPoint](n)
  for i in 0 ..< n:
    let
      t = TAU * float(i) / float(n)
      rr = float(radius) * (1.0 + a2 * sin(2.0 * t + p2) + a3 * sin(3.0 * t + p3))
      px = clamp(cx + int(round(cos(t) * rr)),
                 region.x, region.x + region.w)
      py = clamp(cy + int(round(sin(t) * rr)),
                 region.y, region.y + region.h)
    pts[i] = MapPoint(x: px, y: py)
  ArenaShape(kind: shapePolygon, points: pts)

# --- scatter -----------------------------------------------------------------

type AnchorKind = enum akRect, akBlob

proc verticalAnchors(
    r: var Rand, region: MapRect, period, thick: int, kind: AnchorKind
): seq[ArenaShape] =
  ## One anchor obstacle per row band, its x drawn from a safe MID-FIELD range
  ## (clear of the home spawn pockets and the central flag ring, so the carve
  ## never removes it and reopens a sightline). Consecutive anchors overlap
  ## vertically, so their union blocks every horizontal sightline; their x is
  ## randomized (not a fixed column) so no continuous wall forms — cross-map
  ## routes survive, and the anchors read as part of the terrain, not a grid.
  ## `akRect` matches wall-based styles; `akBlob` matches organic ones.
  let
    loX = region.x + region.w * 50 div 100
    hiX = region.x + region.w * 82 div 100
    h = period + 24
    blobR = max(12, thick)  ## akBlob: `thick` doubles as the anchor blob radius
  var gy = region.y
  while gy <= region.y + region.h:
    let x = clamp(ri(r, loX, hiX + 1), region.x, region.x + region.w - thick)
    case kind
    of akRect:
      let
        y = max(region.y, gy - 12)
        hh = min(h, region.y + region.h - y)
      result.add rectShape(x, y, thick, hh)
    of akBlob:
      # A vertical RIDGE of overlapping ORGANIC blobs at one x — reads as a
      # rock spine, not a bar, and blends with organic styles while still
      # blocking the row.
      var yy = max(region.y, gy - 12)
      let yEnd = min(region.y + region.h, gy + period + 12)
      while yy <= yEnd:
        result.add blobPolygon(r, region, x, yy, blobR, 10)
        yy += blobR + blobR div 2
    gy += period

proc genScatter(r: var Rand, region: MapRect, p: StyleParams): seq[ArenaShape] =
  let period = max(48, p.period)
  if not p.noAnchors:
    result.add verticalAnchors(r, region, period, 18, akRect)
  # A `diamond` whose center lands within the map's central spin band becomes a
  # rotating "spinning diamond" — an AUTHORED-arena feature whose renderer
  # (buildPaintedDiamondPixels) assumes the arena's fixed diamond size and
  # overflows on an arbitrary one. The seam is the map center, so keep diamonds
  # clear of the last SpinSafe px before it; everything there falls back to a
  # disc (never spinning). Comfortably wider than DiamondSpinBand (80).
  const SpinSafe = 100
  let diamondMaxX = region.x + region.w - SpinSafe
  var gy = region.y
  while gy <= region.y + region.h:
    var gx = region.x
    while gx <= region.x + region.w:
      if rand(r, 1.0) < p.prob:
        let n = ri(r, p.clusterMin, p.clusterMax + 1)
        for _ in 0 ..< max(1, n):
          let
            radius = ri(r, p.radMin, p.radMax + 1)
            cx = gx + ri(r, -p.jitter, p.jitter + 1)
            cy = gy + ri(r, -p.jitter, p.jitter + 1)
            (x, y) = clampCenter(region, cx, cy, radius)
          if rand(r, 1.0) < 0.5 or x > diamondMaxX:
            result.add discShape(x, y, radius)
          else:
            result.add diamondShape(x, y, radius)
      gx += period
    gy += period

# --- caves (cellular automata) ----------------------------------------------

proc genCaves(r: var Rand, region: MapRect, p: StyleParams): seq[ArenaShape] =
  let
    cell = max(24, p.cell)
    cols = max(3, region.w div cell)
    rows = max(3, region.h div cell)
  proc idx(c, row: int): int = row * cols + c
  var wall = newSeq[bool](cols * rows)
  for i in 0 ..< wall.len:
    wall[i] = rand(r, 1.0) < p.fillProb
  for _ in 0 ..< p.steps:
    var nextGrid = newSeq[bool](cols * rows)
    for row in 0 ..< rows:
      for c in 0 ..< cols:
        var n = 0
        for dy in -1 .. 1:
          for dx in -1 .. 1:
            if dx == 0 and dy == 0: continue
            let nc = c + dx
            let nr = row + dy
            # Off-grid counts as OPEN: counting it as wall makes borders accrete
            # and, on a small (standard-size) cell grid, the CA runs away to a
            # nearly solid fill. Anchors handle edge sightlines, not the CA.
            if nc >= 0 and nc < cols and nr >= 0 and nr < rows and wall[idx(nc, nr)]:
              inc n
        nextGrid[idx(c, row)] =
          if wall[idx(c, row)]: n >= p.death
          else: n >= p.birth
    wall = nextGrid
  if not p.noAnchors:
    result.add verticalAnchors(r, region, cell, 15, akBlob)
  let radius = max(6, int(float(cell) * p.blobScale))
  for row in 0 ..< rows:
    for c in 0 ..< cols:
      if wall[idx(c, row)]:
        let
          cx = region.x + c * cell + cell div 2
          cy = region.y + row * cell + cell div 2
        # Organic blob per cell; adjacent blobs overlap into merged rock.
        result.add blobPolygon(r, region, cx, cy, radius, 14)

# --- maze (recursive-backtracker lattice) -----------------------------------

proc genMaze(r: var Rand, region: MapRect, p: StyleParams): seq[ArenaShape] =
  let
    cell = max(48, p.cell)
    thick = max(6, p.wallThick)
    cols = max(2, region.w div cell)
    rows = max(2, region.h div cell)
  proc idx(c, row: int): int = row * cols + c
  # Carved edges: right[c,r] = passage to (c+1,r); down[c,r] = to (c,r+1).
  var
    right = newSeq[bool](cols * rows)
    down = newSeq[bool](cols * rows)
    visited = newSeq[bool](cols * rows)
    stack = @[(0, 0)]
  visited[0] = true
  while stack.len > 0:
    let (c, row) = stack[^1]
    var nbrs: seq[(int, int, int)]  # (nc, nr, dir) dir: 0=R 1=L 2=D 3=U
    if c + 1 < cols and not visited[idx(c + 1, row)]: nbrs.add (c + 1, row, 0)
    if c - 1 >= 0 and not visited[idx(c - 1, row)]: nbrs.add (c - 1, row, 1)
    if row + 1 < rows and not visited[idx(c, row + 1)]: nbrs.add (c, row + 1, 2)
    if row - 1 >= 0 and not visited[idx(c, row - 1)]: nbrs.add (c, row - 1, 3)
    if nbrs.len == 0:
      discard stack.pop()
      continue
    let (nc, nr, dir) = nbrs[rand(r, nbrs.len - 1)]
    case dir
    of 0: right[idx(c, row)] = true
    of 1: right[idx(nc, nr)] = true
    of 2: down[idx(c, row)] = true
    else: down[idx(nc, nr)] = true
    visited[idx(nc, nr)] = true
    stack.add (nc, nr)
  # Braid: reopen some walls to add loops / cut dead-ends.
  if p.braid > 0:
    for row in 0 ..< rows:
      for c in 0 ..< cols:
        if c + 1 < cols and not right[idx(c, row)] and rand(r, 1.0) < p.braid:
          right[idx(c, row)] = true
        if row + 1 < rows and not down[idx(c, row)] and rand(r, 1.0) < p.braid:
          down[idx(c, row)] = true
  # A perfect maze can carve a straight horizontal corridor spanning the width,
  # which reads as an open sightline. The staggered mid-field anchors guarantee
  # every row is broken without walling off cross-map routes.
  if not p.noAnchors:
    result.add verticalAnchors(r, region, cell, thick, akRect)
  # Emit every NON-carved internal edge as a wall segment.
  let half = thick div 2
  for row in 0 ..< rows:
    for c in 0 ..< cols:
      if c + 1 < cols and not right[idx(c, row)]:
        let
          wx = region.x + (c + 1) * cell - half
          wy = region.y + row * cell
        result.add rectShape(wx, wy, thick, cell)
      if row + 1 < rows and not down[idx(c, row)]:
        let
          wx = region.x + c * cell
          wy = region.y + (row + 1) * cell - half
        result.add rectShape(wx, wy, cell, thick)

# --- bsp (rooms + doors) -----------------------------------------------------

proc bspSplit(r: var Rand, region: MapRect, minCell: int): seq[MapRect] =
  ## Recursively partition into leaf rects, each at least ~minCell on a side.
  if region.w <= minCell * 2 and region.h <= minCell * 2:
    return @[region]
  let horizontal =
    if region.w > region.h * 2: false
    elif region.h > region.w * 2: true
    else: rand(r, 1.0) < 0.5
  if horizontal:
    if region.h < minCell * 2: return @[region]
    let cut = ri(r, minCell, region.h - minCell + 1)
    return bspSplit(r, MapRect(x: region.x, y: region.y, w: region.w, h: cut), minCell) &
      bspSplit(r, MapRect(x: region.x, y: region.y + cut, w: region.w, h: region.h - cut), minCell)
  else:
    if region.w < minCell * 2: return @[region]
    let cut = ri(r, minCell, region.w - minCell + 1)
    return bspSplit(r, MapRect(x: region.x, y: region.y, w: cut, h: region.h), minCell) &
      bspSplit(r, MapRect(x: region.x + cut, y: region.y, w: region.w - cut, h: region.h), minCell)

proc genBsp(r: var Rand, region: MapRect, p: StyleParams): seq[ArenaShape] =
  let
    minCell = max(90, p.cell)
    thick = max(6, p.wallThick)
    pad = 8
    door = max(40, p.radMin)
  # Room walls give most of the coverage; staggered anchors close the gaps
  # between rooms and at door rows that could otherwise be open sightlines.
  if not p.noAnchors:
    result.add verticalAnchors(r, region, minCell div 2, thick, akRect)
  for leaf in bspSplit(r, region, minCell):
    # Room walls inset from the leaf, with a centered door gap per side.
    let
      rx = leaf.x + pad
      ry = leaf.y + pad
      rw = leaf.w - 2 * pad
      rh = leaf.h - 2 * pad
    if rw < door + 2 * thick or rh < door + 2 * thick: continue
    let
      gx = rx + (rw - door) div 2
      gy = ry + (rh - door) div 2
    # Top and bottom walls, split around the vertical door.
    result.add rectShape(rx, ry, gx - rx, thick)
    result.add rectShape(gx + door, ry, rx + rw - (gx + door), thick)
    result.add rectShape(rx, ry + rh - thick, gx - rx, thick)
    result.add rectShape(gx + door, ry + rh - thick, rx + rw - (gx + door), thick)
    # Left and right walls, split around the horizontal door.
    result.add rectShape(rx, ry, thick, gy - ry)
    result.add rectShape(rx, gy + door, thick, ry + rh - (gy + door))
    result.add rectShape(rx + rw - thick, ry, thick, gy - ry)
    result.add rectShape(rx + rw - thick, gy + door, thick, ry + rh - (gy + door))

# --- dispatch ----------------------------------------------------------------

proc generateShapes*(
    style: MapStyle, seed: int, region: MapRect, p: StyleParams
): seq[ArenaShape] =
  ## Deterministic for a given (style, seed, region, params). The stream is
  ## independent of the map generator's own MapRng, so styling a base map never
  ## perturbs its drawn size / endzone / clearances.
  var r = initRand(seed)
  case style
  of styleScatter: genScatter(r, region, p)
  of styleCaves: genCaves(r, region, p)
  of styleMaze: genMaze(r, region, p)
  of styleBsp: genBsp(r, region, p)
