## Renders a replay to a numbered PNG frame sequence for movie assembly
## (ffmpeg). Steps the replay sim and composites the full broadcast frame
## every N ticks, rebuilding the sprite packet from scratch each sampled tick
## so no incremental-protocol state needs tracking. Demo tooling; not part of
## the server.
import
  std/[os, strformat, strutils],
  pixie,
  ../src/ctf/sim,
  toolutil

proc main() =
  let
    replayPath = paramStr(1)
    outDir = paramStr(2)
    everyN = if paramCount() >= 3: parseInt(paramStr(3)) else: 3
    fromTick = if paramCount() >= 4: parseInt(paramStr(4)) else: 0
    toTick = if paramCount() >= 5: parseInt(paramStr(5)) else: high(int)
  createDir(outDir)
  var (sim, replay) = openReplay(replayPath)
  let maxTick = min(toTick, replay.replayMaxTick())
  var frame = 0
  while sim.tickCount < maxTick and replay.playing:
    replay.stepReplay(sim)
    if sim.tickCount < fromTick or sim.tickCount mod everyN != 0:
      continue
    let canvas = sim.renderBoardFrame()
    canvas.writeFile(outDir / &"frame-{frame:05}.png")
    inc frame
    if frame mod 100 == 0:
      echo "tick ", sim.tickCount, " -> ", frame, " frames"
  echo "wrote ", frame, " frames to ", outDir, " (last tick ",
    sim.tickCount, ")"

main()
