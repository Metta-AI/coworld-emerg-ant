## v6 aim-regression repro probe.
## Re-simulates one .bitreplay (hash-validated) and dumps, per sim tick and per
## seat: position, TRUE aimBrads, alive, fireWindup, windupBrads — plus the full
## tier-2 event stream and a roster/meta record. Everything the belief-vs-truth
## comparison against artlog needs.
##
## Usage: aim_repro_probe <replay-path> <out-prefix>

import
  std/[json, math, os, strformat, strutils],
  ../src/ctf/sim,
  toolutil

proc key(kind: SimEventKind): string =
  case kind
  of Shot: "shot"
  of Hit: "hit"
  of Damage: "damage"
  of Kill: "kill"
  of Death: "death"
  of FlagSteal: "flag_steal"
  of FlagReturn: "flag_return"
  of Capture: "capture"
  of Respawn: "respawn"
  of Heal: "heal"
  of PhaseChange: "phase"
  of GunTrigger: "gun_trigger"
  of ShotImpact: "shot_impact"
  of GrenadeThrow: "grenade_throw"
  of GrenadeImpact: "grenade_impact"
  of SprayUse: "spray_use"
  of Pickup: "item_pickup"
  of ShoutEvent: "shout"

let params = commandLineParams()
if params.len < 2:
  quit("Usage: aim_repro_probe <replay-path> <out-prefix>")
let
  replayPath = params[0].absolutePath()
  outPrefix = params[1].absolutePath()

chdirGameDir()
var (game, replay) = openReplay(replayPath)
game.collectEvents = true

var
  ticksFile: File
  eventsFile: File
if not open(ticksFile, outPrefix & ".ticks.csv", fmWrite):
  quit("cannot open ticks output")
if not open(eventsFile, outPrefix & ".events.jsonl", fmWrite):
  quit("cannot open events output")
ticksFile.write("t,i,x,y,aim,alive,hp,fw,wb\n")

var shotsFile: File
if not open(shotsFile, outPrefix & ".shots.csv", fmWrite):
  quit("cannot open shots output")
shotsFile.write("t,shooter,wb,tgt_los,tgt_nolos,perp,along\n")

var lastWb: seq[int] = @[]

proc shotGeometry(g: SimServer, shooter, lockedBrads: int, useLos: bool):
    tuple[target: int, perp, along: float] =
  ## Replica of sim.selectFireTarget, optionally with the LOS test disabled.
  result = (-1, -1.0, -1.0)
  let
    p = g.players[shooter]
    (ux, uy) = aimVector(lockedBrads)
    sx = p.x + CollisionW div 2
    sy = p.y + CollisionH div 2
    maxRange = float(g.config.gunRange)
  var bestT = maxRange + 1.0
  for i in 0 ..< g.players.len:
    if i == shooter or not g.players[i].alive: continue
    let
      tx = float(g.players[i].x + CollisionW div 2)
      ty = float(g.players[i].y + CollisionH div 2)
    for off in countup(-PlayerHalf, PlayerHalf, ExposureSampleStep):
      let
        px = tx - float(off) * uy
        py = ty + float(off) * ux
        vx = px - float(sx)
        vy = py - float(sy)
        t = vx * ux + vy * uy
      if t <= 0 or t > maxRange: continue
      let cross = abs(vx * uy - vy * ux)
      if cross > BulletHalfWidth: continue
      if useLos and not g.lineOfSightClear(sx, sy, int(round(px)), int(round(py))):
        continue
      if t < bestT:
        bestT = t
        result = (i, cross, t)
      break

var gameStartSeen = -1
while replay.playing:
  replay.stepReplay(game)
  let t = game.tickCount
  if game.phase == Playing and gameStartSeen < 0:
    gameStartSeen = game.gameStartTick
  for i, p in game.players:
    ticksFile.write(&"{t},{i},{p.x},{p.y},{p.aimBrads},{ord(p.alive)},{p.hp},{p.fireWindup},{p.windupBrads}\n")
  for ev in game.events:
    if ev.kind == Shot and ev.source >= 0:
      let wb =
        if ev.source < lastWb.len and lastWb[ev.source] >= 0: lastWb[ev.source]
        else: game.players[ev.source].aimBrads
      let
        withLos = game.shotGeometry(ev.source, wb, true)
        noLos = game.shotGeometry(ev.source, wb, false)
      shotsFile.write(&"{t},{ev.source},{wb},{withLos.target},{noLos.target},{noLos.perp:.2f},{noLos.along:.2f}\n")
    var row = newJObject()
    row["tick"] = %ev.tick
    row["kind"] = %ev.kind.key()
    row["source"] = %ev.source
    row["target"] = %ev.target
    row["weapon"] = %ev.weapon
    row["amount"] = %ev.amount
    row["hp"] = %ev.hp
    row["blocked"] = %ev.blocked
    row["x"] = %ev.x
    row["y"] = %ev.y
    eventsFile.write($row & "\n")
  game.events.setLen(0)
  while lastWb.len < game.players.len: lastWb.add(-1)
  for i, p in game.players: lastWb[i] = p.windupBrads
ticksFile.close()
shotsFile.close()
eventsFile.close()

var meta = newJObject()
meta["replay"] = %replayPath
meta["ticks"] = %game.tickCount
meta["gameStartTick"] = %game.gameStartTick
meta["winner"] = %($game.winner)
meta["isDraw"] = %game.isDraw
meta["gameVersion"] = %GameVersion
var roster = newJArray()
for i, p in game.players:
  var r = newJObject()
  r["index"] = %i
  r["joinOrder"] = %p.joinOrder
  r["address"] = %p.address
  r["team"] = %($p.team)
  r["shotsFired"] = %p.shotsFired
  r["shotsHit"] = %p.shotsHit
  r["kills"] = %p.kills
  r["deaths"] = %p.deaths
  r["captures"] = %p.captures
  r["lives"] = %p.lives
  roster.add(r)
meta["roster"] = roster
writeFile(outPrefix & ".meta.json", meta.pretty() & "\n")
echo &"{extractFilename(replayPath)} ticks={game.tickCount} gameStart={game.gameStartTick} winner={game.winner} draw={game.isDraw}"
