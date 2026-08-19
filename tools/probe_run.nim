import std/[os, strformat], ../src/ctf/sim, toolutil

# Re-simulates a replay WITH sim event logging (med kit pickups, kills) and
# prints each flag's carrier position every 150 ticks.

let path = commandLineParams()[0]
chdirGameDir()
var (game, replay) = openReplay(path, gameEventLoggingEnabled = true)
var tick = 0
while replay.playing:
  replay.stepReplay(game)
  inc tick
  if tick mod 150 == 0:
    for team in [Red, Blue]:
      let c = game.flags[team].carrier
      if c >= 0:
        let p = game.players[c]
        echo &"T{tick} {team} flag carried by slot {c} ({p.team}) at ({p.x},{p.y}) hp={p.hp}"
