import
  std/[json, math, strutils, unittest],
  bitworld/spriteprotocol,
  ctf/[global, map_pool, sim]
import helpers except twoTeamGame

proc twoTeamGame(extraPlayers = 0): SimServer =
  ## A started game with one Red player (0), one Blue player (1), and
  ## `extraPlayers` more Blue bodies (2..), on a generated map with exactly
  ## ONE pit — anchored at the map center by the odd-count rule — since the
  ## default arena ships trench-free.
  var config = defaultGameConfig()
  config.update("""{"mapPath": "gen", "mapSeed": 4242, "mapPits": 1}""")
  result = initCtfForTest(config)
  discard result.addPlayer("red0")
  discard result.addPlayer("blue0")
  for i in 0 ..< extraPlayers:
    discard result.addPlayer("blue" & $(i + 1))
  result.startGame()
  result.players[0].team = Red
  for i in 1 ..< result.players.len:
    result.players[i].team = Blue

proc placeAt(game: var SimServer, playerIndex, px, py: int) =
  ## Puts one player's CENTER exactly on map pixel (px, py), at rest.
  game.players[playerIndex].x = px - CollisionW div 2
  game.players[playerIndex].y = py - CollisionH div 2
  game.players[playerIndex].velX = 0
  game.players[playerIndex].velY = 0

proc throwFullChargeEastAt(game: var SimServer, thrower, tx, ty: int) =
  ## Places `thrower` GrenadeMaxRange west of (tx, ty) and throws a
  ## full-charge shot due east, landing exactly on (tx, ty) — the same math
  ## throwGrenade itself uses (see "charge picks the distance" in
  ## test_grenades.nim), so the target is exact rather than approximate.
  game.placeAt(thrower, tx - GrenadeMaxRange, ty)
  game.players[thrower].aimBrads = 0
  game.players[thrower].hasGrenade = true
  game.chargeAndThrow(thrower, GrenadeChargeTicks)
  check game.airborneGrenades.len == 1
  check game.airborneGrenades[0].tx == tx
  check game.airborneGrenades[0].ty == ty
  let flight = game.airborneGrenades[0].flightTicks
  let prev = game.none()
  for _ in 0 .. flight:
    game.step(game.none(), prev)
  check game.airborneGrenades.len == 0

suite "trenches":
  test "the default arena digs no trenches":
    let plain = initCtfForTest(defaultGameConfig())
    check plain.gameMap.trenches.len == 0
    check ArenaTrenches.len == 0
    check trenchIndexAt(plain.gameMap.center.x, plain.gameMap.center.y) == -1

  test "mapPits:1 anchors one walkable pit at the generated map's center":
    let sim = twoTeamGame()
    check ArenaTrenches.len == 1
    let
      cx = sim.gameMap.center.x
      cy = sim.gameMap.center.y
      trench = shapeAsRect(ArenaTrenches[0])
    check trench.w == TrenchSize
    check trench.h == TrenchSize
    check trenchIndexAt(cx, cy) == 0
    check trenchIndexAt(cx - TrenchSize, cy) == -1
    # Every pixel of the trench is walkable floor (it sits inside the open
    # center ring, never overlapping a wall).
    for y in trench.y ..< trench.y + trench.h:
      for x in trench.x ..< trench.x + trench.w:
        check sim.canOccupy(x, y)

  test "the trench art edge is rough, bounded, and deterministic":
    discard twoTeamGame()
    let trench = shapeAsRect(ArenaTrenches[0])
    # Along the top gameplay edge the rough cut line wanders: the signed
    # distance to it takes several values (a machined square would be one
    # constant) and never strays past the art pad.
    var edges: seq[float]
    for x in trench.x ..< trench.x + trench.w:
      edges.add trenchRoughEdge(trench, x, trench.y)
    var seen: seq[int]
    for e in edges:
      check abs(e) <= float(TrenchArtPadPx)
      let r = int(round(e))
      if r notin seen:
        seen.add r
    check seen.len >= 3
    # The edge is a pure function of the trench and pixel: a second sweep
    # bakes the identical contour (replays must match the live render).
    for i in 0 ..< edges.len:
      check trenchRoughEdge(trench, trench.x + i, trench.y) == edges[i]

  test "trench edge noise survives far map coordinates and keeps its pattern":
    # A trench parked deep in a giant/colossal map drives the noise seed to
    # (x*8191 + y)*4 + side — tens of millions. The prime mix must run in
    # wrapping uint64: as signed native-int math, seed * 73856093 stays legal
    # on 64-bit but overflow-traps on the wasm32 replay viewer, which killed
    # every map bake ("stuck warming up" on all hosted replays). These golden
    # values pin the exact contour the original 64-bit signed math baked, so
    # the arithmetic can never drift and desync recorded replays from the
    # live render (values captured on the pre-fix native build).
    let far = MapRect(x: 3100, y: 1650, w: 40, h: 28)
    const golden = [
      (3100, 1650, -2.6429458836),
      (3105, 1652, 1.1066987106),
      (3120, 1660, 10.5356984817),
      (3139, 1677, -2.1139314870),
      (3098, 1648, -4.8598496113),
      (3110, 1650, 1.2175112233),
    ]
    for (x, y, expected) in golden:
      check abs(trenchRoughEdge(far, x, y) - expected) < 1e-9

  test "climbing out of a trench is one fifth speed":
    var sim = twoTeamGame()
    let
      cx = sim.gameMap.center.x
      cy = sim.gameMap.center.y
      cap = sim.config.maxSpeed div TrenchSpeedDivisor
    # Standing in the pit's right half and pushing further right is
    # climbing the right wall: capped at 1/5 of the open-field max.
    sim.placeAt(0, cx + 20, cy)
    check sim.playerTrench(0) == 0
    for _ in 0 ..< 12:
      sim.applyInput(0, InputState(right: true))
      check sim.players[0].velX <= cap
    check sim.playerTrench(0) == 0
    check sim.players[0].velX == cap
    # Outward momentum sheds to the climbing cap the same way.
    sim.placeAt(0, cx + 20, cy)
    sim.players[0].velX = sim.config.maxSpeed
    sim.applyInput(0, InputState())
    check sim.players[0].velX <= cap

  test "dropping in and moving across the pit are full speed":
    var sim = twoTeamGame()
    let
      cx = sim.gameMap.center.x
      cy = sim.gameMap.center.y
      cap = sim.config.maxSpeed div TrenchSpeedDivisor
    # Full-speed momentum INTO the pit is kept — no entry clamp: only
    # friction touches a glide toward the pit's center.
    sim.placeAt(0, cx + 20, cy)
    sim.players[0].velX = -sim.config.maxSpeed
    sim.applyInput(0, InputState())
    check sim.players[0].velX < -cap
    # Holding toward the pit's middle accelerates to the FULL open-field
    # cap while still inside.
    sim.placeAt(0, cx + 24, cy)
    for _ in 0 ..< 10:
      sim.applyInput(0, InputState(left: true))
    check sim.playerTrench(0) == 0
    check sim.players[0].velX == -sim.config.maxSpeed

  test "firing from inside a trench takes three times the cooldown":
    var sim = twoTeamGame()
    let
      cx = sim.gameMap.center.x
      cy = sim.gameMap.center.y
    sim.placeAt(0, cx, cy)
    sim.players[0].aimBrads = 0
    sim.armToFire(0)
    sim.tryFire(0)
    check sim.players[0].fireCooldown ==
      sim.config.fireCooldownTicks * TrenchFireSlowdown
    # Outside, the same shot costs the base cooldown.
    sim.placeAt(0, cx - 200, cy)
    sim.armToFire(0)
    sim.tryFire(0)
    check sim.players[0].fireCooldown == sim.config.fireCooldownTicks

  test "trench and shield fire slowdowns compose by max, not product":
    var sim = twoTeamGame()
    let
      cx = sim.gameMap.center.x
      cy = sim.gameMap.center.y
    sim.placeAt(0, cx, cy)
    sim.players[0].hasShield = true
    sim.players[0].shieldHp = ShieldLayerHp
    sim.players[0].aimBrads = 0
    sim.armToFire(0)
    sim.tryFire(0)
    check sim.players[0].fireCooldown ==
      sim.config.fireCooldownTicks *
      max(ShieldFireSlowdown, TrenchFireSlowdown)

  test "about seventy percent of incoming shots fly over an occupant":
    var sim = twoTeamGame()
    let
      cx = sim.gameMap.center.x
      cy = sim.gameMap.center.y
      shots = 200
    # Shooter in the open ring outside the trench, aiming due west at the
    # occupant standing on the trench center. Ducked shots deal no damage
    # and count as misses; the rest hit for 1 as usual.
    sim.placeAt(1, cx, cy)
    check sim.playerTrench(1) == 0
    sim.placeAt(0, cx + 50, cy)
    check sim.playerTrench(0) == -1
    sim.players[0].aimBrads = 128
    var damaged = 0
    for _ in 0 ..< shots:
      sim.players[1].hp = sim.config.hitPoints
      sim.armToFire(0)
      sim.tryFire(0)
      if sim.players[1].hp < sim.config.hitPoints:
        inc damaged
    check sim.players[0].shotsFired == shots
    # Every shot that dealt damage is exactly a counted hit, and the hit
    # rate sits in a generous window around the expected 30%.
    check sim.players[0].shotsHit == damaged
    check damaged >= shots * 15 div 100
    check damaged <= shots * 45 div 100

  test "a ducked shot's tracer flies straight over the trench":
    var sim = twoTeamGame()
    let
      cx = sim.gameMap.center.x
      cy = sim.gameMap.center.y
      trench = shapeAsRect(ArenaTrenches[0])
    sim.placeAt(1, cx, cy)
    sim.placeAt(0, cx + 50, cy)
    sim.players[0].aimBrads = 128
    # Fire until one shot is ducked (the seeded RNG makes this quick): its
    # tracer carries on PAST the whole trench toward the far wall, because
    # the pit never stops a bullet.
    var sawFlyOver = false
    for _ in 0 ..< 50:
      sim.players[1].hp = sim.config.hitPoints
      sim.armToFire(0)
      sim.tryFire(0)
      let fx = sim.recentShots[^1]
      if sim.players[1].hp == sim.config.hitPoints:
        sawFlyOver = true
        check not fx.hit
        check fx.x1 < trench.x
        break
    check sawFlyOver

  test "a ducked shot carries on and can hit a body behind the trench":
    var sim = twoTeamGame(extraPlayers = 1)
    let
      cx = sim.gameMap.center.x
      cy = sim.gameMap.center.y
      shots = 200
    # Occupant on the trench center, a second body directly behind it on
    # the same ray (both inside the open ring). Every shot lands on ONE of
    # them: ~30% on the ducking occupant, the rest flying over onto the
    # exposed body behind.
    sim.placeAt(1, cx, cy)
    sim.placeAt(2, cx - 50, cy)
    check sim.playerTrench(1) == 0
    check sim.playerTrench(2) == -1
    sim.placeAt(0, cx + 50, cy)
    sim.players[0].aimBrads = 128
    var
      frontHits = 0
      behindHits = 0
    for _ in 0 ..< shots:
      sim.players[1].hp = sim.config.hitPoints
      sim.players[2].hp = sim.config.hitPoints
      sim.armToFire(0)
      sim.tryFire(0)
      if sim.players[1].hp < sim.config.hitPoints:
        inc frontHits
      if sim.players[2].hp < sim.config.hitPoints:
        inc behindHits
    check frontHits + behindHits == shots
    check frontHits >= shots * 15 div 100
    check frontHits <= shots * 45 div 100
    check behindHits >= shots * 55 div 100

  test "shots between two occupants of the same trench are never ducked":
    var sim = twoTeamGame()
    let
      cx = sim.gameMap.center.x
      cy = sim.gameMap.center.y
    sim.placeAt(0, cx - 20, cy)
    sim.placeAt(1, cx + 20, cy)
    check sim.playerTrench(0) == 0
    check sim.playerTrench(1) == 0
    sim.players[0].aimBrads = 0
    for _ in 0 ..< 20:
      sim.players[1].hp = sim.config.hitPoints
      sim.armToFire(0)
      sim.tryFire(0)
      check sim.players[1].hp == sim.config.hitPoints - 1
    check sim.players[0].shotsHit == 20

  test "shots fired from inside at a target outside are never ducked":
    var sim = twoTeamGame()
    let
      cx = sim.gameMap.center.x
      cy = sim.gameMap.center.y
    sim.placeAt(0, cx, cy)
    sim.placeAt(1, cx + 50, cy)
    check sim.playerTrench(1) == -1
    sim.players[0].aimBrads = 0
    for _ in 0 ..< 20:
      sim.players[1].hp = sim.config.hitPoints
      sim.armToFire(0)
      sim.tryFire(0)
      check sim.players[1].hp == sim.config.hitPoints - 1
    check sim.players[0].shotsHit == 20

  test "generated maps dig walkable, team-symmetric trenches":
    ## Every pool map's trenches sit on open floor (never under a wall or
    ## outside the borders), and every dig has its exact image under the
    ## map's symmetry — neither team gets a private pit.
    var mapsWithTrenches = 0
    var sawEndzone, sawField = false
    for index in 0 ..< MapPoolSeeds.len:
      let
        gameMap = poolCtfMap(index)
        obstacles = buildArenaObstacles(gameMap)
      if gameMap.trenches.len > 0:
        inc mapsWithTrenches
      for trenchShape in gameMap.trenches:
        let trench = shapeAsRect(trenchShape)
        check trench.w == TrenchSize
        check trench.h == TrenchSize
        var open = true
        for y in trench.y ..< trench.y + trench.h:
          for x in trench.x ..< trench.x + trench.w:
            if mapWallAt(gameMap, obstacles, x, y):
              open = false
        check open
        let cx = trench.x + trench.w div 2
        if cx < gameMap.captureClear or
            cx >= gameMap.width - gameMap.captureClear:
          sawEndzone = true
        else:
          sawField = true
        let image =
          case gameMap.symmetry
          of symMirror: MapRect(
            x: gameMap.width - trench.x - trench.w,
            y: trench.y, w: trench.w, h: trench.h)
          of symRot180: MapRect(
            x: gameMap.width - trench.x - trench.w,
            y: gameMap.height - trench.y - trench.h,
            w: trench.w, h: trench.h)
          of symRot90, symQuadMirror:
            raiseAssert "trenches never place on 4-team maps"
          of symNone:
            ## Full-board maps have no symmetry image: a trench stands alone, so
            ## its "image" is itself and the membership check below is trivially
            ## satisfied. (This pool is GENERATED maps, which are never symNone —
            ## the arm exists for exhaustiveness.)
            trench
        check rectShape(image) in gameMap.trenches
    ## The drawn pool exercises the endzone and field placement classes.
    check mapsWithTrenches > 0
    check sawEndzone
    check sawField

  test "generated trenches are deterministic and survive the spec round-trip":
    let generated = generateCtfMap(4242)
    check generated.trenches == generateCtfMap(4242).trenches
    let rebuilt = mapFromSpecJson(mapSpecJson(generated))
    check rebuilt.trenches == generated.trenches

  test "mapPits locks an exact total; odd counts anchor the map center":
    for count in [0, 1, 4, 7, 12]:
      let gameMap = generateCtfMap(
        4242, MapGenOverrides(windows: -1, pits: count, pitDensity: -1))
      check gameMap.trenches.len == count
      let center = MapRect(
        x: gameMap.center.x - TrenchSize div 2,
        y: gameMap.center.y - TrenchSize div 2,
        w: TrenchSize, h: TrenchSize)
      check (rectShape(center) in gameMap.trenches) == (count mod 2 == 1)

  test "mapPitDensity scales the density draw":
    proc withDensity(density: int): CtfMap =
      generateMapAttempt(
        4242, MapGenOverrides(windows: -1, pits: -1, pitDensity: density))
    check withDensity(0).trenches.len == 0
    let defaultDigs = withDensity(-1).trenches.len
    check defaultDigs > 0
    check withDensity(100).trenches.len == defaultDigs
    check withDensity(400).trenches.len >= defaultDigs

  test "mapPits and mapPitDensity flow through the game config":
    var config = defaultGameConfig()
    config.update("""{"mapPath": "gen", "mapSeed": 4242, "mapPits": 5}""")
    check config.mapGen.pits == 5
    check resolveCtfMapMetadata(config).trenches.len == 5

  test "the y axis mirrors the climb-out rule":
    var sim = twoTeamGame()
    let
      cx = sim.gameMap.center.x
      cy = sim.gameMap.center.y
      cap = sim.config.maxSpeed div TrenchSpeedDivisor
    # Below the pit's center, pushing further down climbs the bottom wall.
    sim.placeAt(0, cx, cy + 20)
    check sim.playerTrench(0) == 0
    for _ in 0 ..< 12:
      sim.applyInput(0, InputState(down: true))
      check sim.players[0].velY <= cap
    check sim.players[0].velY == cap
    # Pushing back up toward the middle runs at the full open-field cap.
    sim.placeAt(0, cx, cy + 24)
    for _ in 0 ..< 10:
      sim.applyInput(0, InputState(up: true))
    check sim.playerTrench(0) == 0
    check sim.players[0].velY == -sim.config.maxSpeed

  test "a heart carrier's climb-out cap composes with the carrier penalty":
    var sim = twoTeamGame()
    let
      cx = sim.gameMap.center.x
      cy = sim.gameMap.center.y
      carrierMax = sim.config.maxSpeed * sim.config.carrierSpeedPct div 100
      cap = carrierMax div TrenchSpeedDivisor
    sim.placeAt(0, cx + 20, cy)
    sim.players[0].carryingFlag = true
    for _ in 0 ..< 16:
      sim.applyInput(0, InputState(right: true))
      check sim.players[0].velX <= cap
    check sim.players[0].velX == cap

  test "a windup released inside a pit pays the trench cooldown":
    var sim = twoTeamGame()
    let
      cx = sim.gameMap.center.x
      cy = sim.gameMap.center.y
    # Trigger pulled OUTSIDE the pit; the shooter is inside at release —
    # occupancy is read when the bullet leaves, not at the pull.
    sim.placeAt(0, cx + 60, cy)
    check sim.playerTrench(0) == -1
    sim.players[0].aimBrads = 0
    sim.players[0].fireCooldown = 0
    sim.startFireWindup(0)
    sim.placeAt(0, cx, cy)
    let none = newSeq[InputState](sim.players.len)
    for _ in 0 ..< sim.config.fireWindupTicks + 1:
      sim.step(none, none)
      if sim.players[0].fireCooldown > 0:
        break
    check sim.players[0].fireCooldown ==
      sim.config.fireCooldownTicks * TrenchFireSlowdown

  test "an over-request places as many pits as fit, still in fair pairs":
    let gameMap = generateCtfMap(
      4242, MapGenOverrides(windows: -1, pits: 64, pitDensity: -1))
    check gameMap.trenches.len mod 2 == 0
    check gameMap.trenches.len > 12
    check gameMap.trenches.len < 64
    for trenchShape in gameMap.trenches:
      let trench = shapeAsRect(trenchShape)
      let image =
        case gameMap.symmetry
        of symMirror: MapRect(
          x: gameMap.width - trench.x - trench.w,
          y: trench.y, w: trench.w, h: trench.h)
        of symRot180: MapRect(
          x: gameMap.width - trench.x - trench.w,
          y: gameMap.height - trench.y - trench.h,
          w: trench.w, h: trench.h)
        of symRot90, symQuadMirror:
          raiseAssert "trenches never place on 4-team maps"
        of symNone:
          trench    # full-board: no image; membership check is trivial (generated
                    # maps are never symNone — arm for exhaustiveness)
      check rectShape(image) in gameMap.trenches

  test "out-of-range pit knobs raise config errors at config load":
    # update() resolves the gen map to pin its mapSpec, so a bad knob is
    # rejected the moment the config is loaded — before any game starts.
    for bad in ["""{"mapPath": "gen", "mapSeed": 1, "mapPits": 65}""",
                """{"mapPath": "gen", "mapSeed": 1, "mapPits": -2}""",
                """{"mapPath": "gen", "mapSeed": 1, "mapPitDensity": 1001}"""]:
      var config = defaultGameConfig()
      expect CtfError:
        config.update(bad)

  test "specs recorded before trenches existed load with none":
    let generated = generateCtfMap(4242)
    var node = parseJson(mapSpecJson(generated))
    node.delete("trenches")
    let rebuilt = mapFromSpecJson($node)
    check rebuilt.trenches.len == 0
    check rebuilt.leftObstacles == generated.leftObstacles

  test "a blast trapped in its victim's own trench deals amplified damage":
    var sim = twoTeamGame()
    let
      cx = sim.gameMap.center.x
      cy = sim.gameMap.center.y
    sim.placeAt(1, cx, cy)
    check sim.playerTrench(1) == 0
    sim.players[1].hp = 20
    sim.throwFullChargeEastAt(0, cx, cy)
    check sim.players[1].hp == 20 - GrenadeTrenchDamage
    check sim.recentBlasts.len == 1
    check sim.recentBlasts[0].trenchLanding

  test "a blast landing outside a trench only splashes its occupant":
    var sim = twoTeamGame()
    let
      cx = sim.gameMap.center.x
      cy = sim.gameMap.center.y
      landingX = cx - 40
    # The landing spot itself must read as open field, and still be within
    # blast range of the victim sitting on the trench.
    check trenchIndexAt(landingX, cy) == -1
    check (cx - landingX) * (cx - landingX) <= GrenadeBlastRadius * GrenadeBlastRadius
    sim.placeAt(1, cx, cy)
    check sim.playerTrench(1) == 0
    sim.players[1].hp = 20
    sim.throwFullChargeEastAt(0, landingX, cy)
    check sim.players[1].hp == 20 - GrenadeTrenchSplashDamage
    check sim.recentBlasts.len == 1
    check not sim.recentBlasts[0].trenchLanding

  test "a blast with no trench in play deals the ordinary open-field amount":
    var sim = twoTeamGame()
    let
      cx = sim.gameMap.center.x
      cy = sim.gameMap.center.y
      landingX = cx + 50
    check trenchIndexAt(landingX, cy) == -1
    sim.placeAt(1, landingX, cy)
    check sim.playerTrench(1) == -1
    sim.players[1].hp = 20
    sim.throwFullChargeEastAt(0, landingX, cy)
    check sim.players[1].hp == 20 - GrenadeDamage
    check not sim.recentBlasts[0].trenchLanding

  test "a blast's paint stains stay inside the trench that trapped it":
    var sim = twoTeamGame()
    let
      cx = sim.gameMap.center.x
      cy = sim.gameMap.center.y
      trench = shapeAsRect(ArenaTrenches[0])
    sim.throwFullChargeEastAt(0, cx, cy)
    check sim.paintStains.len > 0
    for stain in sim.paintStains:
      check stain.x >= trench.x and stain.x < trench.x + trench.w
      check stain.y >= trench.y and stain.y < trench.y + trench.h

  test "a trench-trapped blast renders a smaller flash than an open one":
    var sim = twoTeamGame()
    let
      cx = sim.gameMap.center.x
      cy = sim.gameMap.center.y
    sim.throwFullChargeEastAt(0, cx, cy)
    var state = initGlobalViewerState()
    let messages = sim.buildGlobalMessages(state)
    var sawTrenchSprite = false
    for msg in messages:
      if msg.kind == spkSprite and msg.sprite.label.startsWith("blast stage"):
        # The board/spectator stream renders at RenderScale× the sim's own
        # pixels (see RenderScale's doc comment in global.nim), so the wire
        # sprite is TrenchSize scaled up, not TrenchSize itself.
        check msg.sprite.width == TrenchSize * RenderScale
        check msg.sprite.height == TrenchSize * RenderScale
        sawTrenchSprite = true
    check sawTrenchSprite

    var sim2 = twoTeamGame()
    let landingX = cx + 200
    check trenchIndexAt(landingX, cy) == -1
    sim2.throwFullChargeEastAt(0, landingX, cy)
    var state2 = initGlobalViewerState()
    let messages2 = sim2.buildGlobalMessages(state2)
    var sawOpenSprite = false
    for msg in messages2:
      if msg.kind == spkSprite and msg.sprite.label.startsWith("blast stage"):
        check msg.sprite.width == (GrenadeBlastRadius * 2 + 4) * RenderScale
        check msg.sprite.height == (GrenadeBlastRadius * 2 + 4) * RenderScale
        sawOpenSprite = true
    check sawOpenSprite
