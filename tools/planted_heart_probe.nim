## Visual probe for the PLANTED heart's stance on its pedestal: renders a fresh
## game's board through the real global sprite packet and crops each team's
## pedestal, with the grab point marked (a ring of FlagPickupRange map px at
## flag.x/flag.y — the point tryPickupFlags measures from, and the point a
## label-scanning policy reads as the sprite object's center).
##
## What a correct frame shows: the gem STANDING on the pedestal — body above
## the disc's center, tip touching the ring — not lying sunk in the disc. The
## regression this guards against twice over:
##   - bottom-anchored art (pre-#259): gem erect but its object center 28px
##     above the grab point, so policies could never grab what they saw;
##   - center-anchored art on a gem-height canvas (#259): object center fixed
##     but the gem drawn sunk halfway into the pedestal.
## The double-height canvas (PlantedFlagCanvasH) satisfies both: object center
## ON the grab point, gem painted erect above it.
##
##   nim c -d:release -r tools/planted_heart_probe.nim <outDir>
import
  std/[math, os],
  pixie,
  ../src/ctf/sim,
  toolutil

const
  CropHalf = 90         ## map px around the flag home in each crop.
  RingR = FlagPickupRange

proc buildSim(): SimServer =
  var config = defaultGameConfig()
  config.slots.setLen(4)
  result = initSimServer(config)
  for i in 0 ..< 4:
    discard result.addPlayer("probe_(" & $i & ")")
  result.startGame()

proc main() =
  chdirGameDir()
  doAssert paramCount() >= 1, "usage: planted_heart_probe <outDir>"
  let outDir = paramStr(1)
  createDir(outDir)
  var sim = buildSim()
  var canvas = sim.renderBoardFrame()
  # Read the render scale off the canvas itself so the ring is drawn in the
  # same space no matter what scale renderBoardFrame used.
  let scale = canvas.width div sim.gameMap.width
  # The grab ring, drawn straight onto the board raster so the crop carries
  # its own ground truth.
  for team in sim.teams():
    let home = sim.gameMap.flagHome(team)
    for deg in 0 ..< 720:
      let
        a = float(deg) * PI / 360.0
        rx = (float(home.x) + cos(a) * float(RingR)) * float(scale)
        ry = (float(home.y) + sin(a) * float(RingR)) * float(scale)
      for d in 0 ..< scale:
        let
          px = int(rx) + d mod scale
          py = int(ry) + d div scale
        if px >= 0 and px < canvas.width and py >= 0 and py < canvas.height:
          canvas[px, py] = rgba(255, 255, 255, 255)
  for team in sim.teams():
    let
      home = sim.gameMap.flagHome(team)
      x0 = max(0, (home.x - CropHalf) * scale)
      y0 = max(0, (home.y - CropHalf) * scale)
      w = min(canvas.width - x0, 2 * CropHalf * scale)
      h = min(canvas.height - y0, 2 * CropHalf * scale)
    var crop = newImage(w, h)
    crop.draw(canvas, translate(vec2(float32(-x0), float32(-y0))))
    let outPath = outDir / "pedestal_" & teamText(team) & ".png"
    crop.writeFile(outPath)
    echo "wrote ", outPath, " (flag home ", home.x, ",", home.y, " scale ", scale, ")"

main()
