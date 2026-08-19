import std/[os, strformat], ../src/ctf/sim, toolutil

# Re-simulates a replay and prints, every SampleEvery ticks, the carrier of
# each flag (if any) with its position — plus that carrier's position stream
# so a stalled run home is visible at a glance.

const SampleEvery = 250

let path = commandLineParams()[0]
chdirGameDir()
var (game, replay) = openReplay(path)

var tick = 0
while replay.playing:
  replay.stepReplay(game)
  inc tick
  if tick mod SampleEvery == 0:
    for team in [Red, Blue]:
      let c = game.flags[team].carrier
      if c >= 0:
        let p = game.players[c]
        echo &"tick {tick}: {team} flag carried by slot {c} ({p.team}) at ({p.x},{p.y}) alive={p.alive}"
