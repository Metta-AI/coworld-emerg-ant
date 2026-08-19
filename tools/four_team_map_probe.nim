## Probes the 4-team map generator: generates corner and plus maps over a
## seed sweep, reports validation pass rates, and renders wall-mask PNGs
## (pedestals, capture zones, and pickup points marked) for eyeballing.
##
## Run from the repository root:
##   nim r tools/four_team_map_probe.nim

import std/[os, strformat], pixie, ../src/ctf/sim

proc renderMap(gameMap: CtfMap, path: string) =
  let obstacles = buildArenaObstacles(gameMap)
  var image = newImage(gameMap.width, gameMap.height)
  for y in 0 ..< gameMap.height:
    for x in 0 ..< gameMap.width:
      let wall = mapWallAt(gameMap, obstacles, x, y)
      image[x, y] =
        if wall: rgba(60, 48, 36, 255)
        else: rgba(190, 178, 158, 255)
  # Capture zones + anchors per team.
  for team in gameMap.teams():
    let
      zone = gameMap.captureZone(team)
      anchor = gameMap.teamAnchor(team)
      c =
        case team
        of Red: rgba(224, 82, 58, 255)
        of Blue: rgba(63, 124, 196, 255)
        of Green: rgba(69, 168, 94, 255)
        of Yellow: rgba(221, 197, 49, 255)
    for y in zone.yLo .. zone.yHi:
      for x in zone.xLo .. zone.xHi:
        if (x + y) mod 7 == 0 and zone.inCaptureZone(x, y):
          image[x, y] = c
    for dy in -6 .. 6:
      for dx in -6 .. 6:
        let
          px = anchor.x + dx
          py = anchor.y + dy
        if px >= 0 and px < gameMap.width and py >= 0 and py < gameMap.height:
          image[px, py] = c
  # Pickups: shields (S), spray (P), grenades (G), med kits (M) as dots.
  proc dot(x, y: int, c: ColorRGBA) =
    for dy in -3 .. 3:
      for dx in -3 .. 3:
        let
          px = x + dx
          py = y + dy
        if px >= 0 and px < gameMap.width and py >= 0 and py < gameMap.height:
          image[px, py] = c
  for point in gameMap.shieldSpawnPoints():
    dot(point.x, point.y, rgba(255, 255, 255, 255))
  for point in gameMap.plasmaArcSpawnPoints():
    dot(point.x, point.y, rgba(0, 0, 0, 255))
  for point in gameMap.grenadeSpawnPoints():
    dot(point.x, point.y, rgba(255, 0, 255, 255))
  for point in gameMap.medKitSpawns:
    dot(point.x, point.y, rgba(255, 128, 0, 255))
  image.writeFile(path)

when isMainModule:
  let outDir = "/tmp/four_team_maps"
  createDir(outDir)
  for layout in ["corners", "plus"]:
    var passed, failed = 0
    for seed in 1 .. 30:
      let candidate = generateMapAttempt(
        seed, MapGenOverrides(windows: -1, layout: layout), teams = 4)
      let verdict = validateGeneratedMap(candidate)
      if verdict.len == 0:
        inc passed
        if passed <= 3:
          renderMap(candidate, outDir / &"{layout}-{seed}.png")
      else:
        inc failed
        if failed <= 3:
          echo &"{layout} seed {seed}: {verdict}"
    echo &"{layout}: {passed}/30 attempts valid"
  # And the end-to-end path: a validated map through the public entry.
  for layout in ["corners", "plus"]:
    let gameMap = generateCtfMap(
      1000, MapGenOverrides(windows: -1, layout: layout), teams = 4)
    echo &"generateCtfMap {layout}: {gameMap.name} " &
      &"{gameMap.width}x{gameMap.height} kits={gameMap.medKitSpawns.len}"
    renderMap(gameMap, outDir / &"picked-{layout}.png")
