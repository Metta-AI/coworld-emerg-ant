import
  helpers,
  std/[json, os, unittest],
  ctf/sim,
  "../tools/dump_map_mask"

## Covers the machine-readable map exports (dump_map_mask --raw / --geom).
## Importing the module is half the point: nothing else in the suite reaches
## `tools/dump_map_mask`, so CI (nim check src/ctf.nim + nim r tests/tests.nim)
## would never compile it.
##
## Every map here is read through loadCtfMapMetadata, which does NOT install
## the map: the process map is a one-shot global that the render bakes rely on
## (see sim.nim's "Runtime map state"), and this suite shares one process.

proc withGameDir(body: proc()) =
  ## Runs `body` from the repo root so data/ assets resolve.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    body()
  finally:
    setCurrentDir(previousDir)

suite "map export":
  test "the raw mask is the mask the sim collides against":
    ## --raw exists so an offline model can reason about collision without
    ## colour-matching a PNG. That is only true if its bytes agree, pixel for
    ## pixel, with the wallMask the sim actually builds. The default arena is
    ## the one map where both sides are available in-process, so it carries
    ## the equivalence; the rest ride the shape checks below.
    withGameDir proc() =
      let
        gameMap = loadCtfMapMetadata("arena")
        raw = rawMask(gameMap)
        sim = initSimServer(defaultGameConfig())
      check raw.len == gameMap.width * gameMap.height
      var
        mismatches = 0
        stone = 0
        glass = 0
      for y in 0 ..< gameMap.height:
        for x in 0 ..< gameMap.width:
          let cls = int(uint8(raw[y * gameMap.width + x]))
          case cls
          of 1: inc stone
          of 2: inc glass
          else: discard
          if (cls != 0) != sim.isWall(x, y):
            inc mismatches
      check mismatches == 0
      ## A map with no stone would satisfy the comparison vacuously.
      check stone > 0
      ## Glass is a strict subset of stone, never floor mislabelled as glass.
      check glass > 0
      check glass < stone

  test "every map kind exports at its own size, with matching geometry":
    ## The blob is headerless, so its length IS its shape contract, and map
    ## size varies by draw. Generated maps must export without a SimServer.
    ## Both exports share one pass over the map list: resolving a gen:/pool:
    ## name runs the terrain generator, which is the expensive part.
    withGameDir proc() =
      for mapName in ["arena", "arena-large", "gen:1003", "pool:1"]:
        let
          gameMap = loadCtfMapMetadata(mapName)
          raw = rawMask(gameMap)
          geom = geometryJson(gameMap)
        check raw.len == gameMap.width * gameMap.height
        ## Tally first, assert once: a per-pixel `check` would emit millions
        ## of unittest calls and bury a real failure in its own output.
        var
          stone = 0
          outOfAlphabet = 0
          openBorder = 0
        for cls in raw:
          let value = int(uint8(cls))
          if value notin [0, 1, 2]: inc outOfAlphabet
          if value != 0: inc stone
        for x in 0 ..< gameMap.width:
          if raw[x] == '\0': inc openBorder
          if raw[(gameMap.height - 1) * gameMap.width + x] == '\0':
            inc openBorder
        for y in 0 ..< gameMap.height:
          if raw[y * gameMap.width] == '\0': inc openBorder
          if raw[y * gameMap.width + gameMap.width - 1] == '\0':
            inc openBorder
        check outOfAlphabet == 0
        check stone > 0
        ## The border is stone on every map, all the way round.
        check openBorder == 0

        ## The raw blob is headerless: these two fields are the only thing
        ## that tells a reader how to reshape it.
        check geom["width"].getInt == gameMap.width
        check geom["height"].getInt == gameMap.height
        check geom["gameVersion"].getStr == GameVersion
        check geom["teams"].len == gameMap.teamCount()
        for team in geom["teams"]:
          let p = team["pedestal"]
          check p["x"].getInt >= 0 and p["x"].getInt < gameMap.width
          check p["y"].getInt >= 0 and p["y"].getInt < gameMap.height
        ## Every exported pickup point has to land on the map.
        for kind in ["grenade", "shield", "spray", "medkit"]:
          for p in geom["pickups"][kind]:
            check p["x"].getInt >= 0 and p["x"].getInt < gameMap.width
            check p["y"].getInt >= 0 and p["y"].getInt < gameMap.height
        for t in geom["trenches"]:
          check t["x"].getInt >= 0
          check t["x"].getInt + t["w"].getInt <= gameMap.width
          check t["y"].getInt >= 0
          check t["y"].getInt + t["h"].getInt <= gameMap.height
