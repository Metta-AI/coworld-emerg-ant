## symNone full-board authoring (coworld-ctf#280): a symmetry mode that takes
## the authored obstacle set VERBATIM (no fundamental-domain lift) so organic,
## irregular, asymmetric maps can be expressed at all. The suite pins:
##   - buildArenaObstacles adds NO image under symNone (the mesa mirror-seal bug);
##   - orbit helpers (symmetryImages, teamImagePoint) degenerate correctly;
##   - explicit per-team pickup points are used instead of the symmetry orbit;
##   - spec validation fails loudly on a malformed symNone spec (no silent default);
##   - the spec JSON round-trips symNone exactly;
##   - PARITY: the four existing symmetries are byte-for-byte unchanged;
##   - a hand-authored ASYMMETRIC demo map boots and steps deterministically.

import
  helpers,
  std/[json, os, unittest],
  bitworld/spriteprotocol,
  ctf/[arena, sim, sim_config, sim_types]

const
  W = 1235
  H = 659

proc asymShapes(): seq[ArenaShape] =
  ## Deliberately ASYMMETRIC full-board obstacles: shapes on BOTH halves that
  ## are NOT mirror/rot images of each other (the whole point of symNone). A
  ## mirror map authoring these on the left would double them onto the right.
  @[
    ArenaShape(kind: shapeRect, rect: MapRect(x: 300, y: 120, w: 40, h: 200)),
    ArenaShape(kind: shapeDisc, cx: 760, cy: 250, radius: 34),
    ArenaShape(kind: shapePolygon, points: @[
      MapPoint(x: 520, y: 300), MapPoint(x: 611, y: 330),
      MapPoint(x: 540, y: 430)]),               # off-center, no twin
    ArenaShape(kind: shapeRect, rect: MapRect(x: 880, y: 470, w: 120, h: 24)),
  ]

proc shapeNode(s: ArenaShape): JsonNode =
  ## Minimal spec-node emitter for the shape kinds the demo uses (rect / disc /
  ## polygon), matching shapeFromSpecNode's reader.
  case s.kind
  of shapeRect:
    %*{"kind": "rect", "x": s.rect.x, "y": s.rect.y, "w": s.rect.w, "h": s.rect.h}
  of shapeDisc:
    %*{"kind": "disc", "cx": s.cx, "cy": s.cy, "r": s.radius}
  of shapePolygon:
    var pts = newJArray()
    for p in s.points: pts.add %*[p.x, p.y]
    %*{"kind": "polygon", "points": pts}
  else:
    raiseAssert "demo uses only rect/disc/polygon"

proc demoSymNoneSpec(): string =
  ## A minimal well-formed symNone map spec: asymmetric obstacles + EXPLICIT
  ## per-team pickup points (no orbit exists to derive them). Built as spec
  ## JSON and loaded via mapFromSpecJson, so rooms + validation run the real
  ## path. This is the PR's demo fixture.
  var obstacles = newJArray()
  for s in asymShapes(): obstacles.add shapeNode(s)
  let spec = %*{
    "name": "symnone-demo",
    "width": W, "height": H,
    "flagRing": 70, "captureClear": 210,
    "spawnClearW": 70, "spawnClearH": 130,
    "gunRange": GunRange,
    "symmetry": "none",
    "layout": "sides",
    "endzone": "column", "endzoneRadius": 0, "homeDepth": 0,
    "redAnchorOverride": [280, 329],
    "medKitSpawns": [[W div 2, H div 3], [W div 2, 2 * H div 3]],
    "medKitCandidates": [[W div 2, H div 3], [W div 2, 2 * H div 3]],
    "leftObstacles": obstacles,
    # Explicit per-team points — Red (west) then Blue (east), deep in each home
    # column (protected floor, always walkable + connected).
    "teamPickups": {
      "shields": [[40, 3 * H div 4], [W - 40, 3 * H div 4]],
      "cans": [[40, H div 4], [W - 40, H div 4]],
      "barriers": []
    }
  }
  $spec

proc demoSymNoneMap(): CtfMap =
  mapFromSpecJson(demoSymNoneSpec())

suite "symNone full-board authoring (#280)":

  test "buildArenaObstacles takes the authored set VERBATIM — no image added":
    var gameMap = CtfMap(
      width: W, height: H, center: MapPoint(x: 617, y: 329),
      symmetry: symNone, layout: layoutSides,
      leftObstacles: asymShapes())
    let full = buildArenaObstacles(gameMap)
    ## The mesa mirror-seal bug (tasks#42 c96916) was 2x obstacles from a lift.
    check full.len == gameMap.leftObstacles.len
    for shape in gameMap.leftObstacles:
      check shape in full

  test "orbit helpers degenerate: a shape/point maps only to itself":
    var gameMap = CtfMap(
      width: W, height: H, center: MapPoint(x: 617, y: 329),
      symmetry: symNone, layout: layoutSides)
    check gameMap.symmetryImages(MapRect(x: 10, y: 20, w: 5, h: 6)) ==
      @[MapRect(x: 10, y: 20, w: 5, h: 6)]
    check gameMap.symmetryImages(MapPoint(x: 33, y: 44)) ==
      @[MapPoint(x: 33, y: 44)]

  test "teamImagePoint has no meaning under symNone — it raises":
    var gameMap = CtfMap(
      width: W, height: H, center: MapPoint(x: 617, y: 329),
      symmetry: symNone, layout: layoutSides)
    expect CtfError:
      discard gameMap.teamImagePoint(MapPoint(x: 40, y: 100), Blue)

  test "explicit per-team pickups are used, not the orbit":
    let gameMap = demoSymNoneMap()
    let shields = gameMap.shieldSpawnPoints()
    let cans = gameMap.plasmaArcSpawnPoints()
    check shields == @[(40, 3 * H div 4), (W - 40, 3 * H div 4)]
    check cans == @[(40, H div 4), (W - 40, H div 4)]

  test "validation FAILS LOUDLY on a symNone spec missing per-team points":
    ## Only ONE shield point (one team) — no orbit to fill the other. The real
    ## user path (mapFromSpecJson -> validateMap) must reject it, not default.
    var node = parseJson(demoSymNoneSpec())
    node["teamPickups"]["shields"] = %*[[40, 400]]
    expect CtfError:
      discard mapFromSpecJson($node)

  test "validation rejects symNone on a 4-team layout":
    var node = parseJson(demoSymNoneSpec())
    node["layout"] = %"corners"
    expect CtfError:
      discard mapFromSpecJson($node)

  test "validation REJECTS an unwalkable pickup (inside an obstacle)":
    ## A shield authored inside an obstacle would load fine and be unreachable
    ## if only in-bounds were checked. The wall-overlap check must reject it.
    ## The demo's red obstacle is a disc at (760,250) r=34; put a shield there.
    var node = parseJson(demoSymNoneSpec())
    node["leftObstacles"] = %*[{"kind": "disc", "cx": 760, "cy": 250, "r": 34}]
    node["teamPickups"]["shields"] = %*[[760, 250], [W - 60, 250]]  # red shield in the disc
    expect CtfError:
      discard mapFromSpecJson($node)

  test "barrier count mismatch vs config perTeam raises at spawn":
    ## Loader only checks barriers.len is a multiple of teamCount; the config's
    ## perTeam is unknown until spawn. barrierSpawnPoints must reject a spec
    ## that carries the wrong count for the requested perTeam.
    var node = parseJson(demoSymNoneSpec())
    # author ONE pair (perTeam=1) — walkable spots in the open home columns
    node["teamPickups"]["barriers"] = %*[[60, 300], [W - 60, 300]]
    let gm = mapFromSpecJson($node)         # loads: 2 is a valid multiple
    check gm.barrierSpawnPoints(1).len == 2 # config perTeam=1 matches -> OK
    expect CtfError:
      discard gm.barrierSpawnPoints(2)      # config perTeam=2 wants 4, spec has 2

  test "map spec JSON round-trips symNone exactly":
    ## Idempotence on the SERIALIZED form: load -> emit -> load -> emit must be a
    ## fixed point (comparing the loaded CtfMap directly trips on the loader's
    ## homeDepth 0 -> Classic normalization, which is pre-existing and unrelated
    ## to symNone). Two reloads are identical, and symmetry + explicit pickups
    ## survive the trip.
    let once = mapSpecJson(demoSymNoneMap())
    let twice = mapSpecJson(mapFromSpecJson(once))
    check once == twice
    let rebuilt = mapFromSpecJson(once)
    check rebuilt.symmetry == symNone
    check rebuilt.teamPickups.shields == @[
      MapPoint(x: 40, y: 3 * H div 4), MapPoint(x: W - 40, y: 3 * H div 4)]
    check buildArenaObstacles(rebuilt).len == asymShapes().len

  test "the symmetry string parses and re-emits as 'none'":
    let gameMap = demoSymNoneMap()
    let node = parseJson(mapSpecJson(gameMap))
    check node["symmetry"].getStr() == "none"

  test "PARITY: appending symNone leaves every existing symmetry's lift exact":
    ## The wire-safety guarantee: symNone appended LAST changes no existing
    ## ordinal, and the buildArenaObstacles image counts for the four prior
    ## modes are exactly what they were (mirror/rot180 = 2x, rot90/quad = 4x).
    check ord(symMirror) == 0
    check ord(symRot180) == 1
    check ord(symRot90) == 2
    check ord(symQuadMirror) == 3
    check ord(symNone) == 4          # appended last — no keyframe ordinal shifts
    let seeds = asymShapes()
    for (sym, layout, factor) in [
        (symMirror, layoutSides, 2), (symRot180, layoutSides, 2),
        (symRot90, layoutCorners, 4), (symQuadMirror, layoutCorners, 4)]:
      var gm = CtfMap(width: W, height: H, center: MapPoint(x: 617, y: 329),
                      symmetry: sym, layout: layout, leftObstacles: seeds)
      check buildArenaObstacles(gm).len == factor * seeds.len

  test "a symNone asymmetric map boots and steps deterministically":
    proc runGame(): SimServer =
      var config = defaultGameConfig()
      config.mapSpec = mapSpecJson(demoSymNoneMap())
      result = initCtfForTest(config)
      for i in 0 ..< 2:
        discard result.addPlayer("p" & $i)
      result.startGame()
      let none = newSeq[InputState](0)
      for tick in 0 ..< 200:
        result.step(none, none)
    var a = runGame()
    let b = runGame()
    check a.gameMap.symmetry == symNone
    ## The installed obstacle set is the verbatim authored set (no lift).
    check buildArenaObstacles(a.gameMap).len == asymShapes().len
    check a.gameHash() == b.gameHash()

  test "the shipped demo FIXTURE file loads, validates, and runs an episode":
    ## tests/fixtures/symnone-demo.json is the PR's demo fixture: a hand-authored
    ## ASYMMETRIC full-board map. Prove the on-disk file (not just the in-test
    ## builder) loads through the real path and steps.
    ## Source-relative path (currentSourcePath), not cwd-relative: CI runs the
    ## shard binary from a different working directory than tests/ (the relative
    ## "fixtures/..." read failed in CI). Same pattern as test_map_editor_core.
    const fixturePath = currentSourcePath.parentDir / "fixtures" / "symnone-demo.json"
    let specText = readFile(fixturePath)
    let gameMap = mapFromSpecJson(specText)      # validates on load
    check gameMap.symmetry == symNone
    check buildArenaObstacles(gameMap).len == 4  # verbatim, no mirror lift
    var config = defaultGameConfig()
    config.mapSpec = specText
    var sim = initCtfForTest(config)
    for i in 0 ..< 2: discard sim.addPlayer("p" & $i)
    sim.startGame()
    let none = newSeq[InputState](0)
    for tick in 0 ..< 120: sim.step(none, none)
    check sim.gameMap.name == "symnone-demo"
