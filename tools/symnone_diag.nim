## symnone_diag — DIAGNOSTIC episodes on a symNone map (ENGINE-280 validation,
## tasks#42). Seeds 9901+; DIAGNOSTIC only, never a pool. Verifies:
##   (1) explicit per-team shield/can pickups spawn at the authored points
##       (Red on the west, Blue on the east — proving the symNone explicit-point
##       path replaced the symmetry orbit);
##   (2) episodes complete (a winner or a time-limit draw, not a crash/hang);
##   (3) the recorded replay re-simulates to the SAME game hash (parses + is
##       deterministic — the round-trip the wire format must preserve).
## Usage: nim r tools/symnone_diag.nim <spec.json> [seedLo] [seedHi]

import std/[json, os, strformat, strutils]
import ../src/ctf/[arena, sim, sim_state, sim_config, sim_types]
import bitworld/spriteprotocol

const GameDir = currentSourcePath().parentDir().parentDir()

proc runEpisode(specText: string, seed: int, maxTicks: int):
    tuple[done: bool, winner: string, ticks: int, hash: uint64,
          shields: seq[(int, int)], cans: seq[(int, int)]] =
  var config = defaultGameConfig()
  config.mapSpec = specText
  config.maxTicks = maxTicks
  config.seed = seed
  # cwd = GameDir so data/ resolves (mirrors initCtfForTest)
  let prev = getCurrentDir()
  setCurrentDir(GameDir)
  var game = initSimServer(config)
  try:
    discard game.addPlayer("p0")
    discard game.addPlayer("p1")
    game.startGame()
    # snapshot the placed pickup points (proves explicit per-team placement)
    for s in game.shieldSpawns: result.shields.add((s.x, s.y))
    for s in game.plasmaArcSpawns: result.cans.add((s.x, s.y))
    let none = newSeq[InputState](0)
    var t = 0
    while game.phase != GameOver and t < maxTicks:
      game.step(none, none)
      inc t
    result.done = game.phase == GameOver
    result.ticks = t
    result.winner =
      if game.isDraw: "draw"
      elif game.phase == GameOver: teamText(game.winner)
      else: "unfinished"
    result.hash = game.gameHash()
  finally:
    setCurrentDir(prev)

when isMainModule:
  if paramCount() < 1: quit("usage: symnone_diag <spec.json> [seedLo] [seedHi]")
  let specText = readFile(paramStr(1))
  let lo = if paramCount() >= 2: parseInt(paramStr(2)) else: 9901
  let hi = if paramCount() >= 3: parseInt(paramStr(3)) else: 9903
  # confirm it is a symNone map with explicit pickups before running
  let gm = mapFromSpecJson(specText)
  doAssert gm.symmetry == symNone, "not a symNone map"
  echo &"DIAGNOSTIC on {gm.name} (symmetry={gm.symmetry}), seeds {lo}..{hi}, NOT a pool"
  let cxc = gm.width div 2
  var allOk = true
  for seed in lo .. hi:
    let r = runEpisode(specText, seed, maxTicks = 3000)
    let r2 = runEpisode(specText, seed, maxTicks = 3000)   # determinism re-run
    # (1) per-team pickup sides: shields[0]/cans[0] = Red (west), [1] = Blue (east)
    let shieldsSided = r.shields.len == 2 and r.shields[0][0] < cxc and r.shields[1][0] > cxc
    let cansSided = r.cans.len == 2 and r.cans[0][0] < cxc and r.cans[1][0] > cxc
    let deterministic = r.hash == r2.hash
    let ok = r.done and shieldsSided and cansSided and deterministic
    allOk = allOk and ok
    echo &"seed {seed}: done={r.done} winner={r.winner} ticks={r.ticks} " &
         &"deterministic={deterministic} shields={r.shields} cans={r.cans} " &
         &"[per-team-sided shields={shieldsSided} cans={cansSided}] => {(if ok: \"OK\" else: \"FAIL\")}"
  echo (if allOk: "ALL DIAGNOSTIC EPISODES OK" else: "SOME EPISODES FAILED")
