## Audits a replay against the glass-window contract (introduced GameVersion
## 13, still current):
##   move  — no live player footprint ever overlaps a window pixel;
##   shot  — no tracer segment ever crosses a window pixel (bullets stop at
##           the pane, whether the shot hit or missed);
##   vision — players DO see enemies whose sightline crosses a window,
##           counted as seen-through-glass pairs.
## Prints a summary and exits nonzero on any move/shot violation. Demo/audit
## tooling; not part of the server.
import
  std/os,
  ../src/ctf/sim,
  toolutil

proc windowOnSegment(sim: SimServer, cx, cy, ax, ay, bx, by: int): bool =
  ## Returns true when a glass pixel lies on the sampled segment (same
  ## stepping as the sim's line-of-sight routine).
  let
    dx = bx - ax
    dy = by - ay
    steps = max(abs(dx), abs(dy))
  for s in 1 .. steps:
    if isArenaWindowPixel(ax + dx * s div steps, ay + dy * s div steps, cx, cy):
      return true
  false

proc main() =
  let replayPath = paramStr(1)
  var (sim, replay) = openReplay(replayPath)
  let
    cx = sim.gameMap.center.x
    cy = sim.gameMap.center.y
  var
    ticks = 0
    moveViolations = 0
    shotChecked = 0
    shotViolations = 0
    visionSamples = 0
    visiblePairs = 0
    seenThroughGlass = 0
  while replay.playing:
    replay.stepReplay(sim)
    inc ticks
    # MOVE: no live footprint pixel on glass, ever.
    for player in sim.players:
      if not player.alive:
        continue
      block footprint:
        for dy in -PlayerHalf .. PlayerHalf:
          for dx in -PlayerHalf .. PlayerHalf:
            if isArenaWindowPixel(player.x + dx, player.y + dy, cx, cy):
              inc moveViolations
              break footprint
    # SHOT: tracers born this tick never cross a window pixel.
    for shot in sim.recentShots:
      if shot.firedTick != sim.tickCount:
        continue
      inc shotChecked
      if sim.windowOnSegment(cx, cy, shot.x0, shot.y0, shot.x1, shot.y1):
        inc shotViolations
    # VISION: sampled — enemies seen across a glass sightline.
    if sim.tickCount mod 8 == 0:
      inc visionSamples
      for i in 0 ..< sim.players.len:
        if not sim.players[i].alive:
          continue
        for j in 0 ..< sim.players.len:
          if i == j or not sim.players[j].alive:
            continue
          if sim.players[i].team == sim.players[j].team:
            continue
          if not sim.playerVisibleTo(i, j):
            continue
          inc visiblePairs
          if sim.windowOnSegment(
            cx, cy, sim.players[i].x, sim.players[i].y,
            sim.players[j].x, sim.players[j].y
          ):
            inc seenThroughGlass
  echo "ticks replayed:        ", ticks
  echo "move violations:       ", moveViolations, " (footprint on glass)"
  echo "shots checked:         ", shotChecked
  echo "shot violations:       ", shotViolations, " (tracer crossed glass)"
  echo "vision sample ticks:   ", visionSamples
  echo "enemy-visible pairs:   ", visiblePairs
  echo "seen through glass:    ", seenThroughGlass
  if moveViolations > 0 or shotViolations > 0:
    quit(1)
  if seenThroughGlass == 0:
    echo "WARNING: no through-glass sighting occurred in this replay"

main()
