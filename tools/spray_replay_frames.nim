## Renders consecutive board frames around a REAL bot spray burst from a recorded
## replay, as a filmstrip: proof the animation and the held-can art work through
## the true pipeline (replay -> sim -> delta sprite packets), not just a posed probe.
##
## Usage (repo root): nim r tools/spray_replay_frames.nim <replay> <fromTick> [n] [outDir]
## Find a burst tick with tools/spray_probe.nim's sibling scan, or grep the
## fixture's log for "sprayed paint".
import
  std/[os, strutils],
  pixie,
  ../src/ctf/[global, sim],
  toolutil

proc main() =
  let
    replayPath = paramStr(1).absolutePath()
    fromTick = parseInt(paramStr(2))
    frameCount = if paramCount() >= 3: parseInt(paramStr(3)) else: 6
    outDir = if paramCount() >= 4: paramStr(4) else: "/tmp"
  chdirGameDir()
  var (sim, replay) = openReplay(replayPath)

  # Persistent sprite/object world: the wire is a DELTA protocol (see
  # tools/spray_probe.nim), so every packet must be applied, not composited alone.
  var
    state = initGlobalViewerState()
    next: GlobalViewerState
    world = initSpriteWorld()

  proc applyPacket() =
    world.apply(sim.buildSpriteProtocolUpdates(state, next).parseSpritePacket())
    state = next

  proc board(): Image =
    world.renderBoard()

  while sim.tickCount < fromTick - 1 and replay.playing:
    replay.stepReplay(sim)
    applyPacket()

  const
    W = 300
    H = 190
  var frames: seq[Image]
  for f in 0 ..< frameCount:
    if not replay.playing: break
    replay.stepReplay(sim)
    applyPacket()
    # Center on whichever cog is mid-burst (else any can carrier).
    var cx, cy = -1
    for p in sim.players:
      if p.arcTicksLeft > 0 or p.hasPlasmaArc:
        cx = p.x + CollisionW div 2
        cy = p.y + CollisionH div 2
        if p.arcTicksLeft > 0: break
    if cx < 0: continue
    let
      full = board()
      x0 = clamp(cx * RenderScale - W div 2, 0, MapWidth * RenderScale - W)
      y0 = clamp(cy * RenderScale - H div 2, 0, MapHeight * RenderScale - H)
    frames.add full.subImage(x0, y0, W, H)
  if frames.len == 0:
    echo "no frames captured (no carrier/burst in that window)"
    quit(1)
  var strip = newImage(W, H * frames.len)
  for i, fr in frames:
    strip.draw(fr, translate(vec2(0, float32(i * H))))
  let path = outDir / "spray-replay-strip.png"
  strip.resize(W * 2, H * frames.len * 2).writeFile(path)
  echo "wrote ", path, "  ", frames.len, " frames from tick ", fromTick

main()
