## Quad-mirror symmetry (GV39): rectangular 4-team maps completed by the
## Klein four-group (mirrorX, mirrorY, rot180) instead of rot90's quarter
## turns. The suite pins the exact-fairness invariants of the new symmetry
## (transform algebra, wall-mask reflection exactness, anchor/zone/pickup
## orbits, per-axis spin direction, spec round-trip) AND guards that the
## default 4-team draw is untouched (rot90, square, same draws).

import
  helpers,
  std/[sequtils, tables, unittest],
  bitworld/spriteprotocol,
  ctf/sim

const QuadOverrides = MapGenOverrides(
  size: "standard", symmetry: "quadmirror",
  windows: -1, pits: -1, pitDensity: -1)

var quadCache = initTable[string, CtfMap]()

proc quadMap(seed: int, layout = ""): CtfMap =
  ## generateCtfMap memoized (generation is deterministic; the determinism
  ## test below calls generateCtfMap directly, so the cache never hides it).
  let key = $seed & "|" & layout
  if key notin quadCache:
    var overrides = QuadOverrides
    overrides.layout = layout
    quadCache[key] = generateCtfMap(seed, overrides, teams = 4)
  quadCache[key]

proc sampleShapes(): seq[ArenaShape] =
  ## One shape of every kind, at generic (asymmetric) positions.
  @[
    ArenaShape(kind: shapeRect,
      rect: MapRect(x: 101, y: 57, w: 18, h: 62)),
    ArenaShape(kind: shapeDisc, cx: 233, cy: 91, radius: 28),
    ArenaShape(kind: shapeDiamond, window: true, cx: 307, cy: 143, radius: 30),
    ArenaShape(kind: shapeDiagonal,
      x0: 401, y0: 88, x1: 429, y1: 116, thickness: 12),
    ArenaShape(kind: shapePolygon, points: @[
      MapPoint(x: 500, y: 60), MapPoint(x: 540, y: 75),
      MapPoint(x: 531, y: 130), MapPoint(x: 497, y: 111)]),
  ]

suite "quad-mirror symmetry":
  test "mirrorY is an involution and mirrorY o mirrorX == rot180 on every kind":
    const
      w = 1235
      h = 659
    for shape in sampleShapes():
      check shape.mirrorY(h).mirrorY(h) == shape
      check shape.mirrorX(w).mirrorX(w) == shape
      check shape.mirrorX(w).mirrorY(h) == shape.rot180(w, h)
      check shape.mirrorY(h).mirrorX(w) == shape.rot180(w, h)

  test "buildArenaObstacles expands each quad seed into its four images":
    var gameMap = CtfMap(
      width: 1235, height: 659,
      center: MapPoint(x: 617, y: 329),
      symmetry: symQuadMirror, layout: layoutCorners,
      leftObstacles: sampleShapes())
    let full = buildArenaObstacles(gameMap)
    check full.len == 4 * gameMap.leftObstacles.len
    for shape in gameMap.leftObstacles:
      check shape in full
      check shape.mirrorX(gameMap.width) in full
      check shape.mirrorY(gameMap.height) in full
      check shape.rot180(gameMap.width, gameMap.height) in full
    ## symmetryImages agrees, for rects and points (deduplicated orbits).
    check gameMap.symmetryImages(MapRect(x: 10, y: 20, w: 5, h: 6)) == @[
      MapRect(x: 10, y: 20, w: 5, h: 6),
      MapRect(x: 1220, y: 20, w: 5, h: 6),
      MapRect(x: 10, y: 633, w: 5, h: 6),
      MapRect(x: 1220, y: 633, w: 5, h: 6)]
    check gameMap.symmetryImages(MapPoint(x: 33, y: 44)).len == 4
    ## A point on the vertical axis of an odd-width board dedups its
    ## mirrorX image away.
    var odd = CtfMap(width: 11, height: 9, symmetry: symQuadMirror)
    check odd.symmetryImages(MapPoint(x: 5, y: 2)) == @[
      MapPoint(x: 5, y: 2), MapPoint(x: 5, y: 6)]

  test "a generated quad-mirror map is rectangular, valid, and all teams reach":
    for seed in [1, 7, 21]:
      let gameMap = quadMap(seed)
      check gameMap.symmetry == symQuadMirror
      check gameMap.width > gameMap.height
      check gameMap.teamCount() == 4
      check validateGeneratedMap(gameMap) == ""
      let diag = mapDiagnostics(gameMap)
      check diag.unreachableTeams.len == 0
      check diag.centerReachable
    ## Same seed, same map — the quad path is deterministic too.
    check generateCtfMap(1, QuadOverrides, teams = 4) ==
      generateCtfMap(1, QuadOverrides, teams = 4)

  test "the wall mask is bit-identical under both reflections":
    ## THE fairness invariant: every silent parity bug (integer-center
    ## anchoring, half-pixel bands, non-commuting rasterization) shows up
    ## here. Sampled finer than the thinnest wall feature.
    for layout in ["corners", "plus"]:
      let
        gameMap = quadMap(3, layout)
        obstacles = buildArenaObstacles(gameMap)
        w = gameMap.width
        h = gameMap.height
      ## The protected-floor carve alone, at every pixel (cheap, and it is
      ## the layer that broke under rot90 — see test_mapgen).
      var carveMismatch = 0
      for y in 0 ..< h:
        for x in 0 ..< w:
          let seedFloor = mapProtectedFloorAt(gameMap, x, y)
          if seedFloor != mapProtectedFloorAt(gameMap, w - 1 - x, y) or
              seedFloor != mapProtectedFloorAt(gameMap, x, h - 1 - y):
            inc carveMismatch
      check carveMismatch == 0
      ## Then the full mask on a 5px grid.
      var wallMismatch = 0
      var x = ArenaBorder
      while x < w - ArenaBorder:
        var y = ArenaBorder
        while y < h - ArenaBorder:
          let seedWall = mapWallAt(gameMap, obstacles, x, y)
          if seedWall != mapWallAt(gameMap, obstacles, w - 1 - x, y) or
              seedWall != mapWallAt(gameMap, obstacles, x, h - 1 - y):
            inc wallMismatch
          y += 5
        x += 5
      check wallMismatch == 0

  test "corner anchors are the four reflections of Red's":
    let
      gameMap = quadMap(3, "corners")
      w = gameMap.width
      h = gameMap.height
      red = gameMap.teamAnchor(Red)
    check red.x < gameMap.center.x and red.y < gameMap.center.y
    check gameMap.teamAnchor(Blue) == MapPoint(x: w - 1 - red.x, y: red.y)
    check gameMap.teamAnchor(Green) == MapPoint(x: red.x, y: h - 1 - red.y)
    check gameMap.teamAnchor(Yellow) ==
      MapPoint(x: w - 1 - red.x, y: h - 1 - red.y)
    var homes: seq[MapPoint]
    for team in gameMap.teams():
      homes.add gameMap.teamAnchor(team)
      ## Reflections never transpose the axes: every pocket stays upright.
      check gameMap.spawnPocketHalf(team) ==
        (gameMap.spawnClearW, gameMap.spawnClearH)
    check homes.deduplicate().len == 4

  test "plus anchors: W/E are mirror-exact and N/S are mirror-exact":
    let
      gameMap = quadMap(3, "plus")
      w = gameMap.width
      h = gameMap.height
      red = gameMap.teamAnchor(Red)
      green = gameMap.teamAnchor(Green)
    ## Red west, Blue east = Red's exact mirrorX; Green north, Yellow
    ## south = Green's exact mirrorY. On a rectangle the W/E and N/S arm
    ## pairs are two congruence classes — each pair is bit-exact.
    check red.x < gameMap.center.x and red.y == gameMap.center.y
    check green.y < gameMap.center.y and green.x == gameMap.center.x
    check gameMap.teamAnchor(Blue) == MapPoint(x: w - 1 - red.x, y: red.y)
    check gameMap.teamAnchor(Yellow) ==
      MapPoint(x: green.x, y: h - 1 - green.y)
    ## The capture-zone mouths pair up the same way: Blue's zone is the
    ## x-reflection of Red's box, Yellow's the y-reflection of Green's, and
    ## each cross band is centered on its own TRUE axis.
    let
      west = gameMap.captureZone(Red)
      east = gameMap.captureZone(Blue)
      north = gameMap.captureZone(Green)
      south = gameMap.captureZone(Yellow)
    check west.yLo == east.yLo and west.yHi == east.yHi
    check west.xHi == w - 1 - east.xLo
    check west.yLo + west.yHi == h - 1
    check north.xLo == south.xLo and north.xHi == south.xHi
    check north.yHi == h - 1 - south.yLo
    check north.xLo + north.xHi == w - 1

  test "pickups and med kits ride the reflections":
    for layout in ["corners", "plus"]:
      let
        gameMap = quadMap(3, layout)
        w = gameMap.width
        h = gameMap.height
      ## Team-agnostic sets (grenades, med kits) are FULLY closed under the
      ## group: every point's x- and y-reflection is another point of the
      ## same set.
      var kitPoints: seq[tuple[x, y: int]]
      for kit in gameMap.medKitSpawns:
        kitPoints.add((kit.x, kit.y))
      for points in [@(gameMap.grenadeSpawnPoints()), kitPoints]:
        check points.len == 4
        check points.deduplicate().len == 4
        for point in points:
          check (w - 1 - point.x, point.y) in points
          check (point.x, h - 1 - point.y) in points
      ## Team-owned sets (shields, spray cans) pair up: Blue's copy is
      ## exactly Red's mirrorX, Yellow's exactly Green's mirrorY — the
      ## reflection that relates each team pair. (On plus maps mirrorX
      ## FIXES the N/S teams rather than swapping a pair, so the shield set
      ## alone is not closed under it; the shield-union-can set is, which
      ## the last block pins.)
      let
        shields = gameMap.shieldSpawnPoints()
        cans = gameMap.plasmaArcSpawnPoints()
      for points in [shields, cans]:
        check points.len == 4
        check points.deduplicate().len == 4
        check points[ord(Blue)] ==
          (w - 1 - points[ord(Red)].x, points[ord(Red)].y)
        if layout == "corners":
          ## Corner teams are one full group orbit of Red's copy.
          check points[ord(Green)] ==
            (points[ord(Red)].x, h - 1 - points[ord(Red)].y)
          check points[ord(Yellow)] ==
            (w - 1 - points[ord(Red)].x, h - 1 - points[ord(Red)].y)
        else:
          ## Plus pairs: W/E via mirrorX (above), N/S via mirrorY.
          check points[ord(Yellow)] ==
            (points[ord(Green)].x, h - 1 - points[ord(Green)].y)
        ## Each team's copy sits in its OWN endzone.
        for team in gameMap.teams():
          check gameMap.captureZone(team).inCaptureZone(
            points[ord(team)].x, points[ord(team)].y)
      ## The union of the two team-owned sets is closed under the whole
      ## group, so the board's pickup GEOMETRY is exactly symmetric even
      ## where a reflection fixes a team. (Team fairness itself never needs
      ## this — the pairwise checks above are the fairness invariant — and
      ## on plus maps the union closure is pixel-exact on odd-height boards
      ## like the standard class this suite generates, where the integer
      ## center sits on the true axis.)
      let union = shields & cans
      for point in union:
        check (w - 1 - point.x, point.y) in union
        check (point.x, h - 1 - point.y) in union
      for shield in shields:
        check shield notin cans

  test "mirror-image diamonds counter-rotate; the rot180 image co-rotates":
    const
      w = 1235
      h = 659
    let
      cx = 300
      cy = 200
    check diamondSpinDir(cx, cy, symQuadMirror, w, h) == 1
    check diamondSpinDir(w - 1 - cx, cy, symQuadMirror, w, h) == -1
    check diamondSpinDir(cx, h - 1 - cy, symQuadMirror, w, h) == -1
    check diamondSpinDir(w - 1 - cx, h - 1 - cy, symQuadMirror, w, h) == 1
    ## A diamond ON the vertical axis of an odd-width board is its own
    ## mirrorX image; the x-sign contributes +1 and only the y-side decides.
    check diamondSpinDir(5, 100, symQuadMirror, 11, 659) == 1
    check diamondSpinDir(5, 558, symQuadMirror, 11, 659) == -1
    ## Dead center (both axes) takes +1.
    check diamondSpinDir(5, 4, symQuadMirror, 11, 9) == 1
    ## Frame form: one tick-step turns the seed +1 and its x-mirror -1.
    let tick = DiamondSpinTicksPerFrame
    check diamondSpinFrame(cx, cy, tick, symQuadMirror, w, h) == 1
    check diamondSpinFrame(w - 1 - cx, cy, tick, symQuadMirror, w, h) ==
      DiamondSpinFrames - 1
    ## The existing rules are untouched: mirror keys on the side, rotations
    ## never invert.
    check diamondSpinDir(cx, cy, symMirror, w, h) == 1
    check diamondSpinDir(w - 1 - cx, cy, symMirror, w, h) == -1
    check diamondSpinDir(w - 1 - cx, h - 1 - cy, symRot180, w, h) == 1
    check diamondSpinDir(w - 1 - cx, h - 1 - cy, symRot90, w, h) == 1

  test "the live spinning footprint is symmetric under both reflections":
    ## The quad twin of test_spinning_diamonds' rot180/rot90 footprint test:
    ## the union of the selected diamonds' stone must map onto itself under
    ## BOTH reflections at every frame — which is exactly what the per-axis
    ## direction rule buys.
    let gameMap = quadMap(3, "corners")
    let chosen = buildAnimatedDiamonds(gameMap, buildArenaObstacles(gameMap))
    check chosen.len > 0
    ## The spinning set itself is closed under the group.
    for spot in chosen:
      for image in [
          (gameMap.width - 1 - spot.cx, spot.cy),
          (spot.cx, gameMap.height - 1 - spot.cy),
          (gameMap.width - 1 - spot.cx, gameMap.height - 1 - spot.cy)]:
        var found = false
        for other in chosen:
          if other.cx == image[0] and other.cy == image[1]:
            found = true
        check found
    proc coveredAt(x, y, tick: int): bool =
      for spot in chosen:
        if animatedDiamondCovers(
            spot,
            diamondSpinFrame(spot.cx, spot.cy, tick, gameMap.symmetry,
              gameMap.width, gameMap.height),
            x, y):
          return true
      false
    for frame in 0 ..< DiamondSpinFrames:
      let tick = frame * DiamondSpinTicksPerFrame
      var asymmetric = 0
      for spot in chosen:
        for dy in -spot.radius - 2 .. spot.radius + 2:
          for dx in -spot.radius - 2 .. spot.radius + 2:
            let
              x = spot.cx + dx
              y = spot.cy + dy
              covered = coveredAt(x, y, tick)
            if covered != coveredAt(gameMap.width - 1 - x, y, tick) or
                covered != coveredAt(x, gameMap.height - 1 - y, tick):
              inc asymmetric
      check asymmetric == 0

  test "map spec JSON round-trips symQuadMirror exactly":
    let gameMap = quadMap(1)
    let rebuilt = mapFromSpecJson(mapSpecJson(gameMap))
    check rebuilt.symmetry == symQuadMirror
    check rebuilt == gameMap

  test "a quad-mirror 4-team game boots and steps deterministically":
    proc runGame(): SimServer =
      var config = defaultGameConfig()
      config.teams = 4
      config.mapPath = "gen"
      config.mapSeed = 1
      config.mapGen = QuadOverrides
      result = initCtfForTest(config)
      for i in 0 ..< 4:
        discard result.addPlayer("p" & $i)
      result.startGame()
      let none = newSeq[InputState](0)
      for tick in 0 ..< 300:
        result.step(none, none)
    var a = runGame()
    let b = runGame()
    check a.gameMap.symmetry == symQuadMirror
    check a.gameMap.width > a.gameMap.height
    check a.gameHash() == b.gameHash()
    ## Every team's flag starts home on its own pedestal, on the rectangle.
    for team in a.teams():
      let home = a.gameMap.flagHome(team)
      check a.flags[team].x == home.x
      check a.flags[team].y == home.y

  test "trenches stay off quad-mirror maps":
    var overrides = QuadOverrides
    overrides.pits = 2
    expect CtfError:
      discard generateMapAttempt(1, overrides, teams = 4)

  test "sides maps refuse the 4-team symmetries":
    var gameMap = generateCtfMap(4242)
    gameMap.symmetry = symQuadMirror
    expect CtfError:
      discard mapFromSpecJson(mapSpecJson(gameMap))

  test "the default 4-team draw is untouched: rot90 on a square":
    ## Byte-identical existing behavior: no override (and an explicit rot90
    ## lock) still draw the square rot90 board, and both draws agree —
    ## the quad path must not shift any RNG stream.
    for seed in [13, 6]:
      let
        plain = generateMapAttempt(seed,
          MapGenOverrides(windows: -1, pits: -1, pitDensity: -1), teams = 4)
        locked = generateMapAttempt(seed,
          MapGenOverrides(symmetry: "rot90", windows: -1, pits: -1,
            pitDensity: -1), teams = 4)
      check plain.symmetry == symRot90
      check plain.width == plain.height
      check plain == locked
