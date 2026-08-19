## Dumps the generated arena wall mask to a PNG for visual inspection when
## iterating on the obstacle layout. Stone = dark brown, glass windows =
## cyan, floor = warm tan.
##
## Two optional side exports make the same geometry machine-readable, for
## offline analysis that needs the terrain the sim actually collides against
## rather than a picture of it:
##
##   --raw <path>    width*height bytes, row-major, one per pixel:
##                   0 = floor, 1 = stone, 2 = glass window. Headerless, so
##                   it loads as a flat array — take its shape from --geom's
##                   width/height (also echoed on stdout); map size varies by
##                   draw, so do NOT assume the default arena's dimensions.
##                   Classified from the sim's INTEGER collision predicate,
##                   not from the PNG's float rasterizer, so the bytes are the
##                   terrain a bullet meets. (The two agree everywhere today;
##                   sub-pixel disagreement along shape edges is allowed by
##                   design — see inShapeF.)
##   --geom <path>   JSON: pedestals, capture zones, pickup spawn points,
##                   trenches, and the tuning constants the geometry depends
##                   on.
##
## Usage: nim c -r tools/dump_map_mask.nim out.png [mapName]
##                                        [--raw out.bin] [--geom out.json]
## (mapName: "arena" default, "arena-large", or "gen:<seed>" / "pool:<idx>".)
## Demo/audit tooling; not part of the server.
import std/[json, os, strutils], pixie, ../src/ctf/sim

const UsageText =
  "Usage: dump_map_mask <out.png> [mapName] [--raw <path>] [--geom <path>]"

proc parseArgs(): tuple[pngPath, mapName, rawPath, geomPath: string] =
  ## Splits the positional out.png / mapName from the optional side exports.
  var positional: seq[string]
  var params = commandLineParams()
  var i = 0
  while i < params.len:
    let arg = params[i]
    if arg in ["--help", "-h"]:
      echo UsageText
      quit(0)
    elif arg in ["--raw", "--geom"]:
      if i + 1 >= params.len:
        quit(arg & " requires a path.\n" & UsageText)
      inc i
      if arg == "--raw": result.rawPath = params[i] else: result.geomPath = params[i]
    elif arg.startsWith("--"):
      quit("Unknown option: " & arg & "\n" & UsageText)
    else:
      positional.add(arg)
    inc i
  if positional.len < 1 or positional.len > 2:
    quit(UsageText)
  result.pngPath = positional[0]
  result.mapName = if positional.len >= 2: positional[1] else: ""

proc point(p: MapPoint): JsonNode =
  %*{"x": p.x, "y": p.y}

proc point(x, y: int): JsonNode =
  %*{"x": x, "y": y}

proc rawMask*(gameMap: CtfMap): string =
  ## The wall mask as one byte per pixel: 0 floor, 1 stone, 2 glass window.
  ## Built from mapWallAt — the INTEGER predicate the sim's wallMask comes
  ## from — so a consumer modelling collision reads the terrain the sim
  ## collides against. (The PNG keeps the float rasterizer: it is a picture.)
  ## Pure in `gameMap`, like geometryJson: it reads no installed-map globals,
  ## so gen:<seed> / pool:<idx> export without becoming the process map.
  ## Glass is a strict SUBSET of stone (a window pixel is a wall pixel), so
  ## the three classes are disjoint and the ordering below is total.
  ##
  ## One thing this cannot express: since GV28 the arenas' eight center
  ## diamonds are LIVE geometry that turns with the tick. What lands here is
  ## their frame-0 footprint, which is exactly their resting shape — correct
  ## for tick 0 and for every 16th frame, and the right static approximation
  ## everywhere else, but a model that needs the mid-turn silhouette has to
  ## reconstruct it from the tick (animatedDiamondCovers). Generated maps have
  ## no live diamonds, so their masks are exact at every tick.
  let
    obstacles = buildArenaObstacles(gameMap)
    wall = rasterizeRestWallMask(gameMap, obstacles,
      proc (x, y: int): bool = mapProtectedFloorAt(gameMap, x, y))
  result = newString(gameMap.width * gameMap.height)
  for i in 0 ..< wall.len:
    result[i] = char(uint8(ord(wall[i])))
  ## Glass upgrade (1 -> 2) only where a window shape actually reaches: the
  ## per-pixel window scan over the whole board is the expensive part on
  ## oversize maps, and window footprints are a few small boxes.
  for shape in obstacles:
    if not shape.window:
      continue
    let bounds = shapeBounds(shape)
    for y in max(bounds.y0, 0) .. min(bounds.y1, gameMap.height - 1):
      for x in max(bounds.x0, 0) .. min(bounds.x1, gameMap.width - 1):
        let i = y * gameMap.width + x
        if result[i] == char(1) and inShape(x, y, shape):
          result[i] = char(2)

proc geometryJson*(gameMap: CtfMap): JsonNode =
  ## The map's landmarks and the constants a geometric model of it needs.
  ## Everything here reads off CtfMap or a pure accessor, so no SimServer is
  ## built and generated maps export exactly like hand-authored ones.
  result = newJObject()
  result["gameVersion"] = %GameVersion
  result["name"] = %gameMap.name
  result["path"] = %gameMap.path
  result["width"] = %gameMap.width
  result["height"] = %gameMap.height
  result["center"] = point(gameMap.center)
  result["border"] = %ArenaBorder
  result["symmetry"] = %($gameMap.symmetry)
  result["layout"] = %($gameMap.layout)
  result["genSeed"] = %gameMap.genSeed
  result["flagRing"] = %gameMap.flagRing
  result["captureClear"] = %gameMap.captureClear

  var consts = newJObject()
  consts["playerHalf"] = %PlayerHalf
  consts["fovCellSize"] = %FovCellSize
  consts["gunRange"] = %gameMap.gunRange
  consts["visionBubble"] = %VisionBubble
  consts["bulletHalfWidth"] = %BulletHalfWidth
  consts["exposureSampleStep"] = %ExposureSampleStep
  consts["captureZoneWidth"] = %CaptureZoneWidth
  consts["aimBradsTurn"] = %AimBradsTurn
  result["consts"] = consts

  var teams = newJArray()
  for team in activeTeams(gameMap.teamCount):
    let
      home = gameMap.flagHome(team)
      zone = gameMap.captureZone(team)
    teams.add(%*{
      "team": $team,
      "pedestal": point(home),
      "captureZone": {
        "xLo": zone.xLo, "xHi": zone.xHi, "yLo": zone.yLo, "yHi": zone.yHi,
        "diag": zone.diag, "cornerX": zone.cornerX, "cornerY": zone.cornerY,
        "diagLimit": zone.diagLimit
      }
    })
  result["teams"] = teams

  proc points(items: openArray[tuple[x, y: int]]): JsonNode =
    result = newJArray()
    for p in items:
      result.add(point(p.x, p.y))

  var pickups = newJObject()
  pickups["grenade"] = points(grenadeSpawnPoints(gameMap))
  pickups["shield"] = points(shieldSpawnPoints(gameMap))
  pickups["spray"] = points(plasmaArcSpawnPoints(gameMap))
  var medkits = newJArray()
  for p in gameMap.medKitSpawns:
    medkits.add(point(p))
  pickups["medkit"] = medkits
  result["pickups"] = pickups

  var trenches = newJArray()
  for t in gameMap.trenches:
    let r = shapeAsRect(t)
    trenches.add(%*{"x": r.x, "y": r.y, "w": r.w, "h": r.h})
  result["trenches"] = trenches

when isMainModule:
  let
    args = parseArgs()
    gameMap = loadCtfMap(args.mapName)
    cx = gameMap.center.x
    cy = gameMap.center.y
  var img = newImage(MapWidth, MapHeight)
  for y in 0 ..< MapHeight:
    for x in 0 ..< MapWidth:
      var c = rgba(214, 189, 150, 255)
      let
        wall =
          x < ArenaBorder or y < ArenaBorder or
          x >= MapWidth - ArenaBorder or y >= MapHeight - ArenaBorder or
          obstacleWallAtF(float(x), float(y), cx, cy)
        window = isArenaWindowPixel(x, y, cx, cy)
      if window:
        c = rgba(80, 220, 255, 255)
      elif wall:
        c = rgba(64, 48, 34, 255)
      img.unsafe[x, y] = c.rgbx()
  img.writeFile(args.pngPath)
  echo "wrote ", args.pngPath
  if args.rawPath.len > 0:
    writeFile(args.rawPath, rawMask(gameMap))
    echo "wrote ", args.rawPath, " (", MapWidth, "x", MapHeight, " bytes)"
  if args.geomPath.len > 0:
    writeFile(args.geomPath, geometryJson(gameMap).pretty() & "\n")
    echo "wrote ", args.geomPath
