## Prints `seed <sha1-of-mapSpecJson>` for a range of generator seeds — a
## baseline for proving that a generator change leaves given maps untouched.
## The endzone keys are stripped before hashing so a pre-endzone baseline and
## a post-endzone run hash IDENTICALLY for every column-endzone map.
## Usage: nim c -r -d:release tools/dump_map_specs.nim [lo] [hi]
import std/[json, os, strutils, strformat, sha1], ../src/ctf/sim

proc legacySpec(gameMap: CtfMap): string =
  let node = parseJson(gameMap.mapSpecJson())
  for key in ["endzone", "endzoneRadius", "homeDepth"]:
    node.delete(key)
  $node

when isMainModule:
  let
    lo = if paramCount() >= 1: parseInt(paramStr(1)) else: 1001
    hi = if paramCount() >= 2: parseInt(paramStr(2)) else: 1060
  for seed in lo .. hi:
    let gameMap = generateMapAttempt(
      seed, MapGenOverrides(windows: -1, pits: -1, pitDensity: -1))
    let shape =
      case gameMap.endzone
      of ezColumn: "column"
      of ezDisc: "disc"
      of ezSquare: "square"
    echo &"{seed} {($secureHash(gameMap.legacySpec))[0 .. 15]} " &
      &"{gameMap.width} obstacles={gameMap.leftObstacles.len} " &
      &"valid={validateGeneratedMap(gameMap).len == 0} {shape} " &
      &"home={gameMap.teamHomeX(Red)} r={gameMap.endzoneRadius} " &
      &"why={validateGeneratedMap(gameMap)}"
