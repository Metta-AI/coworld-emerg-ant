import std/[os, tables], ../src/ctf/sim, toolutil

# Re-simulates a replay and counts every applied shout (per shouter, per text).

let path = commandLineParams()[0]
chdirGameDir()
var (game, replay) = openReplay(path)

var seen = initTable[string, int]()
var lastTickSeen = initTable[string, int]()
while replay.playing:
  replay.stepReplay(game)
  for s in game.recentShouts:
    let key = s.address & " | " & s.text
    if lastTickSeen.getOrDefault(s.address, -1) != s.tick:
      lastTickSeen[s.address] = s.tick
      seen[key] = seen.getOrDefault(key, 0) + 1
for k, v in seen:
  echo v, "x  ", k
echo "distinct shout texts: ", seen.len
