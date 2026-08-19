## Renders one synthetic viewer's fog-of-war over the arena map to a PNG:
## visible cells keep the map art, fogged cells fall to a dark veil, and the
## viewer is marked with a ring plus an aim tick. Demo tooling for the glass
## windows (vision passes through a window, stone still occludes); not part
## of the server.
import
  std/[os, strutils],
  pixie,
  ../src/ctf/sim

proc main() =
  let
    vx = parseInt(paramStr(1))
    vy = parseInt(paramStr(2))
    aimBrads = parseInt(paramStr(3))
    outPath = paramStr(4)
  var sim = initSimServer(defaultGameConfig())
  var visible: seq[bool]
  let (cx, cy) = fovCellAt(vx, vy)
  sim.computeFovVisible(cx, cy, aimBrads, visible)

  var canvas = newImage(MapWidth, MapHeight)
  for y in 0 ..< MapHeight:
    for x in 0 ..< MapWidth:
      let offset = mapIndex(x, y) * 4
      var color = rgba(
        sim.mapRgba[offset],
        sim.mapRgba[offset + 1],
        sim.mapRgba[offset + 2],
        255
      )
      let (fx, fy) = fovCellAt(x, y)
      if not visible[fovCellIndex(fx, fy)]:
        color = rgba(
          uint8(int(color.r) div 4),
          uint8(int(color.g) div 4),
          uint8(int(color.b) div 4),
          255
        )
      canvas[x, y] = color

  # Viewer ring + aim tick.
  let ctx = newContext(canvas)
  ctx.strokeStyle = rgba(255, 236, 39, 255)
  ctx.lineWidth = 3
  ctx.strokeCircle(circle(vec2(float32(vx), float32(vy)), 10))
  let (ax, ay) = aimVector(aimBrads)
  ctx.strokeSegment(segment(
    vec2(float32(vx) + float32(ax * 12.0), float32(vy) + float32(ay * 12.0)),
    vec2(float32(vx) + float32(ax * 34.0), float32(vy) + float32(ay * 34.0))
  ))
  canvas.writeFile(outPath)
  echo "wrote ", outPath

main()
