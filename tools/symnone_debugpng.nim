import ../src/ctf/[arena, sim_types], std/os, pixie
let gm = mapFromSpecJson(readFile(paramStr(1)))
let obs = buildArenaObstacles(gm)
let w = gm.width; let h = gm.height
var img = newImage(w, h)
for y in 0..<h:
  for x in 0..<w:
    let wall = mapWallAt(gm, obs, x, y, includeSpinning=false)
    let pf = mapProtectedFloorAt(gm, x, y)
    img[x,y] =
      if wall: rgba(60,48,38,255)
      elif pf: rgba(226,214,180,255)
      else: rgba(206,188,150,255)
# mark anchors
proc mark(p: MapPoint, c: ColorRGBX) =
  for dy in -4..4:
    for dx in -4..4:
      if p.x+dx>=0 and p.y+dy>=0 and p.x+dx<w and p.y+dy<h: img[p.x+dx,p.y+dy]=c
mark(gm.teamAnchor(Red), rgba(220,60,60,255))
mark(gm.teamAnchor(Blue), rgba(60,90,220,255))
img.writeFile(paramStr(2))
echo "wrote ", paramStr(2)
