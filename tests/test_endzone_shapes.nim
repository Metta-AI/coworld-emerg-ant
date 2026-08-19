## Compact endzones: the base sits well off its edge, the scoring region is a
## disc or square wrapped around it, and the freed home strip is wilderness.
import
  helpers,
  std/[strutils, unittest],
  bitworld/spriteprotocol,
  ctf/sim, ctf/map_pool

proc compactMap(shape: string, seed = 4242): CtfMap =
  generateCtfMap(seed, MapGenOverrides(
    windows: -1, pits: -1, pitDensity: -1, endzone: shape))

proc compactConfig(shape: string, seed = 4242): GameConfig =
  result = defaultGameConfig()
  result.update("""{"mapPath": "gen", "mapSeed": """ & $seed &
    """, "mapEndzone": """" & shape & """", "minPlayers": 1}""")

suite "compact endzones":
  test "the hand-authored arenas are untouched":
    for name in ["arena", "arena-large"]:
      let gameMap = loadCtfMapMetadata(name)
      check gameMap.endzone == ezColumn
      check gameMap.endzoneRadius == 0
      check gameMap.captureZone(Red).xLo == 0
    check loadCtfMapMetadata("arena").teamHomeX(Red) == 186
    check loadCtfMapMetadata("arena").teamHomeX(Blue) == 1049

  test "both compact shapes generate, validate and are deterministic":
    for shape in ["disc", "square"]:
      let gameMap = compactMap(shape)
      check gameMap == compactMap(shape)
      check validateGeneratedMap(gameMap) == ""
      check gameMap.endzone == (if shape == "disc": ezDisc else: ezSquare)
      check gameMap.endzoneRadius >= EndzoneRadiusMin
      check gameMap.endzoneRadius <= EndzoneRadiusMax

  test "the base sits further from the edge than a column map's":
    let column = generateCtfMap(4242, MapGenOverrides(
      windows: -1, pits: -1, pitDensity: -1, endzone: "column"))
    for shape in ["disc", "square"]:
      let gameMap = compactMap(shape)
      check gameMap.width == column.width      ## same size class, same seed.
      check gameMap.teamHomeX(Red) > column.teamHomeX(Red)
      ## ...and symmetrically on the far side.
      check gameMap.teamHomeX(Blue) < column.teamHomeX(Blue)

  test "the capture zone wraps the base instead of the border":
    for shape in ["disc", "square"]:
      let
        gameMap = compactMap(shape)
        anchor = gameMap.teamAnchor(Red)
        r = gameMap.endzoneRadius
        zone = gameMap.captureZone(Red)
      check zone.inCaptureZone(anchor.x, anchor.y)
      ## Every side of the base scores, including BEHIND it...
      for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
        check zone.inCaptureZone(anchor.x + dx * (r - 2), anchor.y + dy * (r - 2))
        check not zone.inCaptureZone(
          anchor.x + dx * (r + 2), anchor.y + dy * (r + 2))
      ## ...and the home border strip does NOT: it is ordinary field now.
      check not zone.inCaptureZone(ArenaBorder + 1, gameMap.center.y)
      ## A disc rounds its corners off; a square keeps them.
      let corner = (x: anchor.x - r + 3, y: anchor.y - r + 3)
      check zone.inCaptureZone(corner.x, corner.y) == (shape == "square")

  test "the zone is clear floor and the ground behind the base is not":
    for shape in ["disc", "square"]:
      let
        gameMap = compactMap(shape)
        obstacles = buildArenaObstacles(gameMap)
        anchor = gameMap.teamAnchor(Red)
        zone = gameMap.captureZone(Red)
      ## No wall inside the scoring shape: a carrier can always finish.
      var y = anchor.y - gameMap.endzoneRadius
      while y <= anchor.y + gameMap.endzoneRadius:
        var x = anchor.x - gameMap.endzoneRadius
        while x <= anchor.x + gameMap.endzoneRadius:
          if zone.inCaptureZone(x, y):
            check not mapWallAt(gameMap, obstacles, x, y)
          x += 3
        y += 3
      ## Wilderness: the strip between the base and its border carries real
      ## cover, which on a column map is protected floor and always empty.
      var behind = 0
      y = ArenaBorder
      while y < gameMap.height - ArenaBorder:
        var x = ArenaBorder
        while x < anchor.x - gameMap.endzoneRadius:
          if mapWallAt(gameMap, obstacles, x, y):
            inc behind
          x += 3
        y += 3
      check behind > 0

  test "every compact pool seed keeps its flanks open":
    var compact = 0
    for seed in MapPoolSeeds:
      let gameMap = generateCtfMap(seed)
      if gameMap.endzone == ezColumn:
        continue
      inc compact
      ## validateGeneratedMap is what enforces the four cardinal gates and
      ## the route around the endzone; the pool pins first-attempt passes.
      check validateGeneratedMap(gameMap) == ""
    check compact > 0

  test "a sealed backfield is rejected":
    ## Lock a radius so large that the base's own apron swallows the
    ## wilderness behind it: the flank invariants must catch it rather than
    ## shipping a base you can only reach from the field.
    var config = defaultGameConfig()
    expect CtfError:
      config.update("""{
        "mapPath": "gen", "mapSeed": 4242, "mapEndzone": "disc",
        "mapEndzoneRadius": 215, "mapBaseDepth": 800
      }""")

  test "capture, respawn and pickups follow the shape":
    let sim = initCtfForTest(compactConfig("disc"))
    let
      zone = sim.gameMap.captureZone(Red)
      anchor = sim.gameMap.teamAnchor(Red)
      r = sim.gameMap.endzoneRadius
    ## Both pickups sit inside the zone, clear of the pedestal art.
    for points in [sim.gameMap.shieldSpawnPoints(),
        sim.gameMap.plasmaArcSpawnPoints()]:
      check points.len == 2
      for point in points:
        check zone.inCaptureZone(point.x, point.y) or
          sim.gameMap.captureZone(Blue).inCaptureZone(point.x, point.y)
    ## Scoring is the ring, not a border column: standing behind the base
    ## (further out than the ring) does not score.
    check zone.inCaptureZone(anchor.x - r + 4, anchor.y)
    check not zone.inCaptureZone(anchor.x - r - 4, anchor.y)

  test "respawn draws land inside a ROUND zone, not its bounding box":
    ## A disc fills only ~78% of the box it is drawn from, so the sampler
    ## has to re-roll — the corners are wilderness, not endzone.
    var sim = initCtfForTest(compactConfig("disc"))
    let zone = sim.gameMap.captureZone(Red)
    for i in 0 ..< 200:
      let spot = sim.randomEndzonePosition(Red)
      check zone.inCaptureZone(spot.x, spot.y)

  test "a stepped compact episode is deterministic and respawns in-zone":
    proc runGame(): SimServer =
      result = initCtfForTest(compactConfig("disc"))
      for i in 0 ..< 4:
        discard result.addPlayer("p" & $i)
      result.startGame()
      result.killPlayer(2, 0)
      let none = newSeq[InputState](0)
      for tick in 0 ..< 400:
        result.step(none, none)
    var a = runGame()
    let b = runGame()
    check a.gameHash() == b.gameHash()
    check a.players[2].alive
    let
      zone = a.gameMap.captureZone(a.players[2].team)
      px = a.players[2].x + CollisionW div 2
      py = a.players[2].y + CollisionH div 2
    check zone.inCaptureZone(px, py)

  test "the spec round-trips the endzone and the config locks it":
    for shape in ["column", "disc", "square"]:
      let gameMap = compactMap(shape)
      check mapFromSpecJson(mapSpecJson(gameMap)) == gameMap
    ## A spec pinned before compact endzones existed still reads as classic.
    let legacy = generateCtfMap(4242, MapGenOverrides(
      windows: -1, pits: -1, pitDensity: -1, endzone: "column"))
    var node = mapSpecJson(legacy)
    node = node.replace(""""endzone":"column",""", "")
    node = node.replace(""""endzoneRadius":0,""", "")
    node = node.replace(""""homeDepth":700,""", "")
    check mapFromSpecJson(node) == legacy

  test "bad endzone configs fail loudly":
    for bad in [
      """{"mapPath": "gen", "mapSeed": 5, "mapEndzone": "blob"}""",
      """{"mapPath": "gen", "mapSeed": 5, "mapEndzoneRadius": 120}""",
      """{"mapPath": "gen", "mapSeed": 5, "mapBaseDepth": 500}""",
      """{"mapPath": "gen", "mapSeed": 5, "mapEndzone": "disc",
          "mapEndzoneRadius": 40}""",
      """{"mapPath": "gen", "mapSeed": 5, "mapEndzone": "disc",
          "mapBaseDepth": 900}""",
      """{"mapPath": "gen", "mapSeed": 5, "mapEndzone": "disc",
          "teams": 4}""",
    ]:
      var config = defaultGameConfig()
      expect CtfError:
        config.update(bad)
