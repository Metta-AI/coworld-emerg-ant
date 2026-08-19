## Renders one broadcast frame of a replay to a PNG: steps the replay sim to a
## tick where both a fresh HIT and a fresh MISS tracer are in flight, builds the
## global sprite packet, and composites the map-layer objects. Demo tooling for
## the hit-bright/miss-faded tracer rendering; not part of the server.
import
  std/[os, strutils],
  pixie,
  ../src/ctf/sim,
  toolutil

proc main() =
  let
    replayPath = paramStr(1)
    fromTick = parseInt(paramStr(2))
    toTick = parseInt(paramStr(3))
    outPath = paramStr(4)
  var (sim, replay) = openReplay(replayPath)

  while sim.tickCount < fromTick:
    replay.stepReplay(sim)
  var pickTick = -1
  while sim.tickCount < toTick:
    replay.stepReplay(sim)
    var hits, misses = 0
    for shot in sim.recentShots:
      let age = sim.tickCount - shot.firedTick
      if age <= 4:
        if shot.hit: inc hits else: inc misses
    if hits >= 1 and misses >= 1:
      pickTick = sim.tickCount
      break
  if pickTick < 0:
    echo "no tick with fresh hit+miss tracers in ", fromTick, "..", toTick
    quit(1)
  echo "rendering tick ", pickTick

  # NOTE: this tool predates the RenderScale-scaled spectator wire and keeps
  # its original 1x band detection + canvas (scale = 1).
  var canvas = sim.renderBoardFrame(scale = 1)
  canvas.writeFile(outPath)
  echo "wrote ", outPath

  # Zoomed crops of the youngest hit and youngest miss tracer for comparison.
  proc crop(cx, cy: int, tag: string) =
    let
      w = 260
      h = 180
      x0 = clamp(cx - w div 2, 0, MapWidth - w)
      y0 = clamp(cy - h div 2, 0, MapHeight - h)
    var sub = canvas.subImage(x0, y0, w, h)
    var big = sub.resize(w * 3, h * 3)
    let cropPath = outPath.changeFileExt("") & "-" & tag & ".png"
    big.writeFile(cropPath)
    echo "wrote ", cropPath
  var bestHitAge = 1000
  var bestMissAge = 1000
  var hitShot, missShot: ShotFx
  for shot in sim.recentShots:
    let age = sim.tickCount - shot.firedTick
    if shot.hit and age < bestHitAge:
      bestHitAge = age
      hitShot = shot
    if not shot.hit and age < bestMissAge:
      bestMissAge = age
      missShot = shot
  echo "hit shot (", hitShot.x0, ",", hitShot.y0, ")->(", hitShot.x1, ",",
    hitShot.y1, ") age ", bestHitAge
  echo "miss shot (", missShot.x0, ",", missShot.y0, ")->(", missShot.x1, ",",
    missShot.y1, ") age ", bestMissAge
  crop((hitShot.x0 + hitShot.x1) div 2, (hitShot.y0 + hitShot.y1) div 2, "hit")
  crop((missShot.x0 + missShot.x1) div 2, (missShot.y0 + missShot.y1) div 2,
    "miss")

main()
