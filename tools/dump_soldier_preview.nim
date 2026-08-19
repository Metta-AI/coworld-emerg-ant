## Dumps the CvC cog soldier sprites to a PNG for visual inspection: all 16
## aim rotations for every skin and team (upright body, swept gun) plus the
## default roster icons, composited over the arena floor texture.

import
  pixie,
  ../src/ctf/sim,
  toolutil

when isMainModule:
  let
    floor = readImage("data/arena_floor.png")
    outPath = "/tmp/soldier_preview.png"
  var canvas = newImage(1600, 640)
  var ty = 0
  while ty < canvas.height:
    var tx = 0
    while tx < canvas.width:
      canvas.draw(floor, translate(vec2(float32(tx), float32(ty))))
      tx += floor.width
    ty += floor.height
  # Aim rotations: default red/blue, then crown red/blue (rot 0 = east, CCW).
  for skin in Skin:
    for team in Team:
      for rot in 0 ..< SoldierRotations:
        let pix = soldierRotPixels(team, skin, rot)
        canvas.draw(
          spriteToImage(pix, SoldierCanvas, SoldierCanvas),
          translate(vec2(
            float32(20 + rot * 95),
            float32(30 + (ord(skin) * 2 + ord(team)) * 110)
          ))
        )
  # Roster icons at three sizes.
  for team in Team:
    for (i, size) in [(0, 16), (1, 24), (2, 34)]:
      canvas.draw(
        spriteToImage(soldierIconPixels(team, size), size, size),
        translate(vec2(float32(40 + i * 50), float32(500 + ord(team) * 60)))
      )
  canvas.writeFile(outPath)
  echo "wrote ", outPath
