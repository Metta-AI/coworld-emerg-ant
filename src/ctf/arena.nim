## The installed map: hand-authored arena geometry (obstacles, anchors,
## spawn pockets, capture zones, shape transforms, spinning-diamond
## fixed-point geometry), the procedural generator + its validators, the
## mapSpec JSON round-trip, the process-global map INSTALL
## (selectCtfMap/loadCtfMap — including the import-time default-arena
## install every consumer relies on), and the per-pixel wall/trench/window
## queries. Stage 3 of docs/plans/2026-08-01-sim-split.md; sim.nim
## re-exports this module, so existing consumers are unchanged.

import
  std/[json, math, strutils],
  jsony, pixie,
  sim_types

import map_pool

proc validateMapRect(name: string, rect: MapRect, width, height: int) =
  ## Raises if one map rectangle is outside the map.
  if rect.w <= 0 or rect.h <= 0:
    raise newException(CtfError, "Map " & name & " size must be positive.")
  if rect.x < 0 or rect.y < 0 or
      rect.x + rect.w > width or rect.y + rect.h > height:
    raise newException(CtfError, "Map " & name & " is outside the map.")

proc validateMapPoint(name: string, point: MapPoint, width, height: int) =
  ## Raises if one map point is outside the map.
  if point.x < 0 or point.y < 0 or point.x >= width or point.y >= height:
    raise newException(CtfError, "Map " & name & " is outside the map.")

proc rectShape*(r: MapRect): ArenaShape =
  ## Wrap a rectangle as a rect-kind shape (trenches are stored as shapes).
  ArenaShape(kind: shapeRect, rect: r)

proc shapeAsRect*(s: ArenaShape): MapRect =
  ## The rectangle for a rect-kind shape; the tight bounding box for any other
  ## kind. Trench generation and the rect-edge trench art work in rectangles;
  ## this bridges them to the shape-typed `trenches` field.
  case s.kind
  of shapeRect:
    s.rect
  of shapeDisc, shapeDiamond:
    MapRect(x: s.cx - s.radius, y: s.cy - s.radius,
            w: 2 * s.radius + 1, h: 2 * s.radius + 1)
  of shapeDiagonal:
    let half = s.thickness div 2 + 1
    MapRect(x: min(s.x0, s.x1) - half, y: min(s.y0, s.y1) - half,
            w: abs(s.x1 - s.x0) + 2 * half, h: abs(s.y1 - s.y0) + 2 * half)
  of shapePolygon:
    if s.points.len == 0:
      MapRect(x: 0, y: 0, w: 0, h: 0)
    else:
      var
        x0 = s.points[0].x
        y0 = s.points[0].y
        x1 = s.points[0].x
        y1 = s.points[0].y
      for p in s.points:
        x0 = min(x0, p.x); y0 = min(y0, p.y)
        x1 = max(x1, p.x); y1 = max(y1, p.y)
      MapRect(x: x0, y: y0, w: x1 - x0 + 1, h: y1 - y0 + 1)

proc maxEndzoneRadius*(width: int): int =
  ## The compact-endzone radius ceiling for a board of this width. The
  ## classic EndzoneRadiusMax was authored for the STANDARD 1235-wide field
  ## (it keeps the two zones clear of the center ring); a wider board
  ## supports a proportionally larger zone — the generator draws the radius
  ## as a width fraction, and the oversize classes draw past 220. Narrower
  ## boards keep the classic cap rather than tightening a bound existing
  ## configs were allowed to use.
  max(EndzoneRadiusMax, width * EndzoneRadiusMax div 1235)

proc validateMap(gameMap: CtfMap) =
  ## Raises if a loaded map has invalid geometry.
  if gameMap.width <= 0 or gameMap.height <= 0:
    raise newException(CtfError, "Map dimensions must be positive.")
  case gameMap.layout
  of layoutSides:
    if gameMap.symmetry in {symRot90, symQuadMirror}:
      raise newException(
        CtfError, "Sides maps cannot use a 4-team symmetry (rot90/quadmirror).")
  of layoutCorners, layoutPlus:
    if gameMap.symmetry notin {symRot90, symQuadMirror}:
      raise newException(
        CtfError, "Corner/plus maps need rot90 or quadmirror symmetry.")
  if gameMap.symmetry == symRot90 and gameMap.width != gameMap.height:
    ## rot90 rotates about the center of a SQUARE; a non-square board would
    ## silently produce team-unfair obstacle images.
    raise newException(CtfError, "rot90 symmetry needs a square map.")
  if gameMap.homeDepth != 0 and
      (gameMap.homeDepth < HomeDepthMin or gameMap.homeDepth > HomeDepthMax):
    raise newException(
      CtfError, "Map home depth must be " & $HomeDepthMin & ".." &
        $HomeDepthMax & " permille (0 = the classic " &
        $ClassicHomeDepth & ").")
  if gameMap.endzone == ezColumn:
    if gameMap.endzoneRadius != 0:
      raise newException(
        CtfError, "Column endzones carry no radius.")
  else:
    if gameMap.layout != layoutSides:
      raise newException(
        CtfError, "Compact endzones need a 2-team sides map.")
    if gameMap.endzoneRadius < EndzoneRadiusMin or
        gameMap.endzoneRadius > maxEndzoneRadius(gameMap.width):
      raise newException(
        CtfError, "Map endzone radius must be " & $EndzoneRadiusMin & ".." &
          $maxEndzoneRadius(gameMap.width) & " px.")
  validateMapPoint("center", gameMap.center, gameMap.width, gameMap.height)
  for i, room in gameMap.rooms:
    validateMapRect(
      "room " & $i,
      MapRect(x: room.x, y: room.y, w: room.w, h: room.h),
      gameMap.width,
      gameMap.height
    )
  for i, trench in gameMap.trenches:
    validateMapRect(
      "trench " & $i, shapeAsRect(trench), gameMap.width, gameMap.height)
  ## coworld-ctf#280 full-board (symNone) invariants. Fairness is NOT checked
  ## here (it is a MEASURED property the caller gates on); we only enforce that
  ## the spec is well-formed so the sim has real per-team points to place.
  if gameMap.symmetry == symNone:
    if gameMap.layout != layoutSides:
      raise newException(CtfError,
        "symNone (full-board) maps are 2-team: they need a sides layout.")
    let teamCount = 2
    ## Every explicit pickup set present must be point-per-team (barriers are
    ## config-gated, so an EMPTY barriers set is allowed — the config decides
    ## perTeam; a NON-empty set must be a whole multiple of teamCount).
    for (name, pts, perTeamOne) in [
        ("teamPickups.shields", gameMap.teamPickups.shields, true),
        ("teamPickups.cans", gameMap.teamPickups.cans, true),
        ("teamPickups.barriers", gameMap.teamPickups.barriers, false)]:
      if perTeamOne:
        if pts.len != teamCount:
          raise newException(CtfError,
            "symNone map must author " & $teamCount & " explicit points for " &
            name & " (one per team); got " & $pts.len &
            " — no symmetry orbit exists to derive them.")
      elif pts.len mod teamCount != 0:
        raise newException(CtfError,
          name & " on a symNone map must carry the same count per team " &
          "(a multiple of " & $teamCount & "); got " & $pts.len & ".")
      for i, p in pts:
        validateMapPoint(name & "[" & $i & "]", p, gameMap.width, gameMap.height)
    ## The WALL-OVERLAP walkability check needs buildArenaObstacles/mapWallAt,
    ## which are defined later in this module — run it in validateMapWalkability
    ## (called from mapFromSpecJson right after this), not here.

const
  ArenaName = "arena"
  ArenaLargeName = "arena-large"
  ArenaBorder* = 10            ## perimeter wall thickness in px.

  ## Warm CRT-phosphor arena (REPLAY_DESIGN §3 art-lock): neutral-warm grey
  ## polished-concrete floor, warm-stone cover, the two team colors the only
  ## saturated channels — never the cold blue-slate default the house style
  ## forbids.
  ArenaBorderColor* = rgba(44, 34, 25, 255)

  ## Interior obstacle shapes for the LEFT half only. Each is mirrored
  ## across the vertical center line so both halves are identical, and the
  ## in-column shapes come in top/bottom mirrored pairs around the map's
  ## horizontal midline. With map-wide guns the layout is a slalom of five
  ## staggered columns (x-centers 277/349/421/493/565 plus their x-mirrors)
  ## whose in-column gaps are offset from the neighbours', so every
  ## horizontal row hits a shape and no straight cross-field ray survives,
  ## while every corridor stays >= 26px for the 13px player footprint. The
  ## columns vary the shape per lane: border-attached rect stubs, diamonds,
  ## discs, 45-degree chevron walls angling across the old corridors, and
  ## rect/diamond stubs flanking the flag ring. A windowed square bracket
  ## straddling the horizontal midline closes the mid lane outside the flag
  ## ring to movement and fire, while its glass center pane gives both teams
  ## a fogless sightline down the center corridor (GameVersion 16); the
  ## ring itself stays an open disc for close flag fights. Shapes sit
  ## between the capture/spawn columns and the flag ring; isProtectedFloor
  ## carves them out of the ring, pockets, and capture columns.
  ArenaLeftObstacles = [
    # Column 1 (x=268..286): rect stubs, phase 0, border-attached ends.
    # GV27 (operator rule): the GLASS WINDOWS alternate from both ends —
    # stone, glass, stone, glass — landing on stubs 2, 4 (the middle), and
    # 6 of 7, a top/bottom-symmetric set. Glass is solid to movement,
    # bullets, and spray cones, transparent to fog-of-war; x-mirrored like
    # every column-1 shape.
    ArenaShape(kind: shapeRect, rect: MapRect(x: 268, y: 10, w: 18, h: 62)),
    ArenaShape(kind: shapeRect, window: true,
      rect: MapRect(x: 268, y: 108, w: 18, h: 60)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 268, y: 204, w: 18, h: 60)),
    ArenaShape(kind: shapeRect, window: true,
      rect: MapRect(x: 268, y: 300, w: 18, h: 59)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 268, y: 395, w: 18, h: 60)),
    ArenaShape(kind: shapeRect, window: true,
      rect: MapRect(x: 268, y: 491, w: 18, h: 60)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 268, y: 587, w: 18, h: 62)),
    # Column 2 (x=349): diamonds, phase +48 (half period) vs column 1.
    ArenaShape(kind: shapeDiamond, cx: 349, cy: 90, radius: 28),
    ArenaShape(kind: shapeDiamond, cx: 349, cy: 186, radius: 28),
    ArenaShape(kind: shapeDiamond, cx: 349, cy: 282, radius: 28),
    ArenaShape(kind: shapeDiamond, cx: 349, cy: 376, radius: 28),
    ArenaShape(kind: shapeDiamond, cx: 349, cy: 472, radius: 28),
    ArenaShape(kind: shapeDiamond, cx: 349, cy: 568, radius: 28),
    # Column 3 (x=421): discs, phase +24. GameVersion 16 thinned the lane:
    # every other disc removed (was 66/162/258/400/496/592), giving the
    # column real gaps instead of a near-solid picket. Top/bottom mirror
    # symmetry is intentionally traded for the lower density; team fairness
    # only needs the x-mirror.
    ArenaShape(kind: shapeDisc, cx: 421, cy: 66, radius: 28),
    ArenaShape(kind: shapeDisc, cx: 421, cy: 258, radius: 28),
    ArenaShape(kind: shapeDisc, cx: 421, cy: 496, radius: 28),
    # Column 4 (x=479..509): 45-degree chevron walls, phase +72; the
    # midline pair was replaced in GameVersion 16 by the windowed bracket
    # below.
    ArenaShape(kind: shapeDiagonal, x0: 479, y0: 86, x1: 507, y1: 114, thickness: 12),
    ArenaShape(kind: shapeDiagonal, x0: 507, y0: 114, x1: 479, y1: 142, thickness: 12),
    ArenaShape(kind: shapeDiagonal, x0: 507, y0: 182, x1: 479, y1: 210, thickness: 12),
    ArenaShape(kind: shapeDiagonal, x0: 479, y0: 210, x1: 507, y1: 238, thickness: 12),
    # GameVersion 16: the old midline chevron zigzag (the sideways "W" that
    # closed the mid lane) is now a square bracket over the same footprint
    # (x=479..507, y=276..383): a vertical bar on the outer side plus short
    # arms reaching toward the flag ring — "[" here, "]" on the x-mirror.
    # The middle of the bar, straddling the midline, is a GLASS WINDOW:
    # the mid lane stays closed to movement, bullets, and spray, but
    # fog-of-war now sees straight down the center corridor through it.
    ArenaShape(kind: shapeRect, rect: MapRect(x: 479, y: 276, w: 28, h: 12)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 479, y: 288, w: 12, h: 24)),
    ArenaShape(kind: shapeRect, window: true,
      rect: MapRect(x: 479, y: 312, w: 12, h: 36)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 479, y: 348, w: 12, h: 23)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 479, y: 371, w: 28, h: 12)),
    ArenaShape(kind: shapeDiagonal, x0: 507, y0: 421, x1: 479, y1: 449, thickness: 12),
    ArenaShape(kind: shapeDiagonal, x0: 479, y0: 449, x1: 507, y1: 477, thickness: 12),
    ArenaShape(kind: shapeDiagonal, x0: 479, y0: 517, x1: 507, y1: 545, thickness: 12),
    ArenaShape(kind: shapeDiagonal, x0: 507, y0: 545, x1: 479, y1: 573, thickness: 12),
    # Column 5 (x=556..595): rect stubs at the borders, diamonds flanking
    # the flag ring (the ring carves their inner edges).
    ArenaShape(kind: shapeRect, rect: MapRect(x: 556, y: 24, w: 18, h: 66)),
    ArenaShape(kind: shapeDiamond, cx: 565, cy: 156, radius: 30),
    ArenaShape(kind: shapeDiamond, cx: 565, cy: 252, radius: 30),
    ArenaShape(kind: shapeDiamond, cx: 565, cy: 406, radius: 30),
    ArenaShape(kind: shapeDiamond, cx: 565, cy: 502, radius: 30),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 556, y: 569, w: 18, h: 66)),
  ]

  ## The arena-large layout (1606x858, 30% bigger in both axes): every
  ## shape keeps its `arena` SIZE while its CENTER (and the layout
  ## clearances) scale by 1.3, so the same cover sits in a roomier field
  ## with ~30% wider corridors — and some long sightlines the dense arena
  ## deliberately closed now survive; the field plays roomier by design.
  ## Five staggered columns at x-centers 360/454/547/641/735 plus their
  ## x-mirrors; border-attached stubs stay attached and the column-5 border
  ## gaps stay < 26px (impassable) rather than scaling into new lanes.
  ArenaLargeLeftObstacles = [
    # Column 1 (x=351..369): rect stubs, phase 0, border-attached ends. The
    # SECOND stub from the top and from the bottom are GLASS WINDOWS
    # (GameVersion 15): solid to movement, bullets, and spray cones, transparent
    # to fog-of-war.
    ArenaShape(kind: shapeRect, rect: MapRect(x: 351, y: 10, w: 18, h: 62)),
    ArenaShape(kind: shapeRect, window: true,
      rect: MapRect(x: 351, y: 149, w: 18, h: 60)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 351, y: 274, w: 18, h: 60)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 351, y: 399, w: 18, h: 59)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 351, y: 524, w: 18, h: 60)),
    ArenaShape(kind: shapeRect, window: true,
      rect: MapRect(x: 351, y: 649, w: 18, h: 60)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 351, y: 786, w: 18, h: 62)),
    # Column 2 (x=454): diamonds, phase +48 (half period) vs column 1.
    ArenaShape(kind: shapeDiamond, cx: 454, cy: 117, radius: 28),
    ArenaShape(kind: shapeDiamond, cx: 454, cy: 242, radius: 28),
    ArenaShape(kind: shapeDiamond, cx: 454, cy: 367, radius: 28),
    ArenaShape(kind: shapeDiamond, cx: 454, cy: 491, radius: 28),
    ArenaShape(kind: shapeDiamond, cx: 454, cy: 616, radius: 28),
    ArenaShape(kind: shapeDiamond, cx: 454, cy: 741, radius: 28),
    # Column 3 (x=547): discs, phase +24. GameVersion 16 thinned the lane:
    # every other disc removed, giving the column real gaps instead of a
    # near-solid picket. Top/bottom mirror symmetry is intentionally traded
    # for the lower density; team fairness only needs the x-mirror.
    ArenaShape(kind: shapeDisc, cx: 547, cy: 86, radius: 28),
    ArenaShape(kind: shapeDisc, cx: 547, cy: 335, radius: 28),
    ArenaShape(kind: shapeDisc, cx: 547, cy: 645, radius: 28),
    # Column 4 (x=627..655): 45-degree chevron walls, phase +72; the
    # midline pair was replaced in GameVersion 16 by the windowed bracket
    # below.
    ArenaShape(kind: shapeDiagonal, x0: 627, y0: 120, x1: 655, y1: 148, thickness: 12),
    ArenaShape(kind: shapeDiagonal, x0: 655, y0: 148, x1: 627, y1: 176, thickness: 12),
    ArenaShape(kind: shapeDiagonal, x0: 655, y0: 245, x1: 627, y1: 273, thickness: 12),
    ArenaShape(kind: shapeDiagonal, x0: 627, y0: 273, x1: 655, y1: 301, thickness: 12),
    # GameVersion 16: the old midline chevron zigzag (the sideways "W" that
    # closed the mid lane) is now a square bracket over the same footprint
    # (x=627..655, y=375..482): a vertical bar on the outer side plus short
    # arms reaching toward the flag ring — "[" here, "]" on the x-mirror.
    # The middle of the bar, straddling the midline, is a GLASS WINDOW:
    # the mid lane stays closed to movement, bullets, and spray, but
    # fog-of-war now sees straight down the center corridor through it.
    ArenaShape(kind: shapeRect, rect: MapRect(x: 627, y: 375, w: 28, h: 12)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 627, y: 387, w: 12, h: 24)),
    ArenaShape(kind: shapeRect, window: true,
      rect: MapRect(x: 627, y: 411, w: 12, h: 36)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 627, y: 447, w: 12, h: 23)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 627, y: 470, w: 28, h: 12)),
    ArenaShape(kind: shapeDiagonal, x0: 655, y0: 557, x1: 627, y1: 585, thickness: 12),
    ArenaShape(kind: shapeDiagonal, x0: 627, y0: 585, x1: 655, y1: 613, thickness: 12),
    ArenaShape(kind: shapeDiagonal, x0: 627, y0: 682, x1: 655, y1: 710, thickness: 12),
    ArenaShape(kind: shapeDiagonal, x0: 655, y0: 710, x1: 627, y1: 738, thickness: 12),
    # Column 5 (x=726..744): rect stubs at the borders (their border gaps
    # stay < 26px, i.e. impassable, rather than scaling into new lanes),
    # diamonds flanking the flag ring.
    ArenaShape(kind: shapeRect, rect: MapRect(x: 726, y: 31, w: 18, h: 66)),
    ArenaShape(kind: shapeDiamond, cx: 735, cy: 203, radius: 30),
    ArenaShape(kind: shapeDiamond, cx: 735, cy: 328, radius: 30),
    ArenaShape(kind: shapeDiamond, cx: 735, cy: 530, radius: 30),
    ArenaShape(kind: shapeDiamond, cx: 735, cy: 655, radius: 30),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 726, y: 761, w: 18, h: 66)),
  ]

proc homeDepthOf(gameMap: CtfMap): int =
  ## The map's home-anchor depth permille, defaulting to the classic 700 so
  ## a zero-valued map (a hand-built test fixture, an old replay spec) keeps
  ## the historical anchors.
  if gameMap.homeDepth > 0: gameMap.homeDepth else: ClassicHomeDepth

proc axisHomeLo(center, depth: int): int =
  ## Returns the low-edge home anchor along one axis: `depth` permille of the
  ## way back from the center (700 = the classic 30%-from-the-edge home-x).
  ## At 700 this is exactly the historical `center * 7 div 10`.
  center - (center * depth div 1000)

proc axisHomeHi(center, size, depth: int): int =
  ## Returns the high-edge home anchor along one axis (the classic Blue
  ## home-x formula at depth 700).
  center + ((size - center) * depth div 1000)

proc rot90Point*(p: MapPoint, side: int): MapPoint {.inline.} =
  ## One quarter turn clockwise about the center of a side x side square
  ## board: (x, y) -> (side - 1 - y, x).
  ##
  ## The fixed point of that map is (side - 1)/2, which on an EVEN-sided
  ## board is a half pixel away from the div-derived `center`. Anything that
  ## has to be exactly its own quarter turn must therefore be built by
  ## walking this orbit (or measured in doubled coordinates), never anchored
  ## to `center` — see rot90Quarter and centerOffset2.
  MapPoint(x: side - 1 - p.y, y: p.x)

proc rot90Quarter*(gameMap: CtfMap, team: Team): int =
  ## How many quarter turns separate RED's quadrant from this team's. Team
  ## enum order is not orbit order for either 4-team layout, so the mapping
  ## is spelled out per layout; sides maps have no rot90 orbit at all.
  case gameMap.layout
  of layoutSides:
    0
  of layoutCorners:
    ## Orbit top-left -> top-right -> bottom-right -> bottom-left.
    case team
    of Red: 0
    of Blue: 1
    of Yellow: 2
    of Green: 3
  of layoutPlus:
    ## Orbit west -> north -> east -> south.
    case team
    of Red: 0
    of Green: 1
    of Blue: 2
    of Yellow: 3

proc rot90TeamPoint*(gameMap: CtfMap, red: MapPoint, team: Team): MapPoint =
  ## RED's point walked round the orbit to `team`'s quadrant. Anything one
  ## team owns a copy of — a home, a pickup — has to be built this way: the
  ## rot90 wall mask carries Red's surroundings onto the image of Red's
  ## point, so a copy placed by MIRRORING lands in the transpose of them
  ## instead, with different cover and different sightlines.
  result = red
  for _ in 0 ..< gameMap.rot90Quarter(team):
    result = result.rot90Point(gameMap.width)

proc teamImagePoint*(gameMap: CtfMap, red: MapPoint, team: Team): MapPoint =
  ## RED's point carried onto `team`'s side of the board by the map's OWN
  ## symmetry — the general form of `rot90TeamPoint`, for the 2-team boards
  ## too.
  ##
  ## Which symmetry is not a detail: the terrain was built with exactly one
  ## of them, and only that one carries Red's surroundings onto the image.
  ## On a rot180 board a MIRRORED copy lands in the rotation of some other
  ## Red spot instead — which is how the shields came to sit in the terrain
  ## of the spray cans, and the cans in the terrain of the shields.
  case gameMap.symmetry
  of symNone:
    ## Full-board maps have NO symmetry group, so there is no image of Red's
    ## point to carry — per-team points are authored EXPLICITLY in the spec.
    ## Reaching here means a caller tried to derive a team image on a symNone
    ## map (a bug: it should have read the explicit point). Fail loudly rather
    ## than invent an orbit that does not exist.
    raise newException(CtfError,
      "teamImagePoint has no meaning under symNone (full-board): the spec must " &
      "carry an explicit point for team " & $team & " — no symmetry image exists.")
  of symRot90:
    gameMap.rot90TeamPoint(red, team)
  of symMirror:
    if team == Red: red
    else: MapPoint(x: gameMap.width - 1 - red.x, y: red.y)
  of symRot180:
    if team == Red: red
    else: MapPoint(
      x: gameMap.width - 1 - red.x, y: gameMap.height - 1 - red.y)
  of symQuadMirror:
    ## Klein-four images. Corner maps carry Red's TL point by the group
    ## itself: Blue = mirrorX (TR), Green = mirrorY (BL), Yellow = rot180
    ## (BR) — the same team-to-quadrant assignment the rot90 orbit lands on.
    ## Plus maps have NO group element carrying the west arm onto the north
    ## one (on a rectangle the W/E and N/S arm pairs are two separate
    ## congruence classes), so Green takes a pseudo-quarter-turn about the
    ## integer center into the north arm and Yellow is Green's EXACT mirrorY
    ## image in the south arm: W/E and N/S each stay bit-exact mirror pairs.
    if gameMap.layout == layoutPlus:
      let green = MapPoint(
        x: gameMap.center.x - (red.y - gameMap.center.y), y: red.x)
      case team
      of Red: red
      of Blue: MapPoint(x: gameMap.width - 1 - red.x, y: red.y)
      of Green: green
      of Yellow: MapPoint(x: green.x, y: gameMap.height - 1 - green.y)
    else:
      case team
      of Red: red
      of Blue: MapPoint(x: gameMap.width - 1 - red.x, y: red.y)
      of Green: MapPoint(x: red.x, y: gameMap.height - 1 - red.y)
      of Yellow: MapPoint(
        x: gameMap.width - 1 - red.x, y: gameMap.height - 1 - red.y)

proc teamAnchor*(gameMap: CtfMap, team: Team): MapPoint =
  ## Returns one team's home anchor: the center of its protected spawn
  ## pocket, where its pedestal stands.
  ##
  ## rot90 4-team anchors are RED's anchor walked around the rot90 orbit, so
  ## every team's home is EXACTLY a quarter turn of every other team's.
  ## Deriving the far anchors from axisHomeHi instead would place them
  ## symmetrically about `center` — one pixel off the orbit on an even-sided
  ## board, which is a fairness difference, not a rounding detail.
  ##
  ## QUAD-MIRROR anchors never walk the rot90 orbit (a quarter turn is not a
  ## group element, and on a rectangle it does not even stay on the board).
  ## Corner maps take the four reflections of Red's TL anchor, so all four
  ## homes are exactly congruent. Plus maps author TWO seeds — Red at the
  ## west arm mouth and Green at the north one — and reflect each across its
  ## axis (Blue = mirrorX of Red, Yellow = mirrorY of Green): the W/E homes
  ## are exact mirror twins and so are the N/S ones, two congruence classes
  ## rather than rot90's single one, which is the honest fairness story on a
  ## rectangle. The validator's per-team reachability still covers all four.
  let
    cx = gameMap.center.x
    cy = gameMap.center.y
    d = gameMap.homeDepthOf()
  case gameMap.layout
  of layoutSides:
    result =
      case team
      of Red:
        MapPoint(x: axisHomeLo(cx, d), y: cy)
      else:
        MapPoint(x: axisHomeHi(cx, gameMap.width, d), y: cy)
  of layoutCorners, layoutPlus:
    if gameMap.symmetry == symQuadMirror:
      if gameMap.layout == layoutCorners:
        result = gameMap.teamImagePoint(
          MapPoint(x: axisHomeLo(cx, d), y: axisHomeLo(cy, d)), team)
      else:
        let
          red = MapPoint(x: axisHomeLo(cx, d), y: cy)
          green = MapPoint(x: cx, y: axisHomeLo(cy, d))
        result =
          case team
          of Red: red
          of Blue: MapPoint(x: gameMap.width - 1 - red.x, y: red.y)
          of Green: green
          of Yellow: MapPoint(x: green.x, y: gameMap.height - 1 - green.y)
      return
    ## Red seeds the rot90 orbit: top-left on corner maps, west on plus maps.
    result =
      if gameMap.layout == layoutCorners:
        MapPoint(x: axisHomeLo(cx, d), y: axisHomeLo(cy, d))
      else:
        MapPoint(x: axisHomeLo(cx, d), y: cy)
    for _ in 0 ..< gameMap.rot90Quarter(team):
      result = result.rot90Point(gameMap.width)

proc spawnPocketHalf*(gameMap: CtfMap, team: Team): tuple[w, h: int] =
  ## The half-extents of one team's protected spawn pocket, around its
  ## anchor. The pocket is taller than it is wide, so it does NOT survive a
  ## quarter turn unchanged: on rot90 boards the odd quarters carry the
  ## rotated W x H -> H x W box. Stamping the same box at all four anchors
  ## would carve two of the four quadrants to a different shape than their
  ## rotational twins — on a 1248px board that is ~119k pixels, 7.6% of the
  ## board, where the protected floor disagrees with its own quarter turn.
  ##
  ## Mirror, rot180 and quad-mirror symmetries preserve the axes, so 2-team
  ## maps — and every quad-mirror team — keep the single upright box: the
  ## reflections carry an upright W x H box onto an upright W x H box.
  if gameMap.symmetry == symRot90 and gameMap.rot90Quarter(team) mod 2 == 1:
    (gameMap.spawnClearH, gameMap.spawnClearW)
  else:
    (gameMap.spawnClearW, gameMap.spawnClearH)

proc plusArmHalf*(gameMap: CtfMap): int =
  ## Returns the half-span of a plus map's arms — the width of each team's
  ## endzone mouth and protected approach: 19% of the map side, comfortably
  ## wider than the spawn pockets on every size class.
  19 * min(gameMap.width, gameMap.height) div 100

proc plusArmBandOn*(gameMap: CtfMap, span: int): tuple[lo, hi: int] =
  ## The inclusive span an arm occupies across one axis of length `span`,
  ## centered on that axis's TRUE symmetry axis at (span - 1)/2 rather than
  ## on the integer center. The two differ by a pixel on an even span, and a
  ## band centered on `center` is not its own reflection — the west arm's
  ## y-span would land one pixel off its mirrorY image. Identical to the
  ## doubled comparison mapProtectedFloorAt carves the approach with. On the
  ## (square) rot90 boards width and height agree; a RECTANGULAR quad-mirror
  ## board passes height for the W/E arms and width for the N/S ones.
  let lo = (span - 2 * gameMap.plusArmHalf()) div 2
  (lo, span - 1 - lo)

proc plusArmBand*(gameMap: CtfMap): tuple[lo, hi: int] =
  ## The classic single-band form (square boards, where both axes agree).
  gameMap.plusArmBandOn(min(gameMap.width, gameMap.height))

proc teamHomeX*(gameMap: CtfMap, team: Team): int =
  ## Returns the home-edge x anchor for one team's spawn strip and pedestal.
  gameMap.teamAnchor(team).x

proc flagHome*(gameMap: CtfMap, team: Team): MapPoint =
  ## Returns the pedestal position for one team's flag, at the center of the
  ## team's protected spawn pocket.
  gameMap.teamAnchor(team)

proc trenchSquareAt(cx, cy: int): MapRect =
  ## A TrenchSize×TrenchSize dug pit centered on (cx, cy). Like obstacle
  ## sizes, the pit never scales with the map's size class.
  MapRect(
    x: cx - TrenchSize div 2,
    y: cy - TrenchSize div 2,
    w: TrenchSize,
    h: TrenchSize
  )

proc rectsIntersect(a, b: MapRect): bool =
  ## Returns true when the two rectangles overlap by at least one pixel.
  a.x < b.x + b.w and b.x < a.x + a.w and
    a.y < b.y + b.h and b.y < a.y + a.h

proc defaultCtfRooms(gameMap: CtfMap): seq[Room] =
  ## The room annotation set every map shares: an informal center zone plus
  ## one base strip per team spanning its spawn pocket. Derives entirely
  ## from the map's dimensions and clearances. Sides maps keep the classic
  ## full-clearance base columns; 4-team layouts box each pocket instead.
  result.add Room(name: "Center", x: gameMap.width div 2 - 80,
    y: gameMap.height div 2 - 80, w: 160, h: 160)
  if gameMap.endzone != ezColumn:
    ## Compact endzones ARE the base: the room is the zone's bounding box.
    let r = gameMap.endzoneRadius
    for team in gameMap.teams():
      let
        anchor = gameMap.teamAnchor(team)
        name = teamText(team)
      result.add Room(
        name: name[0].toUpperAscii() & name[1 .. ^1] & " Base",
        x: anchor.x - r, y: anchor.y - r, w: 2 * r, h: 2 * r
      )
    return
  case gameMap.layout
  of layoutSides:
    result.add Room(name: "Red Base", x: 0,
      y: gameMap.height div 2 - gameMap.spawnClearH,
      w: gameMap.captureClear, h: 2 * gameMap.spawnClearH)
    result.add Room(name: "Blue Base",
      x: gameMap.width - gameMap.captureClear,
      y: gameMap.height div 2 - gameMap.spawnClearH,
      w: gameMap.captureClear, h: 2 * gameMap.spawnClearH)
  of layoutCorners, layoutPlus:
    for team in gameMap.teams():
      let
        anchor = gameMap.teamAnchor(team)
        half = gameMap.spawnPocketHalf(team)
        name = teamText(team)
        ## Clamped to the board: on a RECTANGULAR quad-mirror map the
        ## pocket box can overhang the near edge (the protected floor is
        ## clipped by the border wall there anyway, identically for every
        ## team by reflection). Square rot90 boards never clip, so their
        ## rooms are byte-identical to before.
        x0 = max(0, anchor.x - half.w)
        y0 = max(0, anchor.y - half.h)
        x1 = min(gameMap.width, anchor.x + half.w)
        y1 = min(gameMap.height, anchor.y + half.h)
      result.add Room(
        name: name[0].toUpperAscii() & name[1 .. ^1] & " Base",
        x: x0,
        y: y0,
        w: x1 - x0,
        h: y1 - y0
      )

proc arenaCtfMap(): CtfMap =
  ## The default arena: the procedurally-defined symmetric 1235x659 map.
  result.name = ArenaName
  result.path = ArenaName
  result.width = 1235
  result.height = 659
  result.mapLayer = 0
  result.walkLayer = 1
  result.wallLayer = 2
  result.center = MapPoint(x: result.width div 2, y: result.height div 2)
  result.flagRing = 70
  result.captureClear = 210
  result.spawnClearW = 70
  result.spawnClearH = 130
  result.gunRange = GunRange
  result.leftObstacles = @ArenaLeftObstacles
  result.medKitSpawns = @[
    MapPoint(x: result.width div 2, y: result.height div 3),
    MapPoint(x: result.width div 2, y: 2 * result.height div 3),
  ]
  result.medKitCandidates = result.medKitSpawns
  result.rooms = result.defaultCtfRooms()
  result.validateMap()

proc arenaLargeCtfMap(): CtfMap =
  ## The arena-large map: 1606x858 (+30% both axes). Obstacles keep their
  ## `arena` sizes but sit spread out; the layout clearances scale with the
  ## field (the gun range does NOT — GV34, see GunRange).
  result.name = ArenaLargeName
  result.path = ArenaLargeName
  result.width = 1606
  result.height = 858
  result.mapLayer = 0
  result.walkLayer = 1
  result.wallLayer = 2
  result.center = MapPoint(x: result.width div 2, y: result.height div 2)
  result.flagRing = 91
  result.captureClear = 273
  result.spawnClearW = 91
  result.spawnClearH = 169
  result.gunRange = GunRange
  result.leftObstacles = @ArenaLargeLeftObstacles
  result.medKitSpawns = @[
    MapPoint(x: result.width div 2, y: result.height div 3),
    MapPoint(x: result.width div 2, y: 2 * result.height div 3),
  ]
  result.medKitCandidates = result.medKitSpawns
  result.rooms = result.defaultCtfRooms()
  result.validateMap()

proc captureZone*(gameMap: CtfMap, team: Team): CaptureZone =
  ## Returns one team's home capture zone. Sides maps keep the classic
  ## full-height home column unless the map draws a COMPACT endzone, which
  ## wraps the base in a disc or square instead; corner teams get a DIAGONAL
  ## zone (everything within an L1 radius of their map corner, its threshold
  ## a 45-degree line through the anchor); plus teams get an arm-mouth box
  ## past the anchor, bounded to the arm span — the open corners are
  ## battlefield.
  let
    anchor = gameMap.teamAnchor(team)
    half = CaptureZoneWidth div 2
    w = gameMap.width
    h = gameMap.height
  # Start from the full board and pull each bounded edge in to the anchor's
  # threshold; which edges are bounded is exactly what the layout decides.
  result = CaptureZone(xLo: 0, xHi: w - 1, yLo: 0, yHi: h - 1)
  if gameMap.endzone != ezColumn:
    ## A compact endzone is the anchor-centered box — which IS the square
    ## zone; the disc flag rounds its corners off. Every edge is an inner
    ## threshold, so the paint lines all four and a carrier scores from
    ## whichever side they reach.
    let r = gameMap.endzoneRadius
    result = CaptureZone(
      xLo: anchor.x - r, xHi: anchor.x + r,
      yLo: anchor.y - r, yHi: anchor.y + r,
      disc: gameMap.endzone == ezDisc,
      anchorX: anchor.x, anchorY: anchor.y, radius: r
    )
    return
  case gameMap.layout
  of layoutSides:
    if team == Red:
      result.xHi = anchor.x + half
    else:
      result.xLo = anchor.x - half
  of layoutCorners:
    ## The threshold edge is the 45-degree line through the anchor (plus
    ## half slack): everything within that L1 radius of the team's map
    ## corner scores. The box fields are its bounding box.
    result.diag = true
    result.cornerX = if anchor.x < gameMap.center.x: 0 else: w - 1
    result.cornerY = if anchor.y < gameMap.center.y: 0 else: h - 1
    result.diagLimit = abs(anchor.x - result.cornerX) +
      abs(anchor.y - result.cornerY) + half
    ## The inset-clamped respawn box must intersect the L1 region, or every
    ## respawn would silently fall back to the pedestal point.
    doAssert result.diagLimit >= 2 * (ArenaBorder + PlayerHalf) + 2,
      "degenerate diagonal capture zone"
    if anchor.x < gameMap.center.x:
      result.xHi = min(w - 1, result.diagLimit)
    else:
      result.xLo = max(0, w - 1 - result.diagLimit)
    if anchor.y < gameMap.center.y:
      result.yHi = min(h - 1, result.diagLimit)
    else:
      result.yLo = max(0, h - 1 - result.diagLimit)
  of layoutPlus:
    ## An arm-mouth box: past the anchor on the home axis, bounded to the
    ## arm span on the other (the corners are open field, not endzone).
    ## The cross-axis band is computed on the axis it actually spans, so a
    ## RECTANGULAR quad-mirror board centers the W/E mouths on the y axis
    ## and the N/S mouths on the x axis (identical on square boards).
    let
      bandY = gameMap.plusArmBandOn(h)
      bandX = gameMap.plusArmBandOn(w)
    case team
    of Red:
      result.xHi = anchor.x + half
      result.yLo = bandY.lo
      result.yHi = bandY.hi
    of Blue:
      result.xLo = anchor.x - half
      result.yLo = bandY.lo
      result.yHi = bandY.hi
    of Green:
      result.yHi = anchor.y + half
      result.xLo = bandX.lo
      result.xHi = bandX.hi
    of Yellow:
      result.yLo = anchor.y - half
      result.xLo = bandX.lo
      result.xHi = bandX.hi

proc inCaptureZone*(zone: CaptureZone, x, y: int): bool =
  ## Returns whether a map point sits inside one capture zone.
  if x < zone.xLo or x > zone.xHi or y < zone.yLo or y > zone.yHi:
    return false
  if zone.diag:
    return abs(x - zone.cornerX) + abs(y - zone.cornerY) <= zone.diagLimit
  if zone.disc:
    let
      dx = x - zone.anchorX
      dy = y - zone.anchorY
    return dx * dx + dy * dy <= zone.radius * zone.radius
  true

proc mirrorX*(rect: MapRect, width: int): MapRect =
  ## Mirrors one rectangle across the vertical center line of a width-px map.
  MapRect(x: width - rect.x - rect.w, y: rect.y, w: rect.w, h: rect.h)

proc mirrorX*(shape: ArenaShape, width: int): ArenaShape =
  ## Mirrors one arena shape across the vertical center line of a width-px map.
  case shape.kind
  of shapeRect:
    ArenaShape(kind: shapeRect, window: shape.window,
      rect: shape.rect.mirrorX(width))
  of shapeDisc:
    ArenaShape(
      kind: shapeDisc,
      window: shape.window,
      cx: width - 1 - shape.cx,
      cy: shape.cy,
      radius: shape.radius
    )
  of shapeDiamond:
    ArenaShape(
      kind: shapeDiamond,
      window: shape.window,
      cx: width - 1 - shape.cx,
      cy: shape.cy,
      radius: shape.radius
    )
  of shapeDiagonal:
    ArenaShape(
      kind: shapeDiagonal,
      window: shape.window,
      x0: width - 1 - shape.x0,
      y0: shape.y0,
      x1: width - 1 - shape.x1,
      y1: shape.y1,
      thickness: shape.thickness
    )
  of shapePolygon:
    var pts = newSeq[MapPoint](shape.points.len)
    for i, p in shape.points:
      pts[i] = MapPoint(x: width - 1 - p.x, y: p.y)
    ArenaShape(kind: shapePolygon, window: shape.window, points: pts)

proc mirrorY*(rect: MapRect, height: int): MapRect =
  ## Mirrors one rectangle across the horizontal center line of a height-px
  ## map — mirrorX with the axes swapped, exactly.
  MapRect(x: rect.x, y: height - rect.y - rect.h, w: rect.w, h: rect.h)

proc mirrorY*(shape: ArenaShape, height: int): ArenaShape =
  ## Mirrors one arena shape across the horizontal center line of a height-px
  ## map — mirrorX with x<->y and width<->height, transform for transform.
  case shape.kind
  of shapeRect:
    ArenaShape(kind: shapeRect, window: shape.window,
      rect: shape.rect.mirrorY(height))
  of shapeDisc:
    ArenaShape(
      kind: shapeDisc,
      window: shape.window,
      cx: shape.cx,
      cy: height - 1 - shape.cy,
      radius: shape.radius
    )
  of shapeDiamond:
    ArenaShape(
      kind: shapeDiamond,
      window: shape.window,
      cx: shape.cx,
      cy: height - 1 - shape.cy,
      radius: shape.radius
    )
  of shapeDiagonal:
    ArenaShape(
      kind: shapeDiagonal,
      window: shape.window,
      x0: shape.x0,
      y0: height - 1 - shape.y0,
      x1: shape.x1,
      y1: height - 1 - shape.y1,
      thickness: shape.thickness
    )
  of shapePolygon:
    var pts = newSeq[MapPoint](shape.points.len)
    for i, p in shape.points:
      pts[i] = MapPoint(x: p.x, y: height - 1 - p.y)
    ArenaShape(kind: shapePolygon, window: shape.window, points: pts)

proc `==`*(a, b: ArenaShape): bool =
  ## Field-wise equality (Nim derives no `==` for case objects); lets whole
  ## CtfMap values compare, which the map-spec round-trip tests rely on.
  if a.kind != b.kind or a.window != b.window:
    return false
  case a.kind
  of shapeRect:
    a.rect == b.rect
  of shapeDisc, shapeDiamond:
    a.cx == b.cx and a.cy == b.cy and a.radius == b.radius
  of shapeDiagonal:
    a.x0 == b.x0 and a.y0 == b.y0 and a.x1 == b.x1 and a.y1 == b.y1 and
      a.thickness == b.thickness
  of shapePolygon:
    a.points == b.points

proc rot180*(rect: MapRect, width, height: int): MapRect =
  ## Rotates one rectangle 180 degrees about the map center.
  MapRect(
    x: width - rect.x - rect.w,
    y: height - rect.y - rect.h,
    w: rect.w,
    h: rect.h
  )

proc rot180*(shape: ArenaShape, width, height: int): ArenaShape =
  ## Rotates one arena shape 180 degrees about the map center.
  case shape.kind
  of shapeRect:
    ArenaShape(kind: shapeRect, window: shape.window,
      rect: shape.rect.rot180(width, height))
  of shapeDisc:
    ArenaShape(
      kind: shapeDisc,
      window: shape.window,
      cx: width - 1 - shape.cx,
      cy: height - 1 - shape.cy,
      radius: shape.radius
    )
  of shapeDiamond:
    ArenaShape(
      kind: shapeDiamond,
      window: shape.window,
      cx: width - 1 - shape.cx,
      cy: height - 1 - shape.cy,
      radius: shape.radius
    )
  of shapeDiagonal:
    ArenaShape(
      kind: shapeDiagonal,
      window: shape.window,
      x0: width - 1 - shape.x0,
      y0: height - 1 - shape.y0,
      x1: width - 1 - shape.x1,
      y1: height - 1 - shape.y1,
      thickness: shape.thickness
    )
  of shapePolygon:
    var pts = newSeq[MapPoint](shape.points.len)
    for i, p in shape.points:
      pts[i] = MapPoint(x: width - 1 - p.x, y: height - 1 - p.y)
    ArenaShape(kind: shapePolygon, window: shape.window, points: pts)

proc rot90(rect: MapRect, side: int): MapRect =
  ## Rotates one rectangle 90 degrees clockwise about the center of a
  ## side x side square map: pixel (x, y) maps to (side - 1 - y, x).
  MapRect(
    x: side - rect.y - rect.h,
    y: rect.x,
    w: rect.h,
    h: rect.w
  )

proc rot90(shape: ArenaShape, side: int): ArenaShape =
  ## Rotates one arena shape 90 degrees clockwise about the center of a
  ## side x side square map. Applying it twice equals rot180, so the rot90
  ## quadrant replication is an exact 4-fold symmetry group. Diamonds and
  ## discs are rotation-invariant about their own centers, so only the
  ## centers move.
  case shape.kind
  of shapeRect:
    ArenaShape(kind: shapeRect, window: shape.window,
      rect: shape.rect.rot90(side))
  of shapeDisc:
    ArenaShape(
      kind: shapeDisc,
      window: shape.window,
      cx: side - 1 - shape.cy,
      cy: shape.cx,
      radius: shape.radius
    )
  of shapeDiamond:
    ArenaShape(
      kind: shapeDiamond,
      window: shape.window,
      cx: side - 1 - shape.cy,
      cy: shape.cx,
      radius: shape.radius
    )
  of shapeDiagonal:
    ArenaShape(
      kind: shapeDiagonal,
      window: shape.window,
      x0: side - 1 - shape.y0,
      y0: shape.x0,
      x1: side - 1 - shape.y1,
      y1: shape.x1,
      thickness: shape.thickness
    )
  of shapePolygon:
    var pts = newSeq[MapPoint](shape.points.len)
    for i, p in shape.points:
      pts[i] = MapPoint(x: side - 1 - p.y, y: p.x)
    ArenaShape(kind: shapePolygon, window: shape.window, points: pts)

proc mirrorX*(puddle: Puddle, width: int): Puddle =
  ## Mirrors one paint puddle across the vertical center line: each disc's
  ## center reflects, radii are untouched — membership transforms bit-exactly
  ## (a reflected distance is the same distance).
  for s in puddle.spots:
    result.spots.add PuddleSpot(cx: width - 1 - s.cx, cy: s.cy, r: s.r)

proc rot180*(puddle: Puddle, width, height: int): Puddle =
  ## Rotates one paint puddle 180 degrees about the map center; bit-exact
  ## like the mirror above.
  for s in puddle.spots:
    result.spots.add PuddleSpot(
      cx: width - 1 - s.cx, cy: height - 1 - s.cy, r: s.r)

proc inPuddle*(x, y: int, puddle: Puddle): bool =
  ## Returns true when map pixel (x, y) lies inside the puddle — inside ANY
  ## of its overlapping paint discs. Pure integer math.
  for s in puddle.spots:
    let
      dx = x - s.cx
      dy = y - s.cy
    if dx * dx + dy * dy <= s.r * s.r:
      return true
  false

proc puddleBounds*(puddle: Puddle): MapRect =
  ## The tight bounding box of the puddle's disc union.
  if puddle.spots.len == 0:
    return MapRect()
  var
    x0 = puddle.spots[0].cx - puddle.spots[0].r
    y0 = puddle.spots[0].cy - puddle.spots[0].r
    x1 = puddle.spots[0].cx + puddle.spots[0].r
    y1 = puddle.spots[0].cy + puddle.spots[0].r
  for s in puddle.spots:
    x0 = min(x0, s.cx - s.r)
    y0 = min(y0, s.cy - s.r)
    x1 = max(x1, s.cx + s.r)
    y1 = max(y1, s.cy + s.r)
  MapRect(x: x0, y: y0, w: x1 - x0 + 1, h: y1 - y0 + 1)

proc symmetryImages*(gameMap: CtfMap, rect: MapRect): seq[MapRect] =
  ## Returns one rectangle's full orbit under the map's own symmetry,
  ## original first. Images are deduplicated after applying the canonical
  ## integer transforms: that handles center-straddling rectangles on even
  ## boards, as well as the one- and two-member rot90 orbits, without
  ## re-deriving the half-pixel rotation axis.
  result.add rect
  case gameMap.symmetry
  of symNone:
    discard   # no symmetry group: the orbit is the rect itself (already added)
  of symMirror:
    let image = rect.mirrorX(gameMap.width)
    if image notin result:
      result.add image
  of symRot180:
    let image = rect.rot180(gameMap.width, gameMap.height)
    if image notin result:
      result.add image
  of symRot90:
    var image = rect
    for _ in 0 ..< 3:
      image = image.rot90(gameMap.width)
      if image notin result:
        result.add image
  of symQuadMirror:
    for image in [rect.mirrorX(gameMap.width),
        rect.mirrorY(gameMap.height),
        rect.rot180(gameMap.width, gameMap.height)]:
      if image notin result:
        result.add image

proc symmetryImages*(gameMap: CtfMap, point: MapPoint): seq[MapPoint] =
  ## Returns one point's full orbit under the map's own symmetry, original
  ## first. Two-team images go through teamImagePoint so pickups authored by
  ## the editor cannot regress to mirroring on rot180 terrain; rot90 images
  ## walk the same exact quarter-turn orbit as team-owned sim geometry.
  result.add point
  case gameMap.symmetry
  of symNone:
    discard   # no symmetry group: a point's orbit is itself (already added)
  of symMirror, symRot180:
    let image = gameMap.teamImagePoint(point, Blue)
    if image notin result:
      result.add image
  of symRot90:
    var image = point
    for _ in 0 ..< 3:
      image = image.rot90Point(gameMap.width)
      if image notin result:
        result.add image
  of symQuadMirror:
    ## The pure Klein-four orbit: mirrorX, mirrorY and their composition.
    ## (Team-OWNED geometry goes through teamImagePoint/teamAnchor instead,
    ## where the plus layout's two-seed convention lives.)
    for image in [
        MapPoint(x: gameMap.width - 1 - point.x, y: point.y),
        MapPoint(x: point.x, y: gameMap.height - 1 - point.y),
        MapPoint(
          x: gameMap.width - 1 - point.x, y: gameMap.height - 1 - point.y)]:
      if image notin result:
        result.add image

proc inRect*(x, y: int, rect: MapRect): bool =
  ## Returns true when (x, y) lies inside the rectangle.
  x >= rect.x and x < rect.x + rect.w and
    y >= rect.y and y < rect.y + rect.h

proc pointInPolygon*(x, y: int, pts: seq[MapPoint]): bool =
  ## Integer even-odd point-in-polygon over a closed ring, evaluated by a
  ## LEFT/RIGHT crossing count that is REFLECTION-SYMMETRIC under the map's
  ## mirror (x -> w-1-x) and rot180 (x,y -> w-1-x, h-1-y) — the team-fairness
  ## invariant. See the crossing loop below for the mechanism; the short version
  ## is that counting crossings on both sides and taking "odd on either" is
  ## symmetric in left<->right, whereas the older single strict-`<` count was a
  ## left-inclusive top-left fill that reflection flipped at every boundary
  ## pixel. An edge is counted only on a STRICT straddle (`ylo < y < yhi`), so a
  ## vertex-touch is skipped identically on both sides. int64 throughout: cross
  ## products of map-scale coords overflow int32 on wasm.
  ## NOTE (honest bound): interior pixels and axis-aligned/vertical boundaries
  ## are now bit-for-bit identical to their mirror. A SLANTED edge whose exact
  ## scan-line crossing falls at a half-integer can still round to opposite
  ## pixels on the two sides — a 1px boundary sliver, never interior (measured:
  ## banked maps drop from ~4-5% self-residual to <0.05%, all edge-adjacent).
  ## Eliminating those entirely needs sub-pixel geometry; tracked separately.
  if pts.len < 3:
    return false
  var
    minx = pts[0].x
    maxx = pts[0].x
    miny = pts[0].y
    maxy = pts[0].y
  for p in pts:
    minx = min(minx, p.x); maxx = max(maxx, p.x)
    miny = min(miny, p.y); maxy = max(maxy, p.y)
  if x < minx or x > maxx or y < miny or y > maxy:
    return false
  var
    inside = false
    j = pts.len - 1
  # Count crossings STRICTLY LEFT and STRICTLY RIGHT of the sample separately;
  # inside iff EITHER count is odd. This is exactly reflection-symmetric under the
  # map's x-mirror (x -> W-1-x) and rot180: the reflection swaps "left" and
  # "right", and "odd on either side" is symmetric in the two, so a polygon and
  # its mirror image rasterize bit-for-bit identically at every INTERIOR pixel
  # and every axis-aligned/vertical boundary (which the plain strict-`<` rule —
  # a left-inclusive top-left fill — did NOT: it included the left boundary and
  # excluded the right, so reflection flipped every boundary pixel; measured on
  # the banked maps as 27,454 px (mesa) / 40,492 px (carve) self-residual, all in
  # the mirrored entrance bands). A pixel exactly ON an edge (lhs == rhs) is
  # counted as NEITHER strictly-left nor strictly-right, so the two counts
  # disagree there and it reads inside (wall) — a wall boundary is a wall from
  # both sides, which is both collision-correct and symmetric. int64 throughout
  # (map-scale cross products overflow int32 on wasm).
  var
    leftCross = 0
    rightCross = 0
  for i in 0 ..< pts.len:
    let
      xi = pts[i].x
      yi = pts[i].y
      xj = pts[j].x
      yj = pts[j].y
      ylo = min(yi, yj)
      yhi = max(yi, yj)
    if y > ylo and y < yhi:
      let
        dyv = int64(yj - yi)          # strict straddle => dyv != 0
        lhs = int64(x - xi) * dyv
        rhs = int64(xj - xi) * int64(y - yi)
      if (if dyv > 0: lhs < rhs else: lhs > rhs):
        inc leftCross                 # edge crosses the scan line to the LEFT of x
      elif (if dyv > 0: lhs > rhs else: lhs < rhs):
        inc rightCross                # ... to the RIGHT of x  (lhs == rhs => on edge, neither)
    j = i
  (leftCross and 1) == 1 or (rightCross and 1) == 1

proc inShape*(x, y: int, shape: ArenaShape): bool =
  ## Returns true when (x, y) lies inside one arena shape.
  case shape.kind
  of shapeRect:
    inRect(x, y, shape.rect)
  of shapeDisc:
    let
      dx = x - shape.cx
      dy = y - shape.cy
    dx * dx + dy * dy <= shape.radius * shape.radius
  of shapeDiamond:
    abs(x - shape.cx) + abs(y - shape.cy) <= shape.radius
  of shapePolygon:
    pointInPolygon(x, y, shape.points)
  of shapeDiagonal:
    ## Bounding-box rejection first, then point-to-segment distance in
    ## integers: (x, y) is inside when its distance to the segment is at
    ## most half the wall thickness.
    let half = shape.thickness div 2 + 1
    if x < min(shape.x0, shape.x1) - half or
        x > max(shape.x0, shape.x1) + half or
        y < min(shape.y0, shape.y1) - half or
        y > max(shape.y0, shape.y1) + half:
      false
    else:
      # 64-bit throughout: dx*dx + dy*dy reaches ~2.2e9 for these segments,
      # past int32 max, so on a 32-bit target (wasm) the plain-int form would
      # overflow. int64 is exact on every target and the comparison is unchanged.
      let
        vx = int64(shape.x1 - shape.x0)
        vy = int64(shape.y1 - shape.y0)
        wx = int64(x - shape.x0)
        wy = int64(y - shape.y0)
        len2 = vx * vx + vy * vy
        t = clamp(wx * vx + wy * vy, 0'i64, len2)
        dx = wx * len2 - t * vx
        dy = wy * len2 - t * vy
      dx * dx + dy * dy <=
        int64(shape.thickness) * int64(shape.thickness) * len2 * len2 div 4

proc buildArenaObstacles*(gameMap: CtfMap): seq[ArenaShape] =
  ## The full obstacle set: every seed shape plus its image(s) under the
  ## map's symmetry (x-mirror or 180° rotation of the left half; 90/180/270°
  ## rotations of the quadrant on rot90 maps; both reflections and rot180 of
  ## the quadrant on quad-mirror maps), precomputed once per map selection so
  ## the per-pixel wall test never re-mirrors.
  ##
  ## Under symNone (coworld-ctf#280) there is no fundamental domain: the
  ## authored `leftObstacles` set IS the whole board, taken VERBATIM with no
  ## image added. `leftObstacles` keeps its name (flatty positional wire compat
  ## — renaming the field would shift the keyframe layout); under symNone read
  ## it as "the full authored obstacle set".
  for shape in gameMap.leftObstacles:
    result.add shape
    case gameMap.symmetry
    of symNone:
      discard   # full board authored verbatim — no lift, no image
    of symMirror:
      result.add shape.mirrorX(gameMap.width)
    of symRot180:
      result.add shape.rot180(gameMap.width, gameMap.height)
    of symRot90:
      let quarter = shape.rot90(gameMap.width)
      result.add quarter
      result.add shape.rot180(gameMap.width, gameMap.height)
      result.add quarter.rot180(gameMap.width, gameMap.height)
    of symQuadMirror:
      result.add shape.mirrorX(gameMap.width)
      result.add shape.mirrorY(gameMap.height)
      result.add shape.rot180(gameMap.width, gameMap.height)

## Spinning-diamond geometry lives up here, ahead of mapWallAt, because
## the terrain validator has to reason about the whole turn.

const
  DiamondSpinFrames* = 16      ## steps across 90° (a diamond is 4-fold symmetric).
  DiamondSpinTicksPerFrame* = 4  ## ~2.7s per quarter turn at 24 ticks/s.
  DiamondRotShift = 16         ## fixed-point fraction bits of the spin table.
  DiamondRotOne = 1'i64 shl DiamondRotShift
  ## cos(frame * 5.625°), scaled by 2^16. Geometry must not use host libm.
  ## sin(frame) is the same table read from the other end.
  DiamondCos: array[DiamondSpinFrames + 1, int64] = [
    65536'i64, 65220'i64, 64277'i64, 62714'i64, 60547'i64,
    57798'i64, 54491'i64, 50660'i64, 46341'i64, 41576'i64,
    36410'i64, 30893'i64, 25080'i64, 19024'i64, 12785'i64,
    6424'i64, 0'i64
  ]

proc diamondFrameIndex*(frame: int): int {.inline.} =
  ## Wraps any signed frame counter into 0 ..< DiamondSpinFrames.
  ((frame mod DiamondSpinFrames) + DiamondSpinFrames) mod DiamondSpinFrames


proc rotatedDiamondCovers*(
  radius, frame, dxNum, dyNum, denom: int
): bool =
  ## Integer rotated-L1 membership: is the offset (dxNum/denom, dyNum/denom)
  ## map pixels from a diamond's center inside it at `frame`? Keeping the
  ## division symbolic lets the collision masks (denom = 2) and the scale× art
  ## rasterizer (denom = 2·scale) share ONE predicate, so the drawn silhouette
  ## and the geometry cannot drift apart.
  ##
  ## Both samplers measure from the diamond's center pixel, NOT from pixel
  ## centers half a pixel to its right. Under the x-mirror (x -> width-1-x)
  ## a +0.5 offset does not flip sign, so a half-pixel sample would make each
  ## diamond's footprint the mirror of its twin's translated by one pixel —
  ## the arena's obstacle union is exactly mirror-symmetric and team fairness
  ## rests on it. On integer offsets the mirror is exact. As a bonus, frame 0
  ## then reproduces the plain |dx| + |dy| <= r diamond that
  ## isAnimatedDiamondPixel bakes the hole for.
  let
    index = diamondFrameIndex(frame)
    ca = DiamondCos[index]
    sa = DiamondCos[DiamondSpinFrames - index]
    rx = int64(dxNum) * ca + int64(dyNum) * sa
    ry = -int64(dxNum) * sa + int64(dyNum) * ca
  abs(rx) + abs(ry) <= int64(radius) * int64(denom) * DiamondRotOne

const DiamondSpinBand = 80
  ## Half-width, in map pixels, of the center column whose diamonds spin.

type SpinFootprint* = enum
  ## Which shape a spinning diamond presents to an offline (uninstalled-map)
  ## wall test. Live play always uses the exact per-frame silhouette; these
  ## are for validation, which must hold across the WHOLE turn and so needs
  ## the bound that points the right way for each invariant.
  spinRest       ## the resting diamond, i.e. what the art bake carves out.
  spinSwept      ## union over the turn: nothing outside this is ever stone.
  spinAlways     ## intersection over the turn: this is stone at every frame.

proc nearSpinAxis(center, span: int): bool {.inline.} =
  ## Is a shape centered at `center` inside the spin band of an axis `span`
  ## pixels long? Measured against the SYMMETRY AXIS at (span - 1)/2, not
  ## against the map's center pixel: on an even span the two differ by half a
  ## pixel, and a diamond whose image fell on the other side of the threshold
  ## would spin while its twin stayed baked stone. Doubling both sides keeps
  ## the comparison exact in integers.
  abs(2 * center - (span - 1)) < 2 * DiamondSpinBand

proc isSpinningDiamond*(gameMap: CtfMap, shape: ArenaShape): bool {.inline.} =
  ## The diamonds flanking the center of the field are the ones drawn — and,
  ## since GV28, COLLIDED — as spinning stone.
  ##
  ## The selected set must be CLOSED under the map's symmetry group, or one
  ## team gets rotating cover where another gets solid stone. The authored
  ## rule is a vertical band down the center column; that band is already
  ## closed under the mirror and under 180° rotation, since both preserve
  ## distance from the vertical axis. It is NOT closed under 90° rotation,
  ## which maps it to a horizontal band — so on rot90 (4-team) maps the set is
  ## the band's own closure: the union of the vertical and horizontal bands, a
  ## cross through the center. The arena is unaffected either way; it selects
  ## the same eight diamonds it always has.
  if shape.kind != shapeDiamond:
    return false
  case gameMap.symmetry
  of symMirror, symRot180, symNone:
    ## symNone is 2-team full-board (sides layout): the spinning set is the
    ## vertical center-band, same rule as mirror/rot180 — it is closed under
    ## nothing (no group) but the band is authored directly and the sim treats
    ## a center-band diamond identically regardless of how the board was built.
    nearSpinAxis(shape.cx, gameMap.width)
  of symRot90, symQuadMirror:
    ## Both 4-team symmetries use the cross through the center. rot90 MUST:
    ## the quarter turn maps the vertical band to the horizontal one, so the
    ## cross is the band's closure. Quad-mirror's reflections preserve each
    ## band separately, but the N/S teams' center approach runs through the
    ## horizontal band exactly as the W/E teams' runs through the vertical
    ## one — 4-team boards spin the whole cross so no lane class meets only
    ## baked stone.
    nearSpinAxis(shape.cx, gameMap.width) or
      nearSpinAxis(shape.cy, gameMap.height)

proc buildAnimatedDiamonds*(
  gameMap: CtfMap, obstacles: seq[ArenaShape]
): seq[tuple[cx, cy, radius: int]] =
  ## The eight diamonds flanking the center of the field (column 5 and its
  ## x-mirror): drawn as slowly rotating sprites instead of baked wall art.
  ## Since GV28 the rotation is REAL: the bake leaves them out of every
  ## collision layer and the sim stamps the live rotated footprint into the
  ## movement, bullet, and vision masks as the frame advances
  ## (applyDiamondGeometry).
  for shape in obstacles:
    if gameMap.isSpinningDiamond(shape):
      result.add((shape.cx, shape.cy, shape.radius))


## ---------------------------------------------------------------------------
## Procedural terrain (GameVersion 25). Canonical play draws a validated map
## from the curated pool (map_pool.nim); mapPath "gen" generates straight from
## a seed. Every layout is authored for the LEFT half only and completed by
## the map's symmetry, so team fairness is structural. The generator is fully
## deterministic (own splitmix64, never std/random) so one seed names one map
## on every platform, including wasm.
## ---------------------------------------------------------------------------

const
  GenMapName* = "gen"
  PoolMapName* = "pool"
  MinCorridorWidth = 26      ## narrowest corridor for the 13px footprint.
  MapGenMaxAttempts = 100
  MapSizeNames = ["small", "standard", "large", "huge", "giant"]
  CenterFeatureNames = ["bracket", "ring", "walls"]
  ## Interior cover budget, in permille of the non-protected interior that is
  ## obstacle wall. The hand-tuned arena sits inside this band; layouts
  ## outside it play too open or too clogged and are re-rolled. Public so
  ## tooling can report a measured figure against the band it is judged by
  ## rather than restating the numbers.
  CoverPermilleMin* = 40
  CoverPermilleMax* = 170

type
  MapRng = object
    state: uint64

  ColumnFamily = enum
    colStubs        ## 18px-wide rect stubs, border-anchored at the ends.
    colDiamonds
    colDiscs
    colChevrons     ## 45-degree zigzag wall segments.

proc next(rng: var MapRng): uint64 =
  ## splitmix64: tiny, statistically solid, identical on every target.
  rng.state = rng.state + 0x9E3779B97F4A7C15'u64
  var z = rng.state
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

proc pick(rng: var MapRng, bound: int): int =
  ## Uniform 0..bound-1 (modulo bias is immaterial at these bounds).
  int(rng.next() mod uint64(bound))

proc pickRange(rng: var MapRng, lo, hi: int): int =
  lo + rng.pick(hi - lo + 1)

proc coin(rng: var MapRng): bool =
  (rng.next() and 1'u64) == 1

proc shuffle[T](rng: var MapRng, items: var seq[T]) =
  for i in countdown(items.high, 1):
    let j = rng.pick(i + 1)
    swap(items[i], items[j])

const
  PuddleMaxRadiusPx* = 45       ## hard bound on a puddle pixel's distance
                                ## from the splat's anchor: the widest lobe
                                ## offset (20) plus the largest lobe radius
                                ## (24), or the core disc's 30 — rounded up.
                                ## Placement margins and tests lean on this.

proc puddleSplatAt(rng: var MapRng, cx, cy: int): Puddle =
  ## An organic paint splat anchored at (cx, cy): one core disc under 2..4
  ## smaller lobes flung a short way off-center, all drawn from the map rng.
  ## Overlapping discs make the classic spill silhouette — bulges and
  ## pinches, never a square. A splat's symmetry image comes from the
  ## engine's own Puddle transforms, so a placed pair is exactly team-fair.
  result.spots.add PuddleSpot(cx: cx, cy: cy, r: rng.pickRange(26, 30))
  let lobes = rng.pickRange(2, 4)
  for _ in 0 ..< lobes:
    let
      dist = rng.pickRange(10, 20)
      angle = float(rng.pick(3600)) * PI / 1800.0
    result.spots.add PuddleSpot(
      cx: cx + int(round(float(dist) * cos(angle))),
      cy: cy + int(round(float(dist) * sin(angle))),
      r: rng.pickRange(14, 24)
    )

proc centerPuddleSplat(rng: var MapRng, gameMap: CtfMap): Puddle =
  ## The odd-count CENTER puddle. Exact self-symmetry by construction: draw
  ## half the discs freely near the center, then union them with their own
  ## engine-transform images — the disc set then maps to itself under the
  ## map's symmetry, the splat analogue of the rect center pit's
  ## width-x-w self-image. (A disc dead on the center pairs with a twin one
  ## pixel over; the two melt into one core visually.)
  let
    cx = gameMap.center.x
    cy = gameMap.center.y
  var half: Puddle
  half.spots.add PuddleSpot(
    cx: cx - rng.pickRange(2, 8),
    cy: cy + rng.pickRange(-6, 6),
    r: rng.pickRange(22, 27)
  )
  for _ in 0 ..< 2:
    let
      dist = rng.pickRange(8, 18)
      angle = float(rng.pick(3600)) * PI / 1800.0
    half.spots.add PuddleSpot(
      cx: cx + int(round(float(dist) * cos(angle))),
      cy: cy + int(round(float(dist) * sin(angle))),
      r: rng.pickRange(13, 19)
    )
  let image =
    case gameMap.symmetry
    of symMirror: half.mirrorX(gameMap.width)
    of symRot180: half.rot180(gameMap.width, gameMap.height)
    of symRot90, symQuadMirror:
      raiseAssert "puddles never place on 4-team maps"
    of symNone:
      ## Full-board: no mirror image — the generated spots already cover the
      ## whole board (this half IS the board). Empty image = verbatim.
      Puddle(spots: @[])
  result = half
  for s in image.spots:
    result.spots.add s

proc mapSizeScale(sizeName: string): float =
  ## Field-scale factor for one size class. The two OVERSIZE classes are
  ## newer than the original three: "giant" doubles the old "large" ceiling
  ## (1.3 -> 2.6), twice the map on each axis.
  case sizeName
  of "small": 0.85
  of "standard": 1.0
  of "large": 1.3
  of "huge": 1.8
  of "giant": 2.6
  of "colossal": 5.2  ## override-only (not in MapSizeNames): 2x giant.
  else:
    raise newException(CtfError, "Unknown map size: " & sizeName)

proc scaledGenShell(sizeName: string): CtfMap =
  ## Field dimensions and clearances for one size class: the standard-arena
  ## numbers scaled by the class factor. Obstacle SIZES never scale — bigger
  ## fields get roomier corridors, exactly like arena-large.
  let scale = mapSizeScale(sizeName)
  proc s(value: int): int = int(round(float(value) * scale))
  result.width = s(1235)
  result.height = s(659)
  result.mapLayer = 0
  result.walkLayer = 1
  result.wallLayer = 2
  result.center = MapPoint(x: result.width div 2, y: result.height div 2)
  result.flagRing = s(70)
  result.captureClear = s(210)
  result.spawnClearW = s(70)
  result.spawnClearH = s(130)
  result.gunRange = GunRange  # fixed, never scaled with the field (GV34).

proc endzoneFloorAt*(
  x, y, anchorX, anchorY, radius: int, disc: bool
): bool =
  ## Whether a point sits on one COMPACT endzone's protected floor: the
  ## scoring shape grown by the wall margin, so the ring the carrier crosses
  ## is never flush against a wall.
  let
    grown = radius + EndzoneWallMargin
    dx = abs(x - anchorX)
    dy = abs(y - anchorY)
  if dx > grown or dy > grown:
    return false
  if disc:
    return dx * dx + dy * dy <= grown * grown
  true

proc centerOffset2*(
  gameMap: CtfMap, x, y: int
): tuple[dx, dy: int] {.inline.} =
  ## TWICE the offset of (x, y) from the map's symmetry center. Doubling is
  ## what lets a 4-team board measure against its true axes at ((w-1)/2,
  ## (h-1)/2): on an even side those axes are a half pixel off the
  ## div-derived `center`, so a radius or band measured from `center` is not
  ## its own quarter turn (rot90) or its own reflection (quad-mirror).
  ## Mirror and rot180 maps keep the historical integer center exactly —
  ## every comparison below is the old one scaled by 4, so 2-team terrain is
  ## bit-identical.
  if gameMap.symmetry in {symRot90, symQuadMirror}:
    (2 * x - (gameMap.width - 1), 2 * y - (gameMap.height - 1))
  else:
    (2 * (x - gameMap.center.x), 2 * (y - gameMap.center.y))

proc mapProtectedFloorAt*(gameMap: CtfMap, x, y: int): bool =
  ## isProtectedFloor for a map that is NOT installed as the process map:
  ## the generator and validators run on candidates before any selection.
  if gameMap.endzone != ezColumn:
    ## COMPACT endzones protect the shape around each base and NOTHING at
    ## the border: the home strip is wilderness the terrain may build on.
    for team in gameMap.teams():
      let anchor = gameMap.teamAnchor(team)
      if endzoneFloorAt(x, y, anchor.x, anchor.y, gameMap.endzoneRadius,
          gameMap.endzone == ezDisc):
        return true
    let
      dcx = x - gameMap.center.x
      dcy = y - gameMap.center.y
    return dcx * dcx + dcy * dcy <= gameMap.flagRing * gameMap.flagRing
  let
    clear = gameMap.captureClear
    nearX = x < clear or x >= gameMap.width - clear
    nearY = y < clear or y >= gameMap.height - clear
    (dx2, dy2) = gameMap.centerOffset2(x, y)
    approach =
      case gameMap.layout
      of layoutSides:
        nearX
      of layoutCorners:
        nearX and nearY
      of layoutPlus:
        (nearX and abs(dy2) <= 2 * gameMap.plusArmHalf()) or
          (nearY and abs(dx2) <= 2 * gameMap.plusArmHalf())
  if approach:
    return true
  if dx2 * dx2 + dy2 * dy2 <= 4 * gameMap.flagRing * gameMap.flagRing:
    return true
  for team in gameMap.teams():
    let
      anchor = gameMap.teamAnchor(team)
      half = gameMap.spawnPocketHalf(team)
    if abs(x - anchor.x) <= half.w and abs(y - anchor.y) <= half.h:
      return true
  false

proc mapWallAt*(
  gameMap: CtfMap,
  obstacles: seq[ArenaShape],
  x, y: int,
  includeSpinning = true,
  spin = spinRest
): bool =
  ## Uninstalled-map wall test, matching isArenaWall's border + carve rules.
  ## `includeSpinning = false` drops the live diamonds, which is what the art
  ## bake needs to see under them; `spin` picks which bound of the turn a
  ## spinning diamond presents, for validation that must hold at every frame.
  if x < ArenaBorder or y < ArenaBorder or
      x >= gameMap.width - ArenaBorder or y >= gameMap.height - ArenaBorder:
    return true
  if mapProtectedFloorAt(gameMap, x, y):
    return false
  for shape in obstacles:
    if gameMap.isSpinningDiamond(shape):
      if not includeSpinning:
        continue
      if spin != spinRest:
        let
          dx = x - shape.cx
          dy = y - shape.cy
          d2 = dx * dx + dy * dy
          r2 = shape.radius * shape.radius
        ## Two cheap circles bracket the answer: nothing outside the
        ## circumradius is ever stone, everything inside the inradius
        ## (2*d2 <= r2) is stone at every frame. Only the annulus between them
        ## depends on the angle, and there the sixteen frames are walked for
        ## real — the true intersection is a rosette strictly larger than the
        ## inscribed disc, and approximating it by that disc would reject maps
        ## whose lane is in fact blocked at every frame.
        if d2 > r2:
          continue
        if 2 * d2 <= r2:
          return true
        var everStone, alwaysStone = false
        alwaysStone = true
        for frame in 0 ..< DiamondSpinFrames:
          if rotatedDiamondCovers(shape.radius, frame, 2 * dx, 2 * dy, 2):
            everStone = true
          else:
            alwaysStone = false
        if (if spin == spinSwept: everStone else: alwaysStone):
          return true
        continue
    if inShape(x, y, shape):
      return true
  false

proc validateMapWalkability*(gameMap: CtfMap) =
  ## coworld-ctf#280 WALL-OVERLAP check for symNone explicit pickups. Separate
  ## from validateMap because it needs buildArenaObstacles/mapWallAt (defined
  ## above here, below validateMap). Called from mapFromSpecJson right after
  ## validateMap. A symmetric map's pickups are nudged to nearest-walkable at
  ## spawn and are orbit-fair by construction; a symNone pickup is authored RAW,
  ## so a point inside an obstacle would load fine and be unreachable. Reject
  ## any pickup that is a WALL (the engine's own uninstalled predicate: border +
  ## obstacle test, spinning excluded). This is the wall-overlap minimum the
  ## brief requires; a full flood-connectivity check is the caller's fairness
  ## gate (too heavy for load-time).
  if gameMap.symmetry != symNone:
    return
  let obstacles = buildArenaObstacles(gameMap)
  for (name, pts) in [
      ("teamPickups.shields", gameMap.teamPickups.shields),
      ("teamPickups.cans", gameMap.teamPickups.cans),
      ("teamPickups.barriers", gameMap.teamPickups.barriers)]:
    for i, p in pts:
      if mapWallAt(gameMap, obstacles, p.x, p.y, includeSpinning = false):
        raise newException(CtfError,
          name & "[" & $i & "] at (" & $p.x & "," & $p.y & ") is inside an " &
          "obstacle/border (unwalkable). symNone pickups are authored raw " &
          "(not nudged), so they must land on open floor.")

proc shapeBounds*(shape: ArenaShape): tuple[x0, y0, x1, y1: int] =
  ## Inclusive bounding box of one shape's membership: no pixel outside it
  ## can pass inShape. Diagonals reuse inShape's own rejection half-width, so
  ## the two can never disagree about where a segment's influence ends.
  case shape.kind
  of shapeRect:
    (shape.rect.x, shape.rect.y,
      shape.rect.x + shape.rect.w - 1, shape.rect.y + shape.rect.h - 1)
  of shapeDisc, shapeDiamond:
    (shape.cx - shape.radius, shape.cy - shape.radius,
      shape.cx + shape.radius, shape.cy + shape.radius)
  of shapeDiagonal:
    let half = shape.thickness div 2 + 1
    (min(shape.x0, shape.x1) - half, min(shape.y0, shape.y1) - half,
      max(shape.x0, shape.x1) + half, max(shape.y0, shape.y1) + half)
  of shapePolygon:
    if shape.points.len == 0:
      (0, 0, -1, -1)
    else:
      var
        x0 = shape.points[0].x
        y0 = shape.points[0].y
        x1 = shape.points[0].x
        y1 = shape.points[0].y
      for p in shape.points:
        x0 = min(x0, p.x); y0 = min(y0, p.y)
        x1 = max(x1, p.x); y1 = max(y1, p.y)
      (x0, y0, x1, y1)

proc rasterizeWallMasks*(
  gameMap: CtfMap, obstacles: seq[ArenaShape]
): tuple[maxWall, minWall: seq[bool]] =
  ## mapWallAt(spin = spinSwept) and mapWallAt(spin = spinAlways) for EVERY
  ## pixel at once, bit-identical to querying them one pixel at a time.
  ## mapWallAt scans the whole shape list per query, so a full-board sweep is
  ## area x shapes — billions of shape tests on an oversize board. Painting
  ## each shape over its own bounding box instead costs area + the sum of the
  ## box areas, and protected floor is only consulted where a shape actually
  ## covers. (A spinning diamond's swept rosette stays inside its circumradius
  ## — rotation preserves L2 and L1 >= L2 — so the resting bbox bounds every
  ## frame.)
  let
    w = gameMap.width
    h = gameMap.height
  var
    maxWall = newSeq[bool](w * h)
    minWall = newSeq[bool](w * h)
  for shape in obstacles:
    let
      bounds = shapeBounds(shape)
      x0 = max(bounds.x0, 0)
      y0 = max(bounds.y0, 0)
      x1 = min(bounds.x1, w - 1)
      y1 = min(bounds.y1, h - 1)
    if gameMap.isSpinningDiamond(shape):
      ## The same circumradius/inradius bracket as mapWallAt: only the
      ## annulus between them walks the sixteen frames.
      let r2 = shape.radius * shape.radius
      for y in y0 .. y1:
        for x in x0 .. x1:
          let
            dx = x - shape.cx
            dy = y - shape.cy
            d2 = dx * dx + dy * dy
          if d2 > r2:
            continue
          let i = y * w + x
          if 2 * d2 <= r2:
            maxWall[i] = true
            minWall[i] = true
            continue
          var everStone = false
          var alwaysStone = true
          for frame in 0 ..< DiamondSpinFrames:
            if rotatedDiamondCovers(shape.radius, frame, 2 * dx, 2 * dy, 2):
              everStone = true
            else:
              alwaysStone = false
          if everStone:
            maxWall[i] = true
          if alwaysStone:
            minWall[i] = true
    else:
      for y in y0 .. y1:
        for x in x0 .. x1:
          if inShape(x, y, shape):
            let i = y * w + x
            maxWall[i] = true
            minWall[i] = true
  ## Border and protected floor, in mapWallAt's precedence: the border ring
  ## is wall unconditionally, protected floor is floor no matter what shape
  ## covers it.
  for y in 0 ..< h:
    let onYBorder = y < ArenaBorder or y >= h - ArenaBorder
    for x in 0 ..< w:
      let i = y * w + x
      if onYBorder or x < ArenaBorder or x >= w - ArenaBorder:
        maxWall[i] = true
        minWall[i] = true
      elif maxWall[i] and mapProtectedFloorAt(gameMap, x, y):
        maxWall[i] = false
        minWall[i] = false
  (maxWall, minWall)

proc rasterizeRestWallMask*(
  gameMap: CtfMap,
  obstacles: seq[ArenaShape],
  protectedAt: proc (x, y: int): bool,
  includeSpinning = true
): seq[bool] =
  ## isArenaWall / mapWallAt(spin = spinRest) for every pixel at once — the
  ## bake-time twin of rasterizeWallMasks, painting resting silhouettes over
  ## their bounding boxes instead of scanning every shape per pixel.
  ## includeSpinning = false is mapWallAt's includeSpinning = false: the
  ## spinning diamonds stay out because the bake stamps their live rotation
  ## per frame. The protected-floor rule is a parameter because the installed
  ## map answers it from the Arena globals (isProtectedFloor) while an
  ## uninstalled candidate answers from the map itself (mapProtectedFloorAt);
  ## the caller passes whichever matches the per-pixel predicate it replaces.
  let
    w = gameMap.width
    h = gameMap.height
  result = newSeq[bool](w * h)
  for shape in obstacles:
    if not includeSpinning and gameMap.isSpinningDiamond(shape):
      continue
    let
      bounds = shapeBounds(shape)
      x0 = max(bounds.x0, 0)
      y0 = max(bounds.y0, 0)
      x1 = min(bounds.x1, w - 1)
      y1 = min(bounds.y1, h - 1)
    for y in y0 .. y1:
      for x in x0 .. x1:
        if inShape(x, y, shape):
          result[y * w + x] = true
  for y in 0 ..< h:
    let onYBorder = y < ArenaBorder or y >= h - ArenaBorder
    for x in 0 ..< w:
      let i = y * w + x
      if onYBorder or x < ArenaBorder or x >= w - ArenaBorder:
        result[i] = true
      elif result[i] and protectedAt(x, y):
        result[i] = false

proc scaledGenShell4(sizeName: string): CtfMap =
  ## The 4-team field shell: a SQUARE board (rot90 symmetry needs one) with
  ## the standard clearances scaled by the same class factors as the 2-team
  ## shell. The standard side (960) splits the difference between the
  ## classic arena's width and height so the fight density stays familiar.
  let scale = mapSizeScale(sizeName)
  proc s(value: int): int = int(round(float(value) * scale))
  result.width = s(960)
  result.height = s(960)
  result.mapLayer = 0
  result.walkLayer = 1
  result.wallLayer = 2
  result.center = MapPoint(x: result.width div 2, y: result.height div 2)
  result.flagRing = s(70)
  result.captureClear = s(210)
  result.spawnClearW = s(70)
  result.spawnClearH = s(130)
  result.gunRange = GunRange  # fixed, never scaled with the field (GV34).

proc rot90Orbit*(p: tuple[x, y: int], side: int):
    array[4, tuple[x, y: int]] =
  ## The four images of one point under the rot90 symmetry group of a
  ## side x side square map, in team-orbit order (k = 0..3 quarter turns).
  var q = MapPoint(x: p.x, y: p.y)
  for k in 0 ..< 4:
    result[k] = (q.x, q.y)
    q = q.rot90Point(side)

proc quadMirrorOrbit*(p: tuple[x, y: int], width, height: int):
    array[4, tuple[x, y: int]] =
  ## The four images of one point under the quad-mirror Klein four-group:
  ## identity, mirrorX, mirrorY, rot180 — the quad-mirror twin of rot90Orbit,
  ## legal on any rectangle. A generic seed yields four distinct points; a
  ## seed ON an axis collapses pairs (callers pick seeds off the axes).
  [(p.x, p.y),
    (width - 1 - p.x, p.y),
    (p.x, height - 1 - p.y),
    (width - 1 - p.x, height - 1 - p.y)]

proc sightlineLoX*(gameMap: CtfMap): int =
  ## The low x of the band no straight horizontal ray may cross unblocked.
  ## Column endzones exempt the protected home strips (nothing can be built
  ## there); a compact endzone makes those strips ordinary field, so the
  ## scan runs border to border.
  if gameMap.endzone != ezColumn: ArenaBorder + 5
  else: gameMap.captureClear + 5

proc sightlineHiX*(gameMap: CtfMap): int =
  ## The high x of that band, the mirror of sightlineLoX.
  if gameMap.endzone != ezColumn: gameMap.width - ArenaBorder - 5
  else: gameMap.width - gameMap.captureClear - 5

proc sightlineLoY*(gameMap: CtfMap): int =
  ## The low y of the band no straight VERTICAL ray may cross unblocked —
  ## sightlineLoX transposed. Only quad-mirror maps scan columns: a 2-team
  ## board plays horizontally, and a rot90 board's row coverage carries onto
  ## its columns by the quarter turn itself. A rectangular quad-mirror board
  ## has no such carry, and its N/S teams fight along y.
  if gameMap.endzone != ezColumn: ArenaBorder + 5
  else: gameMap.captureClear + 5

proc sightlineHiY*(gameMap: CtfMap): int =
  ## The high y of that band, the mirror of sightlineLoY.
  if gameMap.endzone != ezColumn: gameMap.height - ArenaBorder - 5
  else: gameMap.height - gameMap.captureClear - 5

proc rectOnOpenFloor(
  gameMap: CtfMap, obstacles: seq[ArenaShape], rect: MapRect
): bool =
  ## Returns true when every pixel of the rectangle is walkable floor on an
  ## uninstalled candidate map. Sampled on a 3px grid — finer than the
  ## thinnest wall feature (12px) — with the far edge column and row always
  ## included, so no wall can slip past the samples on any side.
  var xs, ys: seq[int]
  var x = rect.x
  while x < rect.x + rect.w - 1:
    xs.add x
    x += 3
  xs.add rect.x + rect.w - 1
  var y = rect.y
  while y < rect.y + rect.h - 1:
    ys.add y
    y += 3
  ys.add rect.y + rect.h - 1
  for sy in ys:
    for sx in xs:
      if mapWallAt(gameMap, obstacles, sx, sy):
        return false
  true

proc placePuddles(gameMap: var CtfMap, count: int, rng: var MapRng) =
  ## Place the paint puddles. COUNT mode only, and AFTER the trench set is
  ## final so acceptance sees every dug pit: sample random left-half spots
  ## from the map rng and accept a spot when the blob AND its symmetry
  ## image sit on open floor, clear of every trench, every accepted
  ## puddle, and every team's base pocket. An odd request anchors its
  ## extra puddle dead center (its own image under mirror AND rot180),
  ## like the odd center pit. Best-effort like pits: when the attempts run
  ## out the map ships with as many as fit. (4-team symmetries raise on an
  ## explicit request in the generator and place nothing here.)
  if count <= 0 or gameMap.symmetry in {symRot90, symQuadMirror}:
    return
  let
    obstacles = buildArenaObstacles(gameMap)
    margin = PuddleMaxRadiusPx + 8
  var baseRooms: seq[MapRect]
  for room in gameMap.defaultCtfRooms():
    if room.name != "Center":
      baseRooms.add MapRect(x: room.x, y: room.y, w: room.w, h: room.h)
  ## Acceptance works on tight bounding boxes: conservative for the open
  ## floor test (a bbox clipping a wall rejects even when the blob's ring
  ## clears it), and cheap for the overlap tests.
  proc addPuddlePair(
    gameMap: CtfMap, splats: var seq[Puddle], splat: Puddle
  ): bool =
    ## Accepts one left-half splat plus its symmetry image when both sit
    ## on open floor clear of everything above. A splat whose image is
    ## blocked drops WITH it — fairness before density, as with trenches.
    ## symNone has no symmetry image: the splat stands alone (full-board maps
    ## author/generate the whole surface directly, no fairness-pair to place).
    let paired = gameMap.symmetry != symNone
    let image =
      case gameMap.symmetry
      of symMirror: splat.mirrorX(gameMap.width)
      of symRot180: splat.rot180(gameMap.width, gameMap.height)
      of symNone: splat        # unused when not paired
      of symRot90, symQuadMirror:
        raiseAssert "puddles never place on 4-team maps"
    let
      splatBox = puddleBounds(splat)
      imageBox = puddleBounds(image)
    if paired and rectsIntersect(splatBox, imageBox):
      return false
    let candBoxes = if paired: @[splatBox, imageBox] else: @[splatBox]
    for candBox in candBoxes:
      if not rectOnOpenFloor(gameMap, obstacles, candBox):
        return false
      for trench in gameMap.trenches:
        if rectsIntersect(shapeAsRect(trench), candBox):
          return false
      for base in baseRooms:
        if rectsIntersect(base, candBox):
          return false
    for accepted in splats:
      let accBox = puddleBounds(accepted)
      if rectsIntersect(accBox, splatBox) or
          (paired and rectsIntersect(accBox, imageBox)):
        return false
    splats.add splat
    if paired:
      splats.add image
    true
  var splats: seq[Puddle]
  if count mod 2 == 1:
    ## The odd splat sits dead center, inside the always-open flag ring —
    ## unless an odd PIT request already dug the center out (paint on a
    ## trench floor would double-stack the two hazards' art and rules).
    ## Its disc set is stitched self-symmetric (see centerPuddleSplat),
    ## so it is its own image and joins the set alone.
    let center = rng.centerPuddleSplat(gameMap)
    var centerOpen = true
    for trench in gameMap.trenches:
      if rectsIntersect(shapeAsRect(trench), puddleBounds(center)):
        centerOpen = false
        break
    if centerOpen:
      splats.add center
  ## Bounded rejection sampling: enough tries that a normal board fills
  ## the request, deterministic from the map seed either way. Anchors cap
  ## at PuddleMaxRadiusPx short of the center line, so a splat and its
  ## mirror image can never touch.
  var attempts = count * 40
  while splats.len < count and attempts > 0:
    dec attempts
    let
      cxHi = gameMap.center.x - PuddleMaxRadiusPx - 4
      cx = rng.pickRange(margin, max(margin, cxHi))
      cy = rng.pickRange(margin, max(margin, gameMap.height - margin))
    discard gameMap.addPuddlePair(splats, rng.puddleSplatAt(cx, cy))
  gameMap.puddles = splats

proc placePuddles*(gameMap: var CtfMap, count: int, seed: int) =
  ## Tool entry (mapkit): place `count` paint puddles on an ALREADY-BUILT
  ## map — e.g. a pinned campaign cell spec — replacing any puddles it
  ## carries, deterministically from `seed`. Same rules as generation:
  ## 2-team maps only, best-effort fill against the final terrain.
  if count > MaxPuddles:
    raise newException(
      CtfError, "Config field mapPuddles must be 0.." & $MaxPuddles & ".")
  if count > 0 and gameMap.symmetry in {symRot90, symQuadMirror}:
    raise newException(
      CtfError, "Puddles are not supported on 4-team maps yet.")
  gameMap.puddles = @[]
  var rng = MapRng(state: uint64(seed))
  placePuddles(gameMap, count, rng)
  gameMap.validateMap()

proc generateMapAttempt*(
  seed: int, overrides: MapGenOverrides, teams = 2
): CtfMap =  ## One UNVALIDATED draw. Every top-level parameter is drawn unconditionally
  ## and THEN overridden if locked, so locking one knob never shifts the
  ## other draws for the same seed. `teams` selects the family: 2 draws the
  ## classic left/right half-map, 4 draws a square rot90 corner/plus map.
  doAssert teams in [2, 4], "team count must be 2 or 4"
  var rng = MapRng(state: uint64(seed))

  ## One draw over ALL size classes. Widening this bound (3 -> 5 when the
  ## oversize classes landed) re-dealt which size each seed draws, which
  ## re-curated the map pool — but the draw still consumes exactly one
  ## stream slot, so every draw after it stays in its historical position.
  let sizeDraw = MapSizeNames[rng.pick(MapSizeNames.len)]
  let sizeName = if overrides.size.len > 0: overrides.size else: sizeDraw
  result =
    if teams == 4 and overrides.symmetry != "quadmirror":
      scaledGenShell4(sizeName)
    else:
      ## 2-team maps AND quad-mirror 4-team maps share the RECTANGULAR
      ## classic shell: quad-mirror completes its quadrant by reflections,
      ## which are legal on any rectangle — that is the whole point.
      scaledGenShell(sizeName)
  result.name = "gen-" & $seed
  result.path = GenMapName
  result.genSeed = seed

  if teams == 4:
    ## The symmetry draw keeps its slot in the draw order (locking layout
    ## must not shift later draws), but the DRAW is always rot90 — the
    ## default 4-team board stays the square it always was, byte for byte.
    ## "quadmirror" is override-only and opts into the rectangular shell.
    discard rng.coin()
    result.symmetry =
      if overrides.symmetry == "quadmirror": symQuadMirror else: symRot90
    if overrides.symmetry notin ["", "rot90", "quadmirror"]:
      raise newException(
        CtfError, "4-team maps are rot90 or quadmirror; got mapSymmetry: " &
          overrides.symmetry)
    let layoutDraw = if rng.coin(): layoutCorners else: layoutPlus
    result.layout =
      case overrides.layout
      of "": layoutDraw
      of "corners": layoutCorners
      of "plus": layoutPlus
      else:
        raise newException(
          CtfError, "Unknown map layout: " & overrides.layout)
  else:
    let symDraw = if rng.coin(): symRot180 else: symMirror
    result.symmetry =
      case overrides.symmetry
      of "": symDraw
      of "mirror": symMirror
      of "rot180": symRot180
      else:
        raise newException(
          CtfError, "Unknown map symmetry: " & overrides.symmetry)
    if overrides.layout.len > 0 and overrides.layout != "sides":
      raise newException(
        CtfError, "Map layout " & overrides.layout & " needs teams: 4.")

  ## Endzone archetype. Drawn from a SEPARATE stream keyed off the same seed
  ## so the main draw order never shifts: a seed that lands on the classic
  ## column generates the exact map it always did, byte for byte.
  block endzoneDraw:
    ## The compact knobs only mean anything on a compact endzone, and which
    ## shape a seed DRAWS is not something a config should have to guess:
    ## demand the shape lock alongside them rather than silently applying
    ## them on the seeds that happen to draw round.
    if (overrides.endzoneRadius > 0 or overrides.baseDepth > 0) and
        overrides.endzone notin ["disc", "square"]:
      raise newException(
        CtfError,
        "mapEndzoneRadius / mapBaseDepth need mapEndzone: disc or square.")
    var ezRng = MapRng(state: uint64(seed) xor 0x5A17E9D3C0FFEE11'u64)
    let shapeDraw =
      if teams == 4: ezColumn      ## 4-team layouts own their own geometry.
      else:
        case ezRng.pick(4)
        of 0, 1: ezColumn          ## half the pool stays the classic arena.
        of 2: ezDisc
        else: ezSquare
    result.endzone =
      case overrides.endzone
      of "": shapeDraw
      of "column": ezColumn
      of "disc": ezDisc
      of "square": ezSquare
      else:
        raise newException(
          CtfError, "Unknown map endzone: " & overrides.endzone)
    if result.endzone == ezColumn:
      ## A column endzone is pinned to the home border by `captureClear`, so
      ## its base cannot move: the threshold would slide out of the protected
      ## column and carriers would score on ordinary terrain.
      result.homeDepth = ClassicHomeDepth
      break endzoneDraw
    if teams == 4:
      raise newException(
        CtfError, "Compact endzones (mapEndzone) need a 2-team map.")
    ## Compact endzones pull the base well off its edge — the strip behind it
    ## becomes wilderness — and wrap it in a scoring shape whose radius
    ## scales with the size class exactly like every other clearance.
    let
      depthDraw = ezRng.pickRange(520, 620)
      radiusDraw = result.width * ezRng.pickRange(110, 140) div 1235
    result.homeDepth =
      if overrides.baseDepth > 0: overrides.baseDepth else: depthDraw
    result.endzoneRadius =
      if overrides.endzoneRadius > 0: overrides.endzoneRadius else: radiusDraw
    if result.homeDepth < HomeDepthMin or result.homeDepth > HomeDepthMax:
      raise newException(
        CtfError, "Config field mapBaseDepth must be " & $HomeDepthMin &
          ".." & $HomeDepthMax & ".")
    if result.endzoneRadius < EndzoneRadiusMin or
        result.endzoneRadius > maxEndzoneRadius(result.width):
      raise newException(
        CtfError, "Config field mapEndzoneRadius must be " &
          $EndzoneRadiusMin & ".." & $maxEndzoneRadius(result.width) & ".")
  result.rooms = result.defaultCtfRooms()

  let featureDraw = CenterFeatureNames[rng.pick(3)]
  let feature =
    if overrides.centerFeature.len > 0: overrides.centerFeature
    else: featureDraw
  if feature notin CenterFeatureNames:
    raise newException(CtfError, "Unknown map center feature: " & feature)

  ## Compact-endzone maps spread their columns over the whole half-field
  ## (the home border strip is wilderness now, not a protected column), so
  ## they draw MORE of them to hold the same field density. Same single draw
  ## either way — the RNG stream never shifts.
  ##
  ## The column counts were tuned on the standard field, and column x-slots
  ## spread over the width: an OVERSIZE board with the standard count would
  ## space its cover ~2x apart and fall to the floor of the cover budget.
  ## So huge/giant multiply the draw bounds by their field scale. The three
  ## classic classes keep factor 1 exactly — their bounds (and so their
  ## draws) are byte-identical to the pre-oversize generator.
  let columnScale =
    if sizeName in ["huge", "giant", "colossal"]: mapSizeScale(sizeName)
    else: 1.0
  proc cols(value: int): int = int(round(float(value) * columnScale))
  let columnsDraw =
    if teams == 4: rng.pickRange(cols(3), cols(4))
    elif result.endzone != ezColumn: rng.pickRange(cols(6), cols(8))
    else: rng.pickRange(cols(4), cols(6))
  let columns =
    if overrides.columns > 0: overrides.columns else: columnsDraw
  ## The ceiling has to admit the generator's OWN widest draw, or a size class
  ## rejects itself: the flat 24 this bound used to carry predated the oversize
  ## classes, and at colossal's 5.2x a compact-endzone board draws cols(8) = 42,
  ## so 32 of 40 two-team colossal seeds raised here instead of generating. (The
  ## 4-team draw tops out at cols(4) = 21, which is why record_colossal_demo.sh
  ## never hit it.) Deriving the ceiling from the same cols() the draw uses keeps
  ## any future class in range automatically; small/standard/large scale by 1, so
  ## their bound stays exactly 24.
  let maxColumns = max(24, cols(8))
  if columns < 3 or columns > maxColumns:
    raise newException(
      CtfError, "Config field mapColumns must be 3.." & $maxColumns & ".")

  let
    cy = result.center.y
    redAnchorX = result.teamHomeX(Red)
    ## Obstacle columns live between the home approach and the flag-ring
    ## flank; the ring and the endzones carve any overlap back out of the
    ## wall mask. A compact endzone frees the border strip, so the columns
    ## start just inside the wall and terrain wraps the base on every side.
    xMin =
      if result.endzone != ezColumn: ArenaBorder + 34
      else: result.captureClear + 50
    xMax = result.center.x - 52
    ## The vertical band the column slots may occupy: the full field on
    ## sides maps, the top-left quadrant on corner maps (rot90 fills the
    ## rest), the west arm on plus maps (the corner blocks own the rest).
    slotBand =
      case result.layout
      of layoutSides:
        (lo: ArenaBorder + 30, hi: result.height - ArenaBorder - 30)
      of layoutCorners, layoutPlus:
        ## The full quadrant, crossing the centerline: the rot90 images
        ## fill the other side, and slots near cy are what covers the
        ## central horizontal band. Both 4-team layouts are fully open
        ## square boards — they differ only in where the teams live.
        (lo: ArenaBorder + 30, hi: cy + 60)
  ## Window-eligible shapes: (obstacle index, column, slot y).
  var eligible: seq[tuple[idx, col, y: int]]
  ## Trench pit candidates, resolved into actual digs after the columns
  ## exist: `instead` swaps its obstacle for a pit, `gap` sits in a
  ## cleared slot's corridor, `endzone` hugs the pedestal.
  const
    pitInstead = 0
    pitGap = 1
    pitEndzone = 2
  var pitCandidates: seq[tuple[kind, obstacleIdx, x, y: int]]

  for col in 0 ..< columns:
    let
      colX = xMin + ((2 * col + 1) * (xMax - xMin)) div (2 * columns)
      family = ColumnFamily(rng.pick(4))
      ## 4-team quadrant shapes replicate x4 (not x2), so slots spread out
      ## to keep the same field density.
      period =
        if teams == 4: rng.pickRange(130, 180)
        else: rng.pickRange(88, 120)
      ## Phases are STRATIFIED across columns (like the hand-authored
      ## arena's 0/+48/+24/+72 ladder) with a half-period jitter: fully
      ## random phases leave rows every column misses, which the sightline
      ## validator rejects — mirror-symmetric maps almost never survived.
      phase = (period * col div columns +
        rng.pick(max(1, period div 2))) mod period
    var slotYs: seq[int]
    var slotY = slotBand.lo + phase
    while slotY <= slotBand.hi:
      slotYs.add slotY
      slotY += period
    if slotYs.len < (if result.layout == layoutSides: 3 else: 2):
      continue

    ## Clear-mask: drop each slot with probability 1/4, then guarantee at
    ## least one gap (a solid picket walls the lane off) and at least half
    ## the slots kept (a bare column gives no cover).
    var cleared = newSeq[bool](slotYs.len)
    var clearedCount = 0
    for i in 0 ..< slotYs.len:
      if rng.pick(4) == 0:
        cleared[i] = true
        inc clearedCount
    if clearedCount == 0:
      cleared[rng.pick(slotYs.len)] = true
      clearedCount = 1
    let minKept = (slotYs.len + 1) div 2
    while slotYs.len - clearedCount < minKept and clearedCount > 1:
      var idx = rng.pick(slotYs.len)
      while not cleared[idx]:
        idx = (idx + 1) mod slotYs.len
      cleared[idx] = false
      dec clearedCount

    var zig = rng.coin()
    for i, sy in slotYs:
      ## Compact endzones keep an APRON of clear ground outside the ring:
      ## terrain that crowded the scoring shape would seal the very
      ## approaches that make an off-the-edge base worth building, and the
      ## open-flank validator would reject the map anyway. Obstacle centers
      ## reach ~30px, so an apron of radius + 60 leaves every cardinal gate
      ## a full corridor's clearance.
      if result.endzone != ezColumn and
          endzoneFloorAt(colX, sy, redAnchorX, cy,
            result.endzoneRadius + 60 - EndzoneWallMargin,
            result.endzone == ezDisc):
        continue
      if cleared[i]:
        ## A cleared gap can hold a dug pit BETWEEN the column's obstacles
        ## — the corridor stays open to movement and fire.
        pitCandidates.add (pitGap, -1, colX, sy)
        continue
      ## Every kept slot can dig a trench INSTEAD of raising its obstacle
      ## — cover you stand in rather than behind. Selection below decides;
      ## the sightline repair and the validators judge the thinner wall
      ## set exactly as usual.
      pitCandidates.add (pitInstead, result.leftObstacles.len, colX, sy)
      case family
      of colStubs:
        ## Stub ends whose border gap would drop under the corridor minimum
        ## anchor to the border instead — a sub-26px slit is impassable
        ## anyway and reads as a wart.
        var top = sy - 30
        var bottom = sy + 30
        if i == 0 and top - ArenaBorder < MinCorridorWidth:
          top = ArenaBorder
        if i == slotYs.len - 1 and result.layout == layoutSides and
            result.height - ArenaBorder - bottom < MinCorridorWidth:
          bottom = result.height - ArenaBorder
        result.leftObstacles.add ArenaShape(kind: shapeRect,
          rect: MapRect(x: colX - 9, y: top, w: 18, h: bottom - top))
        eligible.add (result.leftObstacles.high, col, sy)
      of colDiamonds:
        result.leftObstacles.add ArenaShape(
          kind: shapeDiamond, cx: colX, cy: sy, radius: 28)
        eligible.add (result.leftObstacles.high, col, sy)
      of colDiscs:
        result.leftObstacles.add ArenaShape(
          kind: shapeDisc, cx: colX, cy: sy, radius: 28)
        eligible.add (result.leftObstacles.high, col, sy)
      of colChevrons:
        let (ya, yb) = if zig: (sy - 14, sy + 14) else: (sy + 14, sy - 14)
        result.leftObstacles.add ArenaShape(kind: shapeDiagonal,
          x0: colX - 14, y0: ya, x1: colX + 14, y1: yb, thickness: 12)
        zig = not zig

  ## Endzone trench pit candidates, authored on the RED side (the symmetry
  ## image gives Blue the exact counterpart): BEHIND the pedestal toward
  ## the home edge, and ABOVE and BELOW it — each clear of the pedestal
  ## art. Endzone floor is protected (never walled), so endzone digs
  ## always survive the open-floor prune below.
  let
    redHomeX = redAnchorX
    pedestalClear = PedestalCoverSize div 2 + TrenchSize div 2
    ## How far off the pedestal an endzone dig sits. Column endzones have the
    ## whole home strip to work with; a COMPACT zone clamps the offset so the
    ## pit stays on its protected floor (clear of the pedestal art at the
    ## floor, inside the ring at the ceiling) instead of being pruned later.
    compactPitOffset =
      max(pedestalClear,
        min(pedestalClear + 20,
          result.endzoneRadius - TrenchSize div 2 - EndzoneWallMargin))
    backOffset =
      if result.endzone == ezColumn: pedestalClear + 12
      else: compactPitOffset
    sideOffset =
      if result.endzone == ezColumn: pedestalClear + 20
      else: compactPitOffset
  pitCandidates.add (pitEndzone, -1, redHomeX - backOffset, cy)
  pitCandidates.add (pitEndzone, -1, redHomeX, cy - sideOffset)
  pitCandidates.add (pitEndzone, -1, redHomeX, cy + sideOffset)

  ## Pit selection. DENSITY mode (default) rolls every candidate at its
  ## class chance scaled by pitDensity percent. COUNT mode (pits locked)
  ## shuffles the candidates and takes symmetric pairs until the requested
  ## total is met — an ODD total anchors its extra pit at the exact map
  ## center, the one spot that is its own image under mirror AND rot180,
  ## so both parities stay exactly team-fair.
  if overrides.pits < -1 or overrides.pits > 64:
    raise newException(CtfError, "Config field mapPits must be 0..64.")
  if overrides.puddles > MaxPuddles:
    raise newException(
      CtfError, "Config field mapPuddles must be 0.." & $MaxPuddles & ".")
  if overrides.pitDensity < -1 or overrides.pitDensity > 1000:
    raise newException(
      CtfError, "Config field mapPitDensity must be 0..1000.")
  let
    pitDensity = if overrides.pitDensity >= 0: overrides.pitDensity else: 100
    centerPit = trenchSquareAt(result.center.x, result.center.y)
    oddCenterPit = overrides.pits >= 0 and overrides.pits mod 2 == 1
    pitPairsWanted = if overrides.pits >= 0: overrides.pits div 2 else: -1
  var obstacleRemoved = newSeq[bool](result.leftObstacles.len)
  if result.symmetry in {symRot90, symQuadMirror}:
    ## Trenches are a 2-team-map feature for now: the dig/image pair
    ## accounting assumes one symmetry image per dig, and both 4-team
    ## symmetries have three. An explicit pit request errors; the density
    ## path digs nothing (clearing the candidates keeps the loop from
    ## writing UNPAIRED digs into result.trenches — finalize is what pairs
    ## them, and it is skipped on 4-team symmetries).
    if overrides.pits > 0:
      raise newException(
        CtfError, "Trenches are not supported on 4-team maps yet.")
    if overrides.puddles > 0:
      ## Same pair accounting as trenches: one symmetry image per blob.
      raise newException(
        CtfError, "Puddles are not supported on 4-team maps yet.")
    pitCandidates.setLen(0)
  if pitPairsWanted >= 0:
    rng.shuffle(pitCandidates)
  for cand in pitCandidates:
    if pitPairsWanted >= 0:
      if result.trenches.len >= pitPairsWanted:
        break
    else:
      let baseChance =
        case cand.kind
        of pitInstead: 17
        of pitGap: 25
        else: 50
      if rng.pick(100) >= clamp(baseChance * pitDensity div 100, 0, 100):
        continue
    let pit = trenchSquareAt(cand.x, cand.y)
    var blocked = oddCenterPit and rectsIntersect(pit, centerPit)
    for accepted in result.trenches:
      if rectsIntersect(shapeAsRect(accepted), pit):
        blocked = true
        break
    if blocked:
      continue
    result.trenches.add rectShape(pit)
    if cand.kind == pitInstead:
      obstacleRemoved[cand.obstacleIdx] = true

  ## Swap the chosen `instead` obstacles out of the wall set. Window
  ## eligibility indexes leftObstacles, so compact both together.
  block removeSwappedObstacles:
    var remap = newSeq[int](result.leftObstacles.len)
    var compacted: seq[ArenaShape]
    for i, shape in result.leftObstacles:
      if obstacleRemoved[i]:
        remap[i] = -1
      else:
        remap[i] = compacted.len
        compacted.add shape
    result.leftObstacles = compacted
    var remappedEligible: seq[tuple[idx, col, y: int]]
    for entry in eligible:
      if remap[entry.idx] >= 0:
        remappedEligible.add (remap[entry.idx], entry.col, entry.y)
    eligible = remappedEligible

  ## Center feature, straddling the horizontal midline just outside the
  ## flag ring ("[" here; its symmetry image closes the right side).
  let bx = result.center.x - 138
  case feature
  of "bracket":
    ## The GV16 windowed bracket: mid lane closed to movement and fire,
    ## glass pane over the midline for a fogless center sightline.
    result.leftObstacles.add ArenaShape(kind: shapeRect,
      rect: MapRect(x: bx, y: cy - 53, w: 28, h: 12))
    result.leftObstacles.add ArenaShape(kind: shapeRect,
      rect: MapRect(x: bx, y: cy - 41, w: 12, h: 24))
    result.leftObstacles.add ArenaShape(kind: shapeRect, window: true,
      rect: MapRect(x: bx, y: cy - 17, w: 12, h: 36))
    result.leftObstacles.add ArenaShape(kind: shapeRect,
      rect: MapRect(x: bx, y: cy + 19, w: 12, h: 23))
    result.leftObstacles.add ArenaShape(kind: shapeRect,
      rect: MapRect(x: bx, y: cy + 42, w: 28, h: 12))
  of "walls":
    ## Solid bar pair with an open (glassless) midline gap.
    result.leftObstacles.add ArenaShape(kind: shapeRect,
      rect: MapRect(x: bx, y: cy - 100, w: 12, h: 80))
    result.leftObstacles.add ArenaShape(kind: shapeRect,
      rect: MapRect(x: bx, y: cy + 20, w: 12, h: 80))
  else:
    discard  # "ring": the center stays fully open.

  ## Sightline repair. A horizontal ray survives when no obstacle blocks its
  ## row: under MIRROR the right half repeats the left, so the LEFT half
  ## alone must cover every row; under ROT180 the right half contributes the
  ## flipped rows, so row y needs cover at y or height-1-y. Random layouts
  ## almost never satisfy the mirror condition on their own (the first pool
  ## scan came out 100% rot180), so plug the uncovered rows with diamonds in
  ## drawn columns; the validators still judge the repaired result.
  block sightlineRepair:
    proc rowBlocked(gameMap: CtfMap, y: int): bool =
      for x in gameMap.sightlineLoX .. gameMap.center.x:
        if mapWallAt(gameMap, gameMap.leftObstacles, x, y):
          return true
      false
    proc rowBlockedFull(gameMap: CtfMap, obstacles: seq[ArenaShape],
        y: int): bool =
      ## Full-width row scan against the COMPLETE symmetry-expanded set —
      ## rot90 folds a quadrant into all four quarters, so no single-half
      ## shortcut exists.
      for x in gameMap.sightlineLoX .. gameMap.sightlineHiX:
        if mapWallAt(gameMap, obstacles, x, y):
          return true
      false
    ## The plug budget scales with the columns for the same reason the
    ## columns scale: an oversize board has proportionally more rows to
    ## cover (cols() is 1x on the classic classes, so their budget is the
    ## historical 40).
    var plugsLeft = cols(40)
    while plugsLeft > 0:
      var uncovered = -1
      let fullSet =
        if result.symmetry == symRot90: buildArenaObstacles(result)
        else: @[]
      var y = ArenaBorder + 2
      while y < result.height - ArenaBorder:
        let covered =
          case result.symmetry
          of symMirror, symNone:
            ## symNone: the authored obstacle set IS the full board (no lift),
            ## so a row's cover is read directly from it — same call as mirror
            ## (rowBlocked reads the stored obstacle rows), no fold.
            result.rowBlocked(y)
          of symRot180, symQuadMirror:
            ## Quad-mirror reads like rot180 here: the mirrorX images repeat
            ## the seed rows on the right half, and the mirrorY/rot180
            ## images contribute the y-flipped rows — so row y needs seed
            ## cover at y or height-1-y, the same fold.
            result.rowBlocked(y) or
              result.rowBlocked(result.height - 1 - y)
          of symRot90:
            result.rowBlockedFull(fullSet, y)
        if not covered:
          uncovered = y
          break
        y += 4
      if uncovered < 0:
        break sightlineRepair
      let
        plugCol = rng.pick(columns)
        plugX = xMin + ((2 * plugCol + 1) * (xMax - xMin)) div (2 * columns)
        ## Under both 4-team symmetries a quadrant shape at row y also
        ## covers row H-1-y (its rot180 / mirrorY image), so an uncovered
        ## bottom-half row folds to its top reflection before plugging;
        ## plugs may sit close to the border.
        foldedRow =
          if result.symmetry in {symRot90, symQuadMirror} and uncovered > cy:
            result.height - 1 - uncovered
          else:
            uncovered
        plugY = clamp(
          foldedRow + 24, ArenaBorder + 12, result.height - ArenaBorder - 12)
      dec plugsLeft
      ## A plug inside the endzone apron would seal an approach (and be
      ## carved to a stump by the protected floor anyway); skip it and let
      ## the next iteration try another column for the same row.
      if result.endzone != ezColumn and
          endzoneFloorAt(plugX, plugY, redAnchorX, cy,
            result.endzoneRadius + 60 - EndzoneWallMargin,
            result.endzone == ezDisc):
        continue
      if result.symmetry == symQuadMirror:
        ## Quad plugs are thin vertical bars (the bracket's 12px vocabulary):
        ## reflections never rotate a quadrant shape into cross-coverage the
        ## way rot90 does, so a quad board needs strictly more sightline
        ## breakers — a bar buys the same row span as a diamond for under
        ## half the wall pixels, which is what keeps the repaired board
        ## inside the cover ceiling.
        result.leftObstacles.add ArenaShape(kind: shapeRect,
          rect: MapRect(
            x: plugX - 6, y: max(ArenaBorder, foldedRow - 4), w: 12, h: 60))
      else:
        result.leftObstacles.add ArenaShape(
          kind: shapeDiamond, cx: plugX, cy: plugY, radius: 28)

  ## Vertical (column) sightline repair — QUAD-MIRROR ONLY. On the square
  ## rot90 boards the quarter turn carries blocked rows onto blocked
  ## columns, so the row repair above covers both; a rectangular quad-mirror
  ## board has no such carry, and its N/S teams fight along y. The logic is
  ## the row repair transposed: column x needs seed cover at x or W-1-x
  ## (the mirrorX/rot180 images contribute the x-flipped columns), plugs
  ## fold right-half columns to their left reflection, and the plug's free
  ## coordinate (y) draws from the quadrant slot band. All draws sit inside
  ## this symmetry gate, so non-quad seeds consume the exact RNG stream they
  ## always did.
  block columnSightlineRepair:
    if result.symmetry != symQuadMirror:
      break columnSightlineRepair
    proc colBlocked(gameMap: CtfMap, x: int): bool =
      ## Seed-set cover of column x anywhere in the scanned band. The y band
      ## is scanned in FULL (not folded to the top half): seeds may sit past
      ## cy, and the mirrorY images stay inside the band anyway because the
      ## band is symmetric about the y axis — only the x fold is real.
      ## spinAlways: the validator judges columns on the always-stone mask,
      ## so a spinning diamond's resting edge must not count as cover here.
      for y in gameMap.sightlineLoY .. gameMap.sightlineHiY:
        if mapWallAt(gameMap, gameMap.leftObstacles, x, y,
            spin = spinAlways):
          return true
      false
    proc colFullyProtected(gameMap: CtfMap, x: int): bool =
      ## A column whose entire scan band is protected floor can never hold
      ## wall — on a plus map the columns inside the W/E capture reach run
      ## through the arm's protected approach for the whole band. The
      ## validator exempts them identically; demanding wall there would
      ## make every plus board unbuildable. (Symmetric in x by the carve's
      ## own reflection exactness, so the x fold needs no second call.)
      for y in gameMap.sightlineLoY .. gameMap.sightlineHiY:
        if not mapProtectedFloorAt(gameMap, x, y):
          return false
      true
    var plugsLeft = cols(40)
    while plugsLeft > 0:
      var uncovered = -1
      var x = ArenaBorder + 2
      while x < result.width - ArenaBorder:
        if not (result.colBlocked(x) or
            result.colBlocked(result.width - 1 - x) or
            result.colFullyProtected(x)):
          uncovered = x
          break
        x += 4
      if uncovered < 0:
        break columnSightlineRepair
      ## The plug is a thin horizontal bar over the folded column, its row
      ## drawn INSIDE the scan band so no plug can miss the band and leave
      ## a dead shape behind (see the row-plug note on why quad plugs are
      ## bars, not diamonds).
      let
        foldedCol =
          if uncovered > result.center.x: result.width - 1 - uncovered
          else: uncovered
        plugX = max(ArenaBorder, foldedCol - 4)
        plugY = rng.pickRange(
          result.sightlineLoY,
          max(result.sightlineLoY + 1, result.sightlineHiY - 12))
      dec plugsLeft
      result.leftObstacles.add ArenaShape(kind: shapeRect,
        rect: MapRect(x: plugX, y: plugY, w: 60, h: 12))

  ## Glass windows: fog sees through them, nothing passes them. Biased to
  ## the outermost column and the midline band, where sightlines matter.
  let windowsDraw =
    if teams == 4: rng.pickRange(1, 2)
    else: rng.pickRange(2, 4)
  let windowCount =
    if overrides.windows >= 0: overrides.windows else: windowsDraw
  if windowCount > 6:
    raise newException(CtfError, "Config field mapWindows must be 0..6.")
  var preferred, rest: seq[tuple[idx, col, y: int]]
  for entry in eligible:
    if entry.col == 0 or abs(entry.y - cy) < 70:
      preferred.add entry
    else:
      rest.add entry
  rng.shuffle(preferred)
  rng.shuffle(rest)
  let ranked = preferred & rest
  for i in 0 ..< min(windowCount, ranked.len):
    result.leftObstacles[ranked[i].idx].window = true

  ## Med kits. Sides maps: two complementary (y, H-1-y) center-line pairs
  ## are drawn as candidates and ONE pair goes active — a top/bottom pair on
  ## x = W/2 is invariant under both mirror and rot180, so pickup fairness
  ## is exact. 4-team maps: one kit per team as the rot90 orbit of a single
  ## drawn ring point, which is fair by the same symmetry argument.
  if teams == 4:
    let
      ringLo = result.flagRing + 40
      ringHi = result.center.x - result.captureClear - 60
      d = rng.pickRange(ringLo, max(ringLo + 1, ringHi))
      ## rot90: one ring point east of center, walked round the quarter
      ## turns. Quad-mirror: a point ON the y axis has a degenerate Klein
      ## orbit (its mirrorX image is itself, half a pixel off), so the seed
      ## moves onto the top-left DIAGONAL at the same L2 distance
      ## (181/256 ~ 1/sqrt(2)) and the four reflections give one kit per
      ## quadrant, exactly fair by construction. Same single draw either
      ## way — the RNG stream never shifts.
      orbit =
        if result.symmetry == symQuadMirror:
          let dd = max(1, d * 181 div 256)
          quadMirrorOrbit(
            (result.center.x - dd, result.center.y - dd),
            result.width, result.height)
        else:
          rot90Orbit(
            (result.center.x + d, result.center.y), result.width)
    result.medKitCandidates = @[]
    for point in orbit:
      result.medKitCandidates.add MapPoint(x: point.x, y: point.y)
    result.medKitSpawns = result.medKitCandidates
  else:
    let
      mid = result.width div 2
      y1 = rng.pickRange(result.height * 16 div 100, result.height * 34 div 100)
      y2 = rng.pickRange(result.height * 36 div 100, result.height * 47 div 100)
    result.medKitCandidates = @[
      MapPoint(x: mid, y: y1),
      MapPoint(x: mid, y: result.height - 1 - y1),
      MapPoint(x: mid, y: y2),
      MapPoint(x: mid, y: result.height - 1 - y2),
    ]
    result.medKitSpawns =
      if rng.coin():
        @[result.medKitCandidates[0], result.medKitCandidates[1]]
      else:
        @[result.medKitCandidates[2], result.medKitCandidates[3]]

  ## Finalize the trenches. Every left-half dig gets its image under
  ## the map's symmetry so neither team has a private pit; a dig that ended
  ## up under a wall (a sightline-repair plug can land on its slot) or on
  ## top of an already-accepted dig is dropped — and a dig whose image is
  ## blocked drops WITH it, fairness before density. (4-team maps reach
  ## here with zero candidates and place nothing — see the guard above.)
  block finalizeTrenches:
    let obstacles = buildArenaObstacles(result)
    var digs: seq[MapRect]
    if oddCenterPit:
      ## The odd pit sits dead center, inside the always-open flag ring.
      digs.add centerPit
    proc addPair(
      gameMap: CtfMap, digs: var seq[MapRect], trench: MapRect
    ): bool =
      ## Accepts one left-half dig plus its symmetry image when both sit
      ## on open floor clear of every accepted dig. Count-mode parity
      ## rests on every candidate being distinct from its own image —
      ## true because column candidates cap at center.x - 52 and endzone
      ## candidates hug the red home; a future center-adjacent candidate
      ## class would break the exact-count accounting here.
      let image =
        case gameMap.symmetry
        of symMirror: trench.mirrorX(gameMap.width)
        of symRot180: trench.rot180(gameMap.width, gameMap.height)
        of symNone: trench    # no image: full-board, the `image != trench`
                              # guard below then adds it exactly once
        of symRot90, symQuadMirror:
          raiseAssert "trenches never place on 4-team maps"
      if not rectOnOpenFloor(gameMap, obstacles, trench) or
          not rectOnOpenFloor(gameMap, obstacles, image):
        return false
      for accepted in digs:
        if rectsIntersect(accepted, trench) or
            rectsIntersect(accepted, image):
          return false
      digs.add trench
      if image != trench:
        digs.add image
      true
    for trench in result.trenches:
      discard result.addPair(digs, shapeAsRect(trench))
    ## COUNT mode: pairs lost to sightline-repair walls are topped back up
    ## from the unused candidates that cannot change the wall set (gap and
    ## endzone spots; a late `instead` swap would dodge the repair pass).
    if pitPairsWanted >= 0:
      for cand in pitCandidates:
        if digs.len >= overrides.pits:
          break
        if cand.kind == pitInstead:
          continue
        discard result.addPair(digs, trenchSquareAt(cand.x, cand.y))
    result.trenches = @[]
    for d in digs:
      result.trenches.add rectShape(d)

  ## Paint puddles go last: nothing draws from the map rng after them, so a
  ## puddle-free draw is bit-identical whether or not the proc exists (see
  ## placePuddles for the placement rules).
  placePuddles(result, overrides.puddles, rng)
  result.validateMap()

type
  MapDiagnosticArtifact* = enum
    ## Full-board diagnostic arrays callers may opt into. Summary diagnostics
    ## never retain these large buffers: a giant board has 5.5 million pixels,
    ## and the editor's threaded HTTP service may diagnose several maps at once.
    diagnosticWallMasks
    diagnosticCorridorOpen
    diagnosticReachable

  EndzoneGateState* = enum
    ## Whether one compact-endzone flank gate is usable by the eroded flood.
    gateOpen
    gateOffMap
    gateSealed

  EndzoneGateDiagnostic* = object
    ## The position and reachability state of one named compact-endzone gate.
    name*: string
    point*: MapPoint
    state*: EndzoneGateState

  MapDiagnostics* = object
    ## Play-quality measurements for one map. Scalar and compact sequence
    ## summaries are always populated. Full-board arrays are populated only
    ## when their matching MapDiagnosticArtifact is requested.
    reason*: string
    coverPermille*, minCoverPermille*: int
    openSightlineRows*: seq[int]
      ## Every open row in the validator's historical 4px scan, not every
      ## physical map row.
    redHomeOnOpenFloor*: bool
    unreachableTeams*: seq[Team]
    centerReachable*: bool
    endzoneGates*: seq[EndzoneGateDiagnostic]
    endzoneFlankChecked*: bool
    rearGateReachesCenterWithoutEndzone*: bool
    maxWall*, minWall*: seq[bool]
      ## Swept-union / always-stone masks; retained by diagnosticWallMasks.
    corridorOpen*: seq[bool]
      ## Player-width-eroded floor; retained by diagnosticCorridorOpen.
    reachable*: seq[bool]
      ## Eroded floor reachable from Red; retained by diagnosticReachable.

proc collectMapDiagnostics(
  gameMap: CtfMap,
  artifacts: set[MapDiagnosticArtifact],
  stopAfterFirstFailure: bool,
): MapDiagnostics =
  ## The shared staged implementation behind full editor diagnostics and the
  ## generator's first-failure validator. The latter preserves the old early
  ## exits, so rejected attempts do not pay for later distance/flood stages.
  template recordFailure(message: string) =
    if result.reason.len == 0:
      result.reason = message
    if stopAfterFirstFailure:
      return

  let
    w = gameMap.width
    h = gameMap.height
    obstacles = buildArenaObstacles(gameMap)
  ## A spinning diamond is not one shape, so validation cannot use one mask:
  ## these invariants point in OPPOSITE directions (GV29).
  ##   maxWall — the swept union. Use it where MORE wall is the pessimistic
  ##     case: a corridor that closes at any frame is not a corridor, and a
  ##     map that is too clogged at any frame is too clogged.
  ##   minWall — the intersection over the turn, stone at every frame. Use it
  ##     where LESS wall is pessimistic: a firing lane that opens at any frame
  ##     is an open lane, and cover that comes and goes cannot prop up the
  ##     cover floor.
  ## A sightline checked against the swept mask would let a map ship with a
  ## cross-map lane that opens on a clock: the diamonds reach 29 px along an
  ## axis at rest but only 20 px a third of a turn later, while the swept disc
  ## claims 30 px at all times. Two seeds in the pre-GV29 pool had exactly
  ## that defect, which is why the pool was re-curated with this change.
  var (maxWall, minWall) = rasterizeWallMasks(gameMap, obstacles)
  var minCoverPixels, coverPixels, interiorPixels = 0
  for y in 0 ..< h:
    for x in 0 ..< w:
      ## The cover-budget interior. Sides maps keep the historical x-band
      ## definition EXACTLY (the curated pool seeds validate first-attempt
      ## against it). 4-team layouts measure the actually-playable field:
      ## everything inside the border that is not protected floor.
      let interior =
        if gameMap.endzone != ezColumn:
          ## Compact endzones: the same "everything playable" measure the
          ## 4-team layouts use — the wilderness behind the bases is field
          ## and must carry its share of the cover budget.
          x >= ArenaBorder and x < w - ArenaBorder and
            y >= ArenaBorder and y < h - ArenaBorder and
            not mapProtectedFloorAt(gameMap, x, y)
        else:
          case gameMap.layout
          of layoutSides:
            x >= gameMap.captureClear and x < w - gameMap.captureClear and
              y >= ArenaBorder and y < h - ArenaBorder
          of layoutCorners, layoutPlus:
            x >= ArenaBorder and x < w - ArenaBorder and
              y >= ArenaBorder and y < h - ArenaBorder and
              not mapProtectedFloorAt(gameMap, x, y)
      if interior:
        inc interiorPixels
        if maxWall[y * w + x]:
          inc coverPixels
        if minWall[y * w + x]:
          inc minCoverPixels

  ## Cover budget: neither an open field nor a clogged maze — at EVERY frame,
  ## so the floor is measured on the cover that is always there and the
  ## ceiling on the cover that is ever there.
  let
    permille = coverPixels * 1000 div max(1, interiorPixels)
    minPermille = minCoverPixels * 1000 div max(1, interiorPixels)
  result.coverPermille = permille
  result.minCoverPermille = minPermille
  if minPermille < CoverPermilleMin:
    recordFailure("too open: " & $minPermille & " permille cover")
  if permille > CoverPermilleMax:
    recordFailure("too clogged: " & $permille & " permille cover")

  ## With map-wide guns no straight horizontal ray may survive between the
  ## capture columns (the property tests/test_map_los.nim pins for arena).
  block sightlines:
    let
      ax = gameMap.sightlineLoX
      bx = gameMap.sightlineHiX
    var y = ArenaBorder + 2
    while y < h - ArenaBorder:
      var blocked = false
      for x in ax .. bx:
        if minWall[y * w + x]:
          blocked = true
          break
      if not blocked:
        result.openSightlineRows.add y
        if result.reason.len == 0:
          result.reason = "open horizontal sightline at y=" & $y
        if stopAfterFirstFailure:
          return
      y += 4

  ## Vertical sightlines — QUAD-MIRROR ONLY. rot90's row coverage carries
  ## onto its columns by the quarter turn (the minWall mask is its own
  ## rotation), and 2-team boards play horizontally; a rectangular
  ## quad-mirror board's N/S teams fight along y, so its columns get the
  ## transposed check. Gated so no existing map class changes validation
  ## outcome.
  if gameMap.symmetry == symQuadMirror:
    block verticalSightlines:
      let
        ay = gameMap.sightlineLoY
        by = gameMap.sightlineHiY
      var x = ArenaBorder + 2
      while x < w - ArenaBorder:
        var blocked = false
        for y in ay .. by:
          if minWall[y * w + x]:
            blocked = true
            break
        if not blocked:
          ## A column whose whole band is protected floor can never hold
          ## wall (a plus map's W/E capture reach); it is open by DESIGN,
          ## exactly like the exempted home strips of the horizontal scan,
          ## so it is no violation. Checked only on the rare open columns.
          var canHoldWall = false
          for y in ay .. by:
            if not mapProtectedFloorAt(gameMap, x, y):
              canHoldWall = true
              break
          if canHoldWall:
            if result.reason.len == 0:
              result.reason = "open vertical sightline at x=" & $x
            if stopAfterFirstFailure:
              return
        x += 4
  if diagnosticWallMasks in artifacts:
    result.minWall = minWall
  else:
    minWall.setLen(0)

  ## Corridor + connectivity: chamfer 3-4 distance to the nearest wall,
  ## eroded by half the corridor minimum, then a flood fill — both flags and
  ## the center must connect through corridors the player footprint can
  ## actually use.
  var dist = newSeq[int32](w * h)
  for i in 0 ..< w * h:
    dist[i] = if maxWall[i]: 0'i32 else: int32.high div 2
  for y in 0 ..< h:
    for x in 0 ..< w:
      let i = y * w + x
      if dist[i] == 0:
        continue
      var d = dist[i]
      if x > 0: d = min(d, dist[i - 1] + 3)
      if y > 0: d = min(d, dist[i - w] + 3)
      if x > 0 and y > 0: d = min(d, dist[i - w - 1] + 4)
      if x < w - 1 and y > 0: d = min(d, dist[i - w + 1] + 4)
      dist[i] = d
  for y in countdown(h - 1, 0):
    for x in countdown(w - 1, 0):
      let i = y * w + x
      if dist[i] == 0:
        continue
      var d = dist[i]
      if x < w - 1: d = min(d, dist[i + 1] + 3)
      if y < h - 1: d = min(d, dist[i + w] + 3)
      if x < w - 1 and y < h - 1: d = min(d, dist[i + w + 1] + 4)
      if x > 0 and y < h - 1: d = min(d, dist[i + w - 1] + 4)
      dist[i] = d
  let minChamfer = int32((MinCorridorWidth div 2) * 3)
  var open = newSeq[bool](w * h)
  for i in 0 ..< w * h:
    open[i] = dist[i] >= minChamfer
  dist.setLen(0)
  if diagnosticWallMasks in artifacts:
    result.maxWall = maxWall
  else:
    maxWall.setLen(0)

  let
    redHome = gameMap.flagHome(Red)
    startIndex = redHome.y * w + redHome.x
  var
    reached = newSeq[bool](w * h)
    queue: seq[int]
  result.redHomeOnOpenFloor = open[startIndex]
  if not result.redHomeOnOpenFloor:
    recordFailure("red flag home is not on open floor")
  else:
    reached[startIndex] = true
    queue.add startIndex
  var head = 0
  while head < queue.len:
    let i = queue[head]
    inc head
    for step in [-1, 1, -w, w]:
      let j = i + step
      if j >= 0 and j < w * h and open[j] and not reached[j]:
        ## Row wrap at the border can't happen: the border ring is wall,
        ## so open[] is false along every edge.
        reached[j] = true
        queue.add j
  for team in gameMap.teams():
    if team == Red:
      continue
    let home = gameMap.flagHome(team)
    if not reached[home.y * w + home.x]:
      result.unreachableTeams.add team
      let message =
        if gameMap.teamCount() == 2:
          "no " & $MinCorridorWidth & "px route between the flags"
        else:
          "no " & $MinCorridorWidth & "px route to the " &
            teamText(team) & " flag"
      recordFailure(message)
  result.centerReachable = reached[gameMap.center.y * w + gameMap.center.x]
  if not result.centerReachable:
    recordFailure("no " & $MinCorridorWidth & "px route to the center")

  ## Compact endzones must stay OPEN-FLANKED: a base you can only be reached
  ## from the field side is just a column endzone with extra steps. Checked
  ## on Red alone — mirror and rot180 hand Blue the exact image.
  if gameMap.endzone != ezColumn:
    let
      anchor = gameMap.teamAnchor(Red)
      gate = gameMap.endzoneRadius + MinCorridorWidth div 2 + 4
      gates = [
        (name: "behind", point: MapPoint(x: anchor.x - gate, y: anchor.y)),
        (name: "above", point: MapPoint(x: anchor.x, y: anchor.y - gate)),
        (name: "below", point: MapPoint(x: anchor.x, y: anchor.y + gate)),
        (name: "ahead", point: MapPoint(x: anchor.x + gate, y: anchor.y)),
      ]
    var allGatesOpen = true
    for g in gates:
      var state = gateOpen
      if g.point.x < 0 or g.point.y < 0 or
          g.point.x >= w or g.point.y >= h:
        state = gateOffMap
        allGatesOpen = false
        recordFailure("endzone gate " & g.name & " is off the map")
      elif not reached[g.point.y * w + g.point.x]:
        state = gateSealed
        allGatesOpen = false
        recordFailure("endzone gate " & g.name & " is sealed")
      result.endzoneGates.add EndzoneGateDiagnostic(
        name: g.name, point: g.point, state: state)

    ## ...and the way in from behind must not run THROUGH the endzone: fill
    ## from the rear gate with the zone itself forbidden and demand the
    ## center. That is the whole point of moving the base off the edge.
    if allGatesOpen:
      let zone = gameMap.captureZone(Red)
      var
        around = newSeq[bool](w * h)
        backQueue = @[gates[0].point.y * w + gates[0].point.x]
      result.endzoneFlankChecked = true
      around[backQueue[0]] = true
      head = 0
      while head < backQueue.len:
        let i = backQueue[head]
        inc head
        for step in [-1, 1, -w, w]:
          let j = i + step
          if j < 0 or j >= w * h or not open[j] or around[j]:
            continue
          if zone.inCaptureZone(j mod w, j div w):
            continue
          around[j] = true
          backQueue.add j
      result.rearGateReachesCenterWithoutEndzone =
        around[gameMap.center.y * w + gameMap.center.x]
      if not result.rearGateReachesCenterWithoutEndzone:
        recordFailure("no route around the endzone from behind the base")

  if diagnosticCorridorOpen in artifacts:
    result.corridorOpen = open
  if diagnosticReachable in artifacts:
    result.reachable = reached

proc mapDiagnostics*(
  gameMap: CtfMap,
  artifacts: set[MapDiagnosticArtifact] = {},
): MapDiagnostics =
  ## Computes every play-quality diagnostic for one map. Full-board artifact
  ## arrays are retained only when explicitly requested; scalar summaries and
  ## failure details are always complete.
  collectMapDiagnostics(gameMap, artifacts, stopAfterFirstFailure = false)

proc mapValidationReason*(diagnostics: MapDiagnostics): string =
  ## Returns the canonical first failure from a completed diagnostic pass.
  diagnostics.reason

proc validateGeneratedMap*(gameMap: CtfMap): string =
  ## Returns "" when the layout passes every play-quality invariant, else a
  ## human-readable failure reason. The generator's design intent lives HERE,
  ## not in the draws: anything that passes is fair game.
  collectMapDiagnostics(gameMap, {}, stopAfterFirstFailure = true).reason

proc generateCtfMap*(
  seed: int,
  overrides = MapGenOverrides(windows: -1, pits: -1, pitDensity: -1),
  teams = 2
): CtfMap =
  ## Generates a VALIDATED map: attempts seeds seed, seed+1, ... until one
  ## passes every validator. A locked-parameter combination that can never
  ## pass errors out after MapGenMaxAttempts.
  for attempt in 0 ..< MapGenMaxAttempts:
    let candidate = generateMapAttempt(seed + attempt, overrides, teams)
    if validateGeneratedMap(candidate).len == 0:
      return candidate
  raise newException(
    CtfError,
    "Map generation found no valid layout in " & $MapGenMaxAttempts &
      " attempts from seed " & $seed & " (over-constrained overrides?)."
  )

proc poolCtfMap*(
  index: int, overrides = MapGenOverrides(windows: -1, pits: -1, pitDensity: -1)
): CtfMap =
  ## One curated-pool map; the index wraps around the pool.
  let n = MapPoolSeeds.len
  generateCtfMap(MapPoolSeeds[((index mod n) + n) mod n], overrides)

proc shapeSpecNode(shape: ArenaShape): JsonNode =
  ## One obstacle as replay-spec JSON.
  result = newJObject()
  case shape.kind
  of shapeRect:
    result["kind"] = %"rect"
    result["x"] = %shape.rect.x
    result["y"] = %shape.rect.y
    result["w"] = %shape.rect.w
    result["h"] = %shape.rect.h
  of shapeDisc, shapeDiamond:
    result["kind"] = %(if shape.kind == shapeDisc: "disc" else: "diamond")
    result["cx"] = %shape.cx
    result["cy"] = %shape.cy
    result["r"] = %shape.radius
  of shapeDiagonal:
    result["kind"] = %"diagonal"
    result["x0"] = %shape.x0
    result["y0"] = %shape.y0
    result["x1"] = %shape.x1
    result["y1"] = %shape.y1
    result["t"] = %shape.thickness
  of shapePolygon:
    result["kind"] = %"polygon"
    var pts = newJArray()
    for p in shape.points:
      pts.add %*[p.x, p.y]
    result["points"] = pts
  if shape.window:
    result["window"] = %true

proc shapeFromSpecNode(node: JsonNode): ArenaShape =
  ## One obstacle parsed back from replay-spec JSON.
  let window = node{"window"}.getBool(false)
  case node["kind"].getStr()
  of "rect":
    ArenaShape(kind: shapeRect, window: window, rect: MapRect(
      x: node["x"].getInt(), y: node["y"].getInt(),
      w: node["w"].getInt(), h: node["h"].getInt()))
  of "disc":
    ArenaShape(kind: shapeDisc, window: window,
      cx: node["cx"].getInt(), cy: node["cy"].getInt(),
      radius: node["r"].getInt())
  of "diamond":
    ArenaShape(kind: shapeDiamond, window: window,
      cx: node["cx"].getInt(), cy: node["cy"].getInt(),
      radius: node["r"].getInt())
  of "diagonal":
    ArenaShape(kind: shapeDiagonal, window: window,
      x0: node["x0"].getInt(), y0: node["y0"].getInt(),
      x1: node["x1"].getInt(), y1: node["y1"].getInt(),
      thickness: node["t"].getInt())
  of "polygon":
    var pts: seq[MapPoint]
    for pt in node["points"]:
      pts.add MapPoint(x: pt[0].getInt(), y: pt[1].getInt())
    ArenaShape(kind: shapePolygon, window: window, points: pts)
  else:
    raise newException(
      CtfError, "Unknown map spec shape: " & node["kind"].getStr())

proc pointsNode(points: seq[MapPoint]): JsonNode =
  result = newJArray()
  for p in points:
    result.add %*[p.x, p.y]

proc pointsFromNode(node: JsonNode): seq[MapPoint] =
  if node.isNil or node.kind != JArray:
    return                        # absent optional key (e.g. teamPickups.*) -> empty
  for item in node:
    result.add MapPoint(x: item[0].getInt(), y: item[1].getInt())

proc rectsNode(rects: seq[MapRect]): JsonNode =
  result = newJArray()
  for r in rects:
    result.add %*[r.x, r.y, r.w, r.h]

proc rectsFromNode(node: JsonNode): seq[MapRect] =
  if node.isNil or node.kind != JArray:
    return
  for item in node:
    result.add MapRect(
      x: item[0].getInt(), y: item[1].getInt(),
      w: item[2].getInt(), h: item[3].getInt()
    )

proc mapSpecJson*(gameMap: CtfMap): string =
  ## The FULL expanded geometry of one map as JSON. Replays pin this, so
  ## playback rebuilds the exact map even if the generator changes later.
  var shapes = newJArray()
  for shape in gameMap.leftObstacles:
    shapes.add shape.shapeSpecNode()
  var trenchShapes = newJArray()
  for trench in gameMap.trenches:
    trenchShapes.add trench.shapeSpecNode()
  let spec = %*{
    "name": gameMap.name,
    "genSeed": gameMap.genSeed,
    "width": gameMap.width,
    "height": gameMap.height,
    "flagRing": gameMap.flagRing,
    "captureClear": gameMap.captureClear,
    "spawnClearW": gameMap.spawnClearW,
    "spawnClearH": gameMap.spawnClearH,
    "gunRange": gameMap.gunRange,
    "symmetry": (
      case gameMap.symmetry
      of symMirror: "mirror"
      of symRot180: "rot180"
      of symRot90: "rot90"
      of symQuadMirror: "quadmirror"
      of symNone: "none"),          # round-trips with the parse at ~L3086
    "layout": (
      case gameMap.layout
      of layoutSides: "sides"
      of layoutCorners: "corners"
      of layoutPlus: "plus"),
    "endzone": (
      case gameMap.endzone
      of ezColumn: "column"
      of ezDisc: "disc"
      of ezSquare: "square"),
    "endzoneRadius": gameMap.endzoneRadius,
    "homeDepth": gameMap.homeDepthOf(),
    "medKitSpawns": pointsNode(gameMap.medKitSpawns),
    "medKitCandidates": pointsNode(gameMap.medKitCandidates),
    # Trenches are FULL-map (both halves), already symmetrized — playback
    # re-reads them verbatim, no re-mirroring. Serialized as shapes (the
    # generator emits rect pits; authored maps may use any shape).
    "trenches": trenchShapes,
    "leftObstacles": shapes,
  }
  ## Puddles pin only when present: an unconditional (empty) key would
  ## change every puddle-free pinned spec — and with it every default
  ## fixture's config echo — for nothing.
  if gameMap.puddles.len > 0:
    ## Each puddle pins as its disc list, [[cx, cy, r], ...] — the exact
    ## splat cluster, so playback re-derives identical membership.
    var puddleNodes = newJArray()
    for puddle in gameMap.puddles:
      var spots = newJArray()
      for s in puddle.spots:
        spots.add %*[s.cx, s.cy, s.r]
      puddleNodes.add spots
    spec["puddles"] = puddleNodes
  ## Explicit per-team pickups pin only when present (symNone maps): an
  ## unconditional key would change every existing pinned spec's echo for
  ## nothing. Round-trips with the teamPickups parse in mapFromSpecJson.
  if gameMap.teamPickups.shields.len > 0 or gameMap.teamPickups.cans.len > 0 or
      gameMap.teamPickups.barriers.len > 0:
    spec["teamPickups"] = %*{
      "shields": pointsNode(gameMap.teamPickups.shields),
      "cans": pointsNode(gameMap.teamPickups.cans),
      "barriers": pointsNode(gameMap.teamPickups.barriers),
    }
  $spec

proc mapFromSpecJson*(text: string): CtfMap =
  ## Rebuilds one map from its expanded replay spec. Rooms are derived from
  ## the clearances the same way the generator derives them.
  var node: JsonNode
  try:
    node = fromJson(text)
  except jsony.JsonError as e:
    raise newException(CtfError, "Could not parse map spec JSON: " & e.msg)
  result.name = node["name"].getStr()
  result.path = GenMapName
  result.genSeed = node{"genSeed"}.getInt(0)
  result.width = node["width"].getInt()
  result.height = node["height"].getInt()
  result.mapLayer = 0
  result.walkLayer = 1
  result.wallLayer = 2
  result.center = MapPoint(x: result.width div 2, y: result.height div 2)
  result.flagRing = node["flagRing"].getInt()
  result.captureClear = node["captureClear"].getInt()
  result.spawnClearW = node["spawnClearW"].getInt()
  result.spawnClearH = node["spawnClearH"].getInt()
  result.gunRange = node["gunRange"].getInt()
  ## Missing keys default for pre-4-team pinned specs; an unknown NON-EMPTY
  ## value is a typo or a spec from a future version — replays pin specs
  ## precisely so playback is exact, so silently reinterpreting one would
  ## defeat the point. Raise instead.
  let symmetryText = node{"symmetry"}.getStr("mirror")
  result.symmetry =
    case symmetryText
    of "mirror": symMirror
    of "rot180": symRot180
    of "rot90": symRot90
    of "quadmirror": symQuadMirror
    of "none": symNone          # coworld-ctf#280 full-board authoring (no lift)
    else:
      raise newException(
        CtfError, "Unknown map spec symmetry: " & symmetryText)
  let layoutText = node{"layout"}.getStr("sides")
  result.layout =
    case layoutText
    of "sides": layoutSides
    of "corners": layoutCorners
    of "plus": layoutPlus
    else:
      raise newException(CtfError, "Unknown map spec layout: " & layoutText)
  let endzoneText = node{"endzone"}.getStr("column")
  result.endzone =
    case endzoneText
    of "column": ezColumn
    of "disc": ezDisc
    of "square": ezSquare
    else:
      raise newException(CtfError, "Unknown map spec endzone: " & endzoneText)
  result.endzoneRadius = node{"endzoneRadius"}.getInt(0)
  result.homeDepth = node{"homeDepth"}.getInt(ClassicHomeDepth)
  result.medKitSpawns = pointsFromNode(node["medKitSpawns"])
  result.medKitCandidates = pointsFromNode(node["medKitCandidates"])
  ## Optional: specs pinned before trenches existed carry none and replay
  ## without them, exactly as recorded. Back-compat: GV<=36 pinned trenches as
  ## [x, y, w, h] arrays; GV37+ pins them as shape objects (any kind). Detect
  ## per element so old replays and pool specs still load verbatim.
  let trenchNode = node{"trenches"}
  if not trenchNode.isNil and trenchNode.kind == JArray:
    for item in trenchNode:
      if item.kind == JArray:
        result.trenches.add rectShape(MapRect(
          x: item[0].getInt(), y: item[1].getInt(),
          w: item[2].getInt(), h: item[3].getInt()))
      else:
        result.trenches.add item.shapeFromSpecNode()
  ## Optional like trenches: specs pinned before puddles existed carry none
  ## and replay without them, exactly as recorded.
  let puddleNode = node{"puddles"}
  if not puddleNode.isNil and puddleNode.kind == JArray:
    for item in puddleNode:
      var puddle: Puddle
      for spot in item:
        puddle.spots.add PuddleSpot(
          cx: spot[0].getInt(), cy: spot[1].getInt(), r: spot[2].getInt())
      result.puddles.add puddle
  for item in node["leftObstacles"]:
    result.leftObstacles.add item.shapeFromSpecNode()
  ## Optional: EXPLICIT per-team pickup points (coworld-ctf#280). Only symNone
  ## maps carry these; symmetric maps derive pickups from the orbit and leave
  ## the object absent. Present or not, parse what is there — validateMap
  ## enforces the symNone requirement.
  let tpNode = node{"teamPickups"}
  if not tpNode.isNil and tpNode.kind == JObject:
    result.teamPickups.shields = pointsFromNode(tpNode{"shields"})
    result.teamPickups.cans = pointsFromNode(tpNode{"cans"})
    result.teamPickups.barriers = pointsFromNode(tpNode{"barriers"})
  result.rooms = result.defaultCtfRooms()
  result.validateMap()
  result.validateMapWalkability()   # symNone explicit-pickup wall-overlap check (#280)

proc resolveCtfMapMetadata*(config: GameConfig): CtfMap =
  ## The effective map for one config: an explicit mapSpec wins (replay
  ## exactness), then the named maps, then the generator / curated pool.
  ## The resolved map's team count must match the config's `teams` knob —
  ## a 4-team game needs a generated corner/plus map (or a pinned spec).
  result =
    if config.mapSpec.len > 0:
      mapFromSpecJson(config.mapSpec)
    else:
      let
        name = if config.mapPath.len == 0: DefaultMapPath else: config.mapPath
        genSeed = if config.mapSeed != -1: config.mapSeed else: config.seed
      case name
      of ArenaName: arenaCtfMap()
      of ArenaLargeName: arenaLargeCtfMap()
      of GenMapName: generateCtfMap(genSeed, config.mapGen, config.teams)
      of PoolMapName:
        if config.teams != 2:
          raise newException(
            CtfError, "The curated pool is 2-team; use mapPath gen for " &
              $config.teams & " teams.")
        let index =
          if config.mapPoolIndex >= 0: config.mapPoolIndex else: genSeed
        poolCtfMap(index, config.mapGen)
      else:
        raise newException(CtfError, "Unknown map: " & name)
  if result.teamCount() != config.teams:
    raise newException(
      CtfError, "Config asks for " & $config.teams & " teams but map " &
        result.name & " seats " & $result.teamCount() & ".")

## The SELECTED map's layout, installed once per process by loadCtfMap and
## initialized to the default arena below so tooling that never selects a
## map observes a complete default state, never an empty one.
var
  ArenaMapG = arenaCtfMap()
    ## The selected map backing pure-map wrappers used by the installed arena
    ## renderer. Editor/tool rendering never reads this process global.
  ArenaFlagRing = 70
  ArenaCaptureClear = 210
  ArenaLayoutG = layoutSides
  ArenaSymmetryG* = symMirror
    ## The installed map's symmetry; diamondSpinFrame's default direction
    ## rule reads it (exported for that default parameter).
  ArenaTeamCount = 2
  ArenaAnchors: array[Team, MapPoint]
  ArenaPocketHalf: array[Team, tuple[w, h: int]]
  ArenaPlusArmHalf = 0
  ArenaEndzoneRadius = 0     ## > 0 selects the COMPACT endzone floor rules.
  ArenaEndzoneDisc = false   ## compact endzone is a disc, not a square.
  ArenaObstacles*: seq[ArenaShape]
  AnimatedDiamonds*: seq[tuple[cx, cy, radius: int]]
  ArenaSpinMirrored* = true
    ## True when this map's symmetry is the classic x-REFLECTION, so
    ## mirror-image diamonds must spin in opposite directions. False on
    ## rotationally symmetric maps (rot180 / rot90), where every diamond
    ## turns together, and on quad-mirror maps, whose per-axis direction
    ## rule reads ArenaSymmetryG instead — see diamondSpinDir.
  ArenaTrenches*: seq[ArenaShape]
  ArenaPuddles*: seq[Puddle]

proc selectCtfMap(gameMap: CtfMap) =
  ## Installs one map as THE map for this process: dimensions, fog grid,
  ## map-relative ranges, layout clearances, and the mirrored obstacle set.
  ## Runs before any sim, mask, or render work; the render bakes in
  ## global.nim assume the arena never changes afterward.
  ArenaMapG = gameMap
  MapWidth = gameMap.width
  MapHeight = gameMap.height
  FovGridW = (MapWidth + FovCellSize - 1) div FovCellSize
  FovGridH = (MapHeight + FovCellSize - 1) div FovCellSize
  FovCellCount = FovGridW * FovGridH
  GrenadeMaxRange = MapWidth div 5
  ShoutRange = MapWidth div 5
  ArenaFlagRing = gameMap.flagRing
  ArenaCaptureClear = gameMap.captureClear
  ArenaLayoutG = gameMap.layout
  ArenaSymmetryG = gameMap.symmetry
  ArenaTeamCount = gameMap.teamCount()
  for team in gameMap.teams():
    ArenaAnchors[team] = gameMap.teamAnchor(team)
    ArenaPocketHalf[team] = gameMap.spawnPocketHalf(team)
  ArenaPlusArmHalf = gameMap.plusArmHalf()
  ArenaEndzoneRadius =
    if gameMap.endzone == ezColumn: 0 else: gameMap.endzoneRadius
  ArenaEndzoneDisc = gameMap.endzone == ezDisc
  ArenaObstacles = buildArenaObstacles(gameMap)
  AnimatedDiamonds = buildAnimatedDiamonds(gameMap, ArenaObstacles)
  ArenaSpinMirrored = gameMap.symmetry == symMirror
  ArenaTrenches = gameMap.trenches
  ArenaPuddles = gameMap.puddles

proc installDefaultArena*() =
  ## Installs the hand-tuned default arena into the process-wide map globals.
  ## Stage 6 of docs/plans/2026-08-01-sim-split.md replaced the old
  ## import-time `selectCtfMap(arenaCtfMap())` side effect with this explicit
  ## call: constructing any sim (initSimServer -> loadCtfMap) installs its
  ## config's map anyway, so this matters only for code that touches the
  ## installed-map globals BEFORE building a sim (test scaffolding, tools
  ## that query geometry standalone).
  selectCtfMap(arenaCtfMap())

proc loadCtfMapMetadata*(path = ""): CtfMap =
  ## Returns one map's metadata WITHOUT installing it as the process map.
  ## Accepts "arena", "arena-large", "gen[:seed]", and "pool[:index]" (the
  ## suffix-less generated forms use seed/index 0); tooling convenience —
  ## servers resolve through the GameConfig overload instead.
  let name = if path.len == 0: DefaultMapPath else: path
  case name
  of ArenaName: arenaCtfMap()
  of ArenaLargeName: arenaLargeCtfMap()
  else:
    let parts = name.split(':')
    var suffix = 0
    if parts.len == 2:
      try:
        suffix = parseInt(parts[1])
      except ValueError:
        raise newException(CtfError, "Unknown map: " & name)
    if parts.len <= 2 and parts[0] == GenMapName:
      generateCtfMap(suffix)
    elif parts.len <= 2 and parts[0] == PoolMapName:
      poolCtfMap(suffix)
    else:
      raise newException(CtfError, "Unknown map: " & name)

proc loadCtfMapMetadata*(config: GameConfig): CtfMap =
  ## GameConfig-driven metadata: honors mapSpec, mapSeed, pool picks, and
  ## the generator overrides.
  resolveCtfMapMetadata(config)

proc loadCtfMap*(path = ""): CtfMap =
  ## Returns the named map ("arena" is the default; "arena-large" is the
  ## 30%-larger variant; "gen:<seed>"/"pool:<index>" the generated forms)
  ## and installs it as this process's arena.
  result = loadCtfMapMetadata(path)
  selectCtfMap(result)

proc loadCtfMap*(config: GameConfig): CtfMap =
  ## Resolves the config's effective map and installs it as this process's
  ## arena.
  result = resolveCtfMapMetadata(config)
  selectCtfMap(result)

proc trenchIndexAt*(x, y: int): int =
  ## Returns the index of the trench containing map pixel (x, y), or -1 when
  ## the point is in the open field.
  for i, trench in ArenaTrenches:
    if inShape(x, y, trench):
      return i
  -1

proc playerTrench*(sim: SimServer, playerIndex: int): int =
  ## Returns the index of the trench the player's center is standing in,
  ## or -1 in the open field. Occupancy is instantaneous: the slowdowns and
  ## the fly-over shot misses apply exactly while the center is inside.
  trenchIndexAt(
    sim.players[playerIndex].x + CollisionW div 2,
    sim.players[playerIndex].y + CollisionH div 2
  )

proc puddleIndexAt*(x, y: int): int =
  ## Returns the index of the puddle containing map pixel (x, y), or -1 when
  ## the point is on clean floor.
  for i, puddle in ArenaPuddles:
    if inPuddle(x, y, puddle):
      return i
  -1

proc playerPuddle*(sim: SimServer, playerIndex: int): int =
  ## Returns the index of the puddle the player's center is standing in, or
  ## -1 on clean floor. Center-based like trench occupancy: the damage clock
  ## runs exactly while the center is inside.
  puddleIndexAt(
    sim.players[playerIndex].x + CollisionW div 2,
    sim.players[playerIndex].y + CollisionH div 2
  )

proc isAnimatedDiamondPixel*(x, y: int): bool =
  ## Returns true when (x, y) lies inside one of the rotating center diamonds
  ## at rest (frame 0). This is the BAKE-TIME predicate: it tells the art and
  ## the collision bake which pixels to leave empty because the live shape is
  ## stamped per frame instead. For "is this stone right now", ask the wall
  ## mask (or animatedDiamondCovers with the tick's frame).
  for spot in AnimatedDiamonds:
    if abs(x - spot.cx) + abs(y - spot.cy) <= spot.radius:
      return true
  false

proc inShapeF*(x, y: float, shape: ArenaShape): bool =
  ## Float-coordinate inShape: the render-scale rasterizer evaluates the same
  ## geometry at sub-pixel positions for crisp high-resolution wall edges.
  ## Collision and FOV keep using the integer predicate; the two may disagree
  ## by less than one map pixel along shape boundaries, which is invisible.
  case shape.kind
  of shapeRect:
    x >= float(shape.rect.x) and x < float(shape.rect.x + shape.rect.w) and
      y >= float(shape.rect.y) and y < float(shape.rect.y + shape.rect.h)
  of shapeDisc:
    let
      dx = x - float(shape.cx)
      dy = y - float(shape.cy)
    dx * dx + dy * dy <= float(shape.radius * shape.radius)
  of shapeDiamond:
    abs(x - float(shape.cx)) + abs(y - float(shape.cy)) <=
      float(shape.radius)
  of shapePolygon:
    ## Float even-odd for the render rasterizer. Render need not be bit-exact
    ## with the integer predicate (they may disagree by <1px on the boundary,
    ## as the doc for this proc notes); the integer `inShape` is what collision,
    ## FOV, and symmetry use.
    if shape.points.len < 3:
      false
    else:
      var
        inside = false
        j = shape.points.len - 1
      for i in 0 ..< shape.points.len:
        let
          xi = float(shape.points[i].x)
          yi = float(shape.points[i].y)
          xj = float(shape.points[j].x)
          yj = float(shape.points[j].y)
        if (yi > y) != (yj > y):
          if x < xi + (xj - xi) * (y - yi) / (yj - yi):
            inside = not inside
        j = i
      inside
  of shapeDiagonal:
    let
      vx = float(shape.x1 - shape.x0)
      vy = float(shape.y1 - shape.y0)
      wx = x - float(shape.x0)
      wy = y - float(shape.y0)
      len2 = vx * vx + vy * vy
      t = clamp(wx * vx + wy * vy, 0.0, len2)
      dx = wx * len2 - t * vx
      dy = wy * len2 - t * vy
    dx * dx + dy * dy <=
      float(shape.thickness * shape.thickness) * len2 * len2 / 4.0

proc arenaCenterOffset2(x, y, cx, cy: int): tuple[dx, dy: int] {.inline.} =
  ## The installed-map twin of CtfMap.centerOffset2: twice the offset from
  ## the symmetry center, measured against a 4-team board's true axes at
  ## ((w-1)/2, (h-1)/2) and against the integer center everywhere else.
  if ArenaSymmetryG in {symRot90, symQuadMirror}:
    (2 * x - (MapWidth - 1), 2 * y - (MapHeight - 1))
  else:
    (2 * (x - cx), 2 * (y - cy))

proc isProtectedFloor*(x, y, cx, cy: int): bool =
  ## Regions that MUST stay walkable: the flag ring, every spawn pocket,
  ## and each team's home capture approach. Walls are never carved here.
  if ArenaEndzoneRadius > 0:
    ## COMPACT endzones: the shape around each base plus the center ring.
    ## The home border strips are ordinary field (see mapProtectedFloorAt).
    for team in activeTeams(ArenaTeamCount):
      if endzoneFloorAt(x, y, ArenaAnchors[team].x, ArenaAnchors[team].y,
          ArenaEndzoneRadius, ArenaEndzoneDisc):
        return true
    let
      rdx = x - cx
      rdy = y - cy
    return rdx * rdx + rdy * rdy <= ArenaFlagRing * ArenaFlagRing
  ## The classic column path below must stay pixel-for-pixel identical to
  ## mapProtectedFloorAt, which the generator and validators run on
  ## uninstalled candidates. 4-team maps always draw ezColumn, so the
  ## rot90/quad-mirror boards are carved here, never by the compact branch.
  let
    nearX = x < ArenaCaptureClear or x >= MapWidth - ArenaCaptureClear
    nearY = y < ArenaCaptureClear or y >= MapHeight - ArenaCaptureClear
    (dx2, dy2) = arenaCenterOffset2(x, y, cx, cy)
    approach =
      case ArenaLayoutG
      of layoutSides:
        nearX
      of layoutCorners:
        nearX and nearY
      of layoutPlus:
        (nearX and abs(dy2) <= 2 * ArenaPlusArmHalf) or
          (nearY and abs(dx2) <= 2 * ArenaPlusArmHalf)
  if approach:
    return true
  if dx2 * dx2 + dy2 * dy2 <= 4 * ArenaFlagRing * ArenaFlagRing:
    return true
  for team in activeTeams(ArenaTeamCount):
    if abs(x - ArenaAnchors[team].x) <= ArenaPocketHalf[team].w and
        abs(y - ArenaAnchors[team].y) <= ArenaPocketHalf[team].h:
      return true
  false

proc isArenaWall*(x, y, cx, cy: int): bool =
  ## Returns true when (x, y) is a wall pixel on the generated arena.
  if x < ArenaBorder or y < ArenaBorder or
      x >= MapWidth - ArenaBorder or y >= MapHeight - ArenaBorder:
    return true
  if isProtectedFloor(x, y, cx, cy):
    return false
  for shape in ArenaObstacles:
    if inShape(x, y, shape):
      return true
  false

proc isArenaWindowPixel*(x, y, cx, cy: int): bool =
  ## Returns true when (x, y) is a GLASS pixel: a wall pixel that belongs to a
  ## window shape. Glass stays in the collision/shot wall mask but is excluded
  ## from the fog-of-war occlusion build, so vision passes through it.
  if not isArenaWall(x, y, cx, cy):
    return false
  for shape in ArenaObstacles:
    if shape.window and inShape(x, y, shape):
      return true
  false

proc mapProtectedFloorAtF*(
  gameMap: CtfMap, x, y: float, cx, cy: int
): bool =
  ## Float-coordinate mapProtectedFloorAt for a map that is NOT installed as
  ## the process map. Render tools use this form so concurrent arbitrary-spec
  ## renders never read or mutate the installed arena globals.
  if gameMap.endzone != ezColumn:
    let grown = float(gameMap.endzoneRadius + EndzoneWallMargin)
    for team in gameMap.teams():
      let anchor = gameMap.teamAnchor(team)
      let
        adx = abs(x - float(anchor.x))
        ady = abs(y - float(anchor.y))
      if adx > grown or ady > grown:
        continue
      if gameMap.endzone != ezDisc or
          adx * adx + ady * ady <= grown * grown:
        return true
    let
      rdx = x - float(cx)
      rdy = y - float(cy)
    return rdx * rdx + rdy * rdy <=
      float(gameMap.flagRing * gameMap.flagRing)
  ## Carries the same doubled-coordinate center as the integer test so the
  ## painted art cannot drift off the collision mask on a 4-team board.
  let
    nearX = x < float(gameMap.captureClear) or
      x >= float(gameMap.width - gameMap.captureClear)
    nearY = y < float(gameMap.captureClear) or
      y >= float(gameMap.height - gameMap.captureClear)
    (dx2, dy2) =
      if gameMap.symmetry in {symRot90, symQuadMirror}:
        (2.0 * x - float(gameMap.width - 1),
          2.0 * y - float(gameMap.height - 1))
      else:
        (2.0 * (x - float(cx)), 2.0 * (y - float(cy)))
    approach =
      case gameMap.layout
      of layoutSides:
        nearX
      of layoutCorners:
        nearX and nearY
      of layoutPlus:
        let arm = gameMap.plusArmHalf()
        (nearX and abs(dy2) <= float(2 * arm)) or
          (nearY and abs(dx2) <= float(2 * arm))
  if approach:
    return true
  if dx2 * dx2 + dy2 * dy2 <=
      float(4 * gameMap.flagRing * gameMap.flagRing):
    return true
  for team in gameMap.teams():
    let
      anchor = gameMap.teamAnchor(team)
      half = gameMap.spawnPocketHalf(team)
    if abs(x - float(anchor.x)) <= float(half.w) and
        abs(y - float(anchor.y)) <= float(half.h):
      return true
  false

proc mapObstacleWallAtF*(
  gameMap: CtfMap,
  obstacles: openArray[ArenaShape],
  x, y: float,
  cx, cy: int,
): bool =
  ## Float-coordinate interior-obstacle test for an uninstalled map. The
  ## border ring is excluded because renderers draw it as separate slabs.
  if mapProtectedFloorAtF(gameMap, x, y, cx, cy):
    return false
  for shape in obstacles:
    if inShapeF(x, y, shape):
      return true
  false

proc obstacleWallAtF*(x, y: float, cx, cy: int): bool =
  ## Float-coordinate interior-obstacle test (the border ring excluded);
  ## the high-resolution renderer draws the border as separate slabs.
  mapObstacleWallAtF(ArenaMapG, ArenaObstacles, x, y, cx, cy)

proc mapShapeWallAtF*(
  gameMap: CtfMap,
  x, y: float,
  shape: ArenaShape,
  cx, cy: int,
): bool =
  ## Float-coordinate test for one uninstalled-map shape with the canonical
  ## protected-floor carve applied.
  inShapeF(x, y, shape) and
    not mapProtectedFloorAtF(gameMap, x, y, cx, cy)

proc shapeWallAtF*(x, y: float, shape: ArenaShape, cx, cy: int): bool =
  ## Float-coordinate test for one shape with the protected-floor carve
  ## applied, matching what the integer wall mask keeps of that shape.
  mapShapeWallAtF(ArenaMapG, x, y, shape, cx, cy)

proc diamondSpinDir*(
  cx, cy: int, symmetry: MapSymmetry, width, height: int
): int {.inline.} =
  ## The spin direction (+1 / -1) of the diamond centered at (cx, cy) under
  ## one map symmetry.
  ##
  ## Direction has to follow the map's symmetry or the live footprint stops
  ## being symmetric even though the resting one is. A REFLECTION maps a
  ## rotation by +theta to one by -theta, so mirror-image diamonds must spin
  ## in OPPOSITE directions — the classic arena's two halves. A ROTATION
  ## commutes with rotation, so rot180 and rot90 image diamonds must spin the
  ## SAME way; giving them opposite directions (which the side-of-the-map rule
  ## does, since both symmetries move a diamond across the axis) makes the two
  ## halves of a rot180 map differ. On rotationally symmetric maps every
  ## diamond therefore turns together.
  ##
  ## QUAD-MIRROR composes one reflection per axis, so the direction flips
  ## once per axis crossing: sign(2cx-(w-1)) * sign(2cy-(h-1)) against the
  ## true axes. The x-mirror and y-mirror images of a diamond counter-rotate
  ## it and the rot180 image co-rotates it — exactly what each group element
  ## demands. A diamond ON an axis (sign 0) takes +1: it is its own image
  ## under that reflection, so either direction is self-consistent.
  case symmetry
  of symMirror, symNone:
    ## symNone is a 2-team sides board; use the mirror rule so the two halves'
    ## center-band diamonds counter-rotate (the classic arena feel). This is a
    ## per-diamond visual/collision rule read from position, independent of how
    ## the board was authored — no symmetry group is required for it.
    if 2 * cx >= width - 1: -1 else: 1
  of symRot180, symRot90:
    1
  of symQuadMirror:
    (if 2 * cx > width - 1: -1 else: 1) *
      (if 2 * cy > height - 1: -1 else: 1)

proc diamondSpinFrame*(
  cx, cy, tick: int,
  symmetry = ArenaSymmetryG,
  width = MapWidth,
  height = MapHeight
): int {.inline.} =
  ## The spin frame of the diamond centered at (cx, cy) on one tick. The
  ## frame derives only from the tick (direction from the symmetry rule in
  ## diamondSpinDir), so the renderer, the collision masks, and every replay
  ## viewer read the SAME angle. Single source of truth.
  ##
  ## `symmetry` / `width` / `height` default to the installed map, which is
  ## what every production caller wants; passing them explicitly lets the
  ## rule be checked against a map that is not the process map.
  diamondFrameIndex(
    (tick div DiamondSpinTicksPerFrame) *
      diamondSpinDir(cx, cy, symmetry, width, height))

proc animatedDiamondCovers*(
  spot: tuple[cx, cy, radius: int], frame, x, y: int
): bool {.inline.} =
  ## True when map pixel (x, y) is stone in one spinning diamond at `frame`.
  rotatedDiamondCovers(
    spot.radius, frame, 2 * (x - spot.cx), 2 * (y - spot.cy), 2)
