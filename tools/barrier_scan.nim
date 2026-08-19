import std/[os, strformat], ../src/ctf/sim, toolutil

# Re-simulates a replay and prints every standing-barrier interval: the tick
# each barrier appears and disappears, so a viewer can be scrubbed to it.

let path = commandLineParams()[0]
chdirGameDir()
var (game, replay) = openReplay(path)

var prev = 0
var upSince = -1
while replay.playing:
  replay.stepReplay(game)
  let count = game.placedBarriers.len
  if count > 0 and prev == 0:
    upSince = game.tickCount
  if count == 0 and prev > 0:
    echo &"standing t={upSince}..{game.tickCount}  ({game.tickCount - upSince} ticks)"
    upSince = -1
  if count > prev and prev > 0:
    echo &"  another placed at t={game.tickCount} (now {count})"
  prev = count
if upSince >= 0:
  echo &"standing t={upSince}..end"
