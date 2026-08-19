## Dumps the BAKED board art (floor, stone, glass, endzone glow + threshold
## line, pedestals) for one map to a PNG — the picture players actually see,
## as opposed to the schematic tools/render_map_pool.nim draws.
## Usage: nim c -r -d:release tools/dump_endzone_bake.nim <mapPath> <out.png>
##        (mapPath: arena | gen:<seed> | pool:<index>)
import std/[os], pixie, ../src/ctf/sim

when isMainModule:
  let
    mapPath = if paramCount() >= 1: paramStr(1) else: "arena"
    outPath = if paramCount() >= 2: paramStr(2) else: "endzone-bake.png"
    gameMap = loadCtfMap(mapPath)
    layers = loadMapLayers(gameMap)
  layers.mapImage.writeFile(outPath)
  echo "wrote ", outPath, " (", gameMap.name, " endzone=", gameMap.endzone,
    " r=", gameMap.endzoneRadius, ")"
