## Steps a replay until a heart is being CARRIED (flag.carrier >= 0), then renders
## that broadcast frame and a tight crop around the carrier — a browser-free way
## to eyeball the carry pose (heart cradled front + perpendicular + arms).
import
  std/[os, strformat],
  pixie,
  ../src/ctf/[global, sim],
  toolutil

proc main() =
  let
    replayPath = paramStr(1)
    outDir = if paramCount() >= 2: paramStr(2) else: "/tmp/carryframes"
  createDir(outDir)
  var (sim, replay) = openReplay(replayPath)
  let maxTick = replay.replayMaxTick()
  echo "maxTick=", maxTick, " playing=", replay.playing
  var shots = 0
  var everCarried = 0
  while sim.tickCount < maxTick and replay.playing:
    replay.stepReplay(sim)
    for team in Team:
      if sim.flags[team].carrier >= 0: inc everCarried
    # find an active carrier
    var carrierIdx = -1
    for team in Team:
      if sim.flags[team].carrier >= 0:
        carrierIdx = sim.flags[team].carrier
    if carrierIdx < 0: continue
    # sample a few carry frames spaced out
    if sim.tickCount mod 8 != 0: continue
    let canvas = sim.renderBoardFrame()
    let p = sim.players[carrierIdx]
    let
      cx = p.x * RenderScale
      cy = p.y * RenderScale
      half = 70 * RenderScale
      x0 = max(0, cx - half)
      y0 = max(0, cy - half)
      x1 = min(canvas.width, cx + half)
      y1 = min(canvas.height, cy + half)
    let crop = canvas.subImage(x0, y0, x1 - x0, y1 - y0)
    let big = crop.resize(crop.width * 3, crop.height * 3)
    big.writeFile(outDir / &"carry-t{sim.tickCount:05}-p{carrierIdx}.png")
    inc shots
    echo "carry at tick ", sim.tickCount, " player ", carrierIdx,
      " aim ", p.aimBrads, " vel(", p.velX, ",", p.velY, ")"
    if shots >= 8: break
  echo "wrote ", shots, " carry crops to ", outDir,
    " (carry-tick samples seen: ", everCarried, ", last tick ", sim.tickCount, ")"

main()
