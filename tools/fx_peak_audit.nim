import std/os, ../src/ctf/replays, ../src/ctf/sim

# Re-simulates a replay and reports the PEAK size of every capped cosmetic FX
# list against its board-render pool cap (global.nim). The render loops clamp
# with `min(list.len, cap)`, so a peak above its cap means that many effects
# silently vanished from spectator/replay views — exactly the 32-player bug
# this audits for (pools were sized for the old 16-player maximum).
#
# Usage: nim c -r tools/fx_peak_audit.nim <replay.bitreplay>

const
  # Render caps, mirrored from global.nim (private there). Keep in sync.
  TracerCap = MaxPlayers            # TracerMaxShots / muzzle blooms / heads
  HitFlashCap = MaxPlayers          # HitFlashMaxCount
  AirborneCap = MaxPlayers          # GrenadeMaxAirborne
  BlastCap = MaxPlayers             # GrenadeMaxBlasts
  ShoutCap = MaxPlayers             # ShoutMaxCount
  DamagePopCap = MaxPlayers         # DamagePopMaxCount
  SplatterCap = MaxPlayers * 2      # SplatterMaxCount
  PlasmaFlashCap = MaxPlayers       # PlasmaArcMaxFlashes

let path = commandLineParams()[0]
let gameDir = currentSourcePath().parentDir().parentDir()
setCurrentDir(gameDir)
let data = loadReplay(path)
var config = defaultGameConfig()
config.update(data.configJson)
var
  game = initSimServer(config)
  replay = initReplayPlayer(data)
game.gameEventLoggingEnabled = false
replay.looping = false
replay.mismatchQuit = true

var peaks: array[8, tuple[name: string, cap, peak, peakTick: int]] = [
  ("shot tracers", TracerCap, 0, -1),
  ("hit flashes", HitFlashCap, 0, -1),
  ("airborne grenades", AirborneCap, 0, -1),
  ("blast flashes", BlastCap, 0, -1),
  ("shouts", ShoutCap, 0, -1),
  ("damage pops", DamagePopCap, 0, -1),
  ("splatters", SplatterCap, 0, -1),
  ("plasma arc flashes", PlasmaFlashCap, 0, -1),
]

proc bump(slot: var tuple[name: string, cap, peak, peakTick: int], n, tick: int) =
  if n > slot.peak:
    slot.peak = n
    slot.peakTick = tick

while replay.playing:
  replay.stepReplay(game)
  let t = game.tickCount
  bump(peaks[0], game.recentShots.len, t)
  bump(peaks[1], game.hitFlashes.len, t)
  bump(peaks[2], game.airborneGrenades.len, t)
  bump(peaks[3], game.recentBlasts.len, t)
  bump(peaks[4], game.recentShouts.len, t)
  bump(peaks[5], game.damagePops.len, t)
  bump(peaks[6], game.splatters.len, t)
  bump(peaks[7], game.plasmaArcFlashes.len, t)

var dropped = false
for slot in peaks:
  let verdict =
    if slot.peak > slot.cap: (dropped = true; "DROPPED " & $(slot.peak - slot.cap))
    else: "ok"
  echo slot.name, ": peak ", slot.peak, " / cap ", slot.cap,
    " (tick ", slot.peakTick, ") ", verdict
echo "paint stains recorded: ", game.paintStains.len, " / cap ", StainMaxCount
if dropped:
  echo "FAIL: at least one FX family exceeded its render pool cap"
  quit(1)
echo "ok: every FX family stayed within its render pool"
