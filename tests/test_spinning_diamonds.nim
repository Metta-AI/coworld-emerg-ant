import
  helpers,
  std/[math, os, unittest],
  bitworld/spriteprotocol,
  ctf/sim

proc tickOfFrame(cx, frame: int): int =
  ## The first tick on which the diamond centered at map-x `cx` shows `frame`.
  ## (cy = 0: the installed default arena is a MIRROR map, whose direction
  ## rule keys on cx alone.)
  for tick in 0 ..< DiamondSpinFrames * DiamondSpinTicksPerFrame:
    if diamondSpinFrame(cx, 0, tick) == frame:
      return tick
  -1

proc cornerPixel(spot: tuple[cx, cy, radius: int]):
    tuple[x, y: int] =
  ## A pixel on the diamond's resting east vertex line that the 45° frame
  ## vacates: at rest it is stone, half a quarter-turn later it is open floor.
  (spot.cx + spot.radius - 2, spot.cy)

proc turnedCornerPixel(spot: tuple[cx, cy, radius: int]):
    tuple[x, y: int] =
  ## Inside the 45° frame's southeast corner, outside the resting diamond.
  let offset = spot.radius * 2 div 3
  (spot.cx + offset, spot.cy + offset)

suite "spinning center diamonds are real geometry":
  test "every diamond turns and its silhouette IS the collision mask":
    var sim = twoTeamGame()
    check AnimatedDiamonds.len > 0
    for frame in 0 ..< DiamondSpinFrames:
      # Drive the geometry straight to a tick that shows this frame on the
      # left half; the right half mirrors, which the per-pixel compare covers.
      let tick = tickOfFrame(AnimatedDiamonds[0].cx, frame)
      check tick >= 0
      sim.applyDiamondGeometry(tick)
      for spot in AnimatedDiamonds:
        let spotFrame = diamondSpinFrame(spot.cx, spot.cy, tick)
        for y in spot.cy - spot.radius - 1 .. spot.cy + spot.radius + 1:
          for x in spot.cx - spot.radius - 1 .. spot.cx + spot.radius + 1:
            let expected = sim.isArtWall(x, y) or
              animatedDiamondCovers(spot, spotFrame, x, y)
            check sim.isWall(x, y) == expected
            check sim.isWalkable(x, y) == not expected

  test "a vertex that rotates away stops blocking movement and bullets":
    var sim = twoTeamGame()
    let
      spot = AnimatedDiamonds[0]
      (px, py) = cornerPixel(spot)
      restTick = tickOfFrame(spot.cx, 0)
      turnedTick = tickOfFrame(spot.cx, DiamondSpinFrames div 2)
      rayTop = spot.cy - spot.radius - 6
      rayBottom = spot.cy + spot.radius + 6
    sim.applyDiamondGeometry(restTick)
    check sim.isWall(px, py)
    check not sim.lineOfSightClear(px, rayTop, px, rayBottom)
    # Half a quarter-turn later the vertex has swung off this row: the pixel
    # the player sees as floor really is floor, and the shot goes through.
    sim.applyDiamondGeometry(turnedTick)
    check not sim.isWall(px, py)
    check sim.canOccupy(px, py)
    check sim.lineOfSightClear(px, rayTop, px, rayBottom)

  test "the fog occlusion grid follows the spin":
    var sim = twoTeamGame()
    let spot = AnimatedDiamonds[0]
    proc cellsAround(sim: SimServer, spot: tuple[cx, cy, radius: int]):
        seq[bool] =
      let
        (gx0, gy0) = fovCellAt(spot.cx - spot.radius, spot.cy - spot.radius)
        (gx1, gy1) = fovCellAt(spot.cx + spot.radius, spot.cy + spot.radius)
      for gy in gy0 .. gy1:
        for gx in gx0 .. gx1:
          result.add sim.fovBlocked[fovCellIndex(gx, gy)]
    sim.applyDiamondGeometry(tickOfFrame(spot.cx, 0))
    let atRest = sim.cellsAround(spot)
    sim.applyDiamondGeometry(tickOfFrame(spot.cx, DiamondSpinFrames div 2))
    let turned = sim.cellsAround(spot)
    # Vision is recomputed as the stone moves, not frozen at bake time: the
    # 45° frame occludes a different set of cells than the resting one.
    check atRest != turned

  test "the sweep pushes an engulfed player onto free floor":
    var sim = twoTeamGame()
    let spot = AnimatedDiamonds[0]
    sim.tickCount = tickOfFrame(spot.cx, DiamondSpinFrames div 2)
    sim.updateAnimatedDiamonds()
    # Stand exactly where the resting vertex will be — open floor right now.
    let (px, py) = cornerPixel(spot)
    check sim.canOccupy(px, py)
    sim.players[0].x = px
    sim.players[0].y = py
    sim.tickCount = tickOfFrame(spot.cx, 0)
    sim.updateAnimatedDiamonds()
    check sim.isWall(px, py)
    check sim.canOccupy(sim.players[0].x, sim.players[0].y)

  test "geometry is a pure function of the tick":
    var
      simA = twoTeamGame()
      simB = twoTeamGame()
    for tick in [0, 7, 33, 250]:
      simA.applyDiamondGeometry(tick)
      simB.applyDiamondGeometry(tick)
      for spot in AnimatedDiamonds:
        for y in spot.cy - spot.radius - 1 .. spot.cy + spot.radius + 1:
          for x in spot.cx - spot.radius - 1 .. spot.cx + spot.radius + 1:
            check simA.isWall(x, y) == simB.isWall(x, y)
    check simA.gameHash == simB.gameHash

  test "paint follows the live footprint, including pixels outside frame zero":
    var sim = twoTeamGame()
    let
      spot = AnimatedDiamonds[0]
      tick = tickOfFrame(spot.cx, DiamondSpinFrames div 2)
      (px, py) = turnedCornerPixel(spot)
    sim.tickCount = tick
    sim.applyDiamondGeometry(tick)
    check not isAnimatedDiamondPixel(px, py)
    check sim.isWall(px, py)
    check sim.animatedDiamondAt(px, py) == 0
    sim.addPaintStain(px, py, RedTeamColor, onWall = true)
    check sim.diamondStains.len == 1
    check sim.paintStains.len == 0

  test "the silhouette is the rotated diamond, not just whatever we stamped":
    ## Every other test here compares the mask against animatedDiamondCovers,
    ## which is the predicate that WROTE it — a typo in the fixed-point cosine
    ## table would move the drawn shape and the collision shape together and
    ## no assertion would notice. So check the predicate itself against an
    ## independent float rotation, and allow disagreement only within a pixel
    ## of the boundary, where integer rounding is entitled to differ.
    var offBoundary = 0
    for spot in AnimatedDiamonds:
      for frame in 0 ..< DiamondSpinFrames:
        let
          angle = float(frame) / float(DiamondSpinFrames) * PI / 2.0
          ca = cos(angle)
          sa = sin(angle)
        for dy in -spot.radius - 2 .. spot.radius + 2:
          for dx in -spot.radius - 2 .. spot.radius + 2:
            let
              rx = float(dx) * ca + float(dy) * sa
              ry = -float(dx) * sa + float(dy) * ca
              distance = abs(rx) + abs(ry)
              covered = animatedDiamondCovers(
                spot, frame, spot.cx + dx, spot.cy + dy)
            if covered != (distance <= float(spot.radius)) and
                abs(distance - float(spot.radius)) > 1.0:
              inc offBoundary
    check offBoundary == 0

    ## And frame 0 is exactly the diamond the art bake carves a hole for —
    ## isAnimatedDiamondPixel and the live footprint must not be two shapes.
    var restMismatch = 0
    for spot in AnimatedDiamonds:
      for dy in -spot.radius - 2 .. spot.radius + 2:
        for dx in -spot.radius - 2 .. spot.radius + 2:
          if animatedDiamondCovers(spot, 0, spot.cx + dx, spot.cy + dy) !=
              isAnimatedDiamondPixel(spot.cx + dx, spot.cy + dy):
            inc restMismatch
    check restMismatch == 0

  test "the live wall mask stays exactly mirror-symmetric all turn":
    ## The arena's obstacle union is exactly x-mirror symmetric and 2-team
    ## fairness rests on it (tests/test_mapgen.nim). Making the diamonds live
    ## put that at risk: sampling half a pixel to the right of each center
    ## does not flip sign under x -> width-1-x, so each diamond's footprint
    ## would be its twin's mirrored AND shifted one pixel.
    var sim = twoTeamGame()
    for frame in 0 ..< DiamondSpinFrames:
      sim.applyDiamondGeometry(frame * DiamondSpinTicksPerFrame)
      var asymmetric = 0
      for spot in AnimatedDiamonds:
        for y in spot.cy - spot.radius - 2 .. spot.cy + spot.radius + 2:
          for x in spot.cx - spot.radius - 2 .. spot.cx + spot.radius + 2:
            if sim.isWall(x, y) != sim.isWall(MapWidth - 1 - x, y):
              inc asymmetric
      check asymmetric == 0

  test "the spinning set is closed under every map's own symmetry":
    ## If the set is not closed, one team gets rotating cover exactly where
    ## another gets solid stone. The authored rule is a vertical band down the
    ## center column: already closed under the mirror and under 180 degrees,
    ## but NOT under 90 — a quarter turn maps it to a horizontal band — so
    ## rot90 maps take the band's closure, a cross through the center.
    let previousDir = getCurrentDir()
    setCurrentDir(GameDir)
    try:
      proc imagesOf(m: CtfMap, cx, cy: int): seq[(int, int)] =
        case m.symmetry
        of symNone: result = @[]   # full-board: no symmetry image of a diamond
        of symMirror: result = @[(m.width - 1 - cx, cy)]
        of symRot180: result = @[(m.width - 1 - cx, m.height - 1 - cy)]
        of symRot90:
          var (x, y) = (cx, cy)
          for _ in 0 ..< 3:
            (x, y) = (m.width - 1 - y, x)
            result.add((x, y))
        of symQuadMirror:
          result = @[
            (m.width - 1 - cx, cy),
            (cx, m.height - 1 - cy),
            (m.width - 1 - cx, m.height - 1 - cy)]
      for spec in [("arena", 0), ("arena-large", 0), ("gen:1046", 0),
                   ("gen:1002", 0), ("gen:1005", 0)]:
        let
          gameMap = loadCtfMapMetadata(spec[0])
          chosen = buildAnimatedDiamonds(
            gameMap, buildArenaObstacles(gameMap))
        for spot in chosen:
          for image in gameMap.imagesOf(spot.cx, spot.cy):
            var found = false
            for other in chosen:
              if other.cx == image[0] and other.cy == image[1]:
                found = true
            ## A selected diamond's symmetry image must be selected too.
            check found
      ## The authored arenas still select exactly the eight they always have.
      for mapName in ["arena", "arena-large"]:
        let gameMap = loadCtfMapMetadata(mapName)
        check buildAnimatedDiamonds(
          gameMap, buildArenaObstacles(gameMap)).len == 8
    finally:
      setCurrentDir(previousDir)

  test "spin direction follows the symmetry: reflections invert, rotations do not":
    ## A reflection maps a rotation by +theta to one by -theta, so mirror-image
    ## diamonds must turn OPPOSITE ways. A rotation commutes with rotation, so
    ## rot180 and rot90 images must turn the SAME way. Keying direction off
    ## which side of the map a diamond sits on gets the reflection right and
    ## both rotations wrong, because every one of these symmetries moves a
    ## diamond across the axis.
    check ArenaSpinMirrored          # the default arena is a mirror map
    let
      left = AnimatedDiamonds[0]
      right = block:
        var pick = AnimatedDiamonds[0]
        for spot in AnimatedDiamonds:
          if 2 * spot.cx >= MapWidth - 1:
            pick = spot
            break
        pick
      tick = DiamondSpinTicksPerFrame
    check diamondSpinFrame(left.cx, left.cy, tick) == 1
    check diamondSpinFrame(right.cx, right.cy, tick) == DiamondSpinFrames - 1

  test "the live footprint is symmetric on rot180 and rot90 maps too":
    ## The installed-map globals make it impractical to boot a generated map
    ## inside this suite (selectCtfMap installs ONE map per process), so this
    ## checks the property directly on the geometry: the union of the selected
    ## diamonds' stone must map onto itself under the map's own symmetry, at
    ## every frame. Rotations do not invert the spin, so the image diamond
    ## reads the SAME frame; that is what makes this pass or fail.
    let previousDir = getCurrentDir()
    setCurrentDir(GameDir)
    try:
      ## Seeds picked (re-picked when the oversize size classes re-dealt the
      ## draws) so the 2-team map is rot180 and both maps select diamonds.
      for gameMap in [generateCtfMap(1111), generateCtfMap(66, teams = 4)]:
        let
          chosen = buildAnimatedDiamonds(
            gameMap, buildArenaObstacles(gameMap))
        check chosen.len > 0
        check gameMap.symmetry in {symRot180, symRot90}
        ## Frames come from diamondSpinFrame, NOT from a constant: the whole
        ## question is whether the direction rule hands a diamond and its
        ## image the same angle. Hard-coding one frame for both would test the
        ## footprint and quietly assume the rule.
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
                  image =
                    if gameMap.symmetry == symRot180:
                      (gameMap.width - 1 - x, gameMap.height - 1 - y)
                    else:
                      (gameMap.width - 1 - y, x)
                if coveredAt(x, y, tick) !=
                    coveredAt(image[0], image[1], tick):
                  inc asymmetric
          check asymmetric == 0
    finally:
      setCurrentDir(previousDir)

  test "stepping to a tick lands on the same geometry as jumping to it":
    ## The masks are mutable state carried across ticks, so "pure function of
    ## the tick" has to mean path-independent, not just deterministic given
    ## the same calls in the same order.
    var
      stepped = twoTeamGame()
      jumped = twoTeamGame()
    let noInput = newSeq[InputState](stepped.players.len)
    for _ in 0 ..< 300:
      stepped.step(noInput, noInput)
    jumped.applyDiamondGeometry(stepped.tickCount)
    var drift = 0
    for spot in AnimatedDiamonds:
      for y in spot.cy - spot.radius - 2 .. spot.cy + spot.radius + 2:
        for x in spot.cx - spot.radius - 2 .. spot.cx + spot.radius + 2:
          if stepped.isWall(x, y) != jumped.isWall(x, y):
            inc drift
    check drift == 0
    for cell in 0 ..< FovCellCount:
      check stepped.fovBlocked[cell] == jumped.fovBlocked[cell]

  test "a turn invalidates cached vision, not just the shared grid":
    ## refreshPlayerFov early-returns when the cache is valid and the viewer
    ## has not moved or turned, and fovVisibleAt fails OPEN on an invalid
    ## cache — so dropping the cache invalidation would leak whole-map vision
    ## to a stationary player rather than blinding them. The existing fog test
    ## only inspects fovBlocked, which refreshFovCells writes directly.
    var sim = twoTeamGame()
    let spot = AnimatedDiamonds[0]
    sim.tickCount = tickOfFrame(spot.cx, 0)
    sim.applyDiamondGeometry(sim.tickCount)
    sim.players[0].x = spot.cx - spot.radius - 20
    sim.players[0].y = spot.cy
    check sim.refreshPlayerFov(0)          # first pass computes it
    check not sim.refreshPlayerFov(0)      # standing still reuses the cache
    check sim.applyDiamondGeometry(
      tickOfFrame(spot.cx, DiamondSpinFrames div 2))
    # Same cell, same aim — only the stone moved, and that has to be enough.
    check sim.refreshPlayerFov(0)

  test "one sweep never stacks two players on the same floor":
    ## nearestWalkable knows nothing about other bodies, so two players caught
    ## by the same turn used to be handed the identical pixel — an overlap the
    ## rest of the game forbids (tests/test_player_collision.nim).
    var sim = twoTeamGame()
    let spot = AnimatedDiamonds[0]
    sim.tickCount = tickOfFrame(spot.cx, DiamondSpinFrames div 2)
    sim.updateAnimatedDiamonds()
    let (px, py) = cornerPixel(spot)
    check sim.canOccupy(px, py)
    sim.players[0].x = px
    sim.players[0].y = py
    sim.players[1].x = px
    sim.players[1].y = py + 1
    sim.tickCount = tickOfFrame(spot.cx, 0)
    sim.updateAnimatedDiamonds()
    for i in 0 .. 1:
      check sim.canOccupy(sim.players[i].x, sim.players[i].y)
    check max(abs(sim.players[0].x - sim.players[1].x),
              abs(sim.players[0].y - sim.players[1].y)) > PlayerSolidSpan

  test "resetting the tick also resets the live geometry":
    var sim = twoTeamGame()
    let
      spot = AnimatedDiamonds[0]
      tick = tickOfFrame(spot.cx, DiamondSpinFrames div 2)
      (turnedX, turnedY) = turnedCornerPixel(spot)
      (restX, restY) = cornerPixel(spot)
    sim.tickCount = tick
    sim.applyDiamondGeometry(tick)
    check sim.isWall(turnedX, turnedY)
    sim.resetToLobby()
    check sim.tickCount == 0
    check not sim.isWall(turnedX, turnedY)
    check sim.isWall(restX, restY)
