import std/[os, json, sets, tables], ../src/ctf/sim, toolutil

# Grenade/plasma forensics: every throw (thrower/launch/landing), blast damage
# attribution (hp drops within radius at landing tick), enemy CLUSTERS
# (2+ same-team players within 110px), per-player grenade possession time,
# and plasma arc firings. JSON out.

let path = commandLineParams()[0].absolutePath()
chdirGameDir()
var (game, replay) = openReplay(path)

let seatCap = game.config.playerSlotLimit()
var
  joins = newJArray()
  throws = newJArray()
  seenPlayers = 0
  liveNades = initHashSet[int]()          # launchTick*1000+thrower key
  nadeInfo = initTable[int, JsonNode]()
  prevHp = newSeq[int](seatCap)
  prevHasNade = newSeq[bool](seatCap)
  prevArcTicks = newSeq[int](seatCap)
  nadeHeldTicks = newSeq[int](seatCap)
  arcFires = newSeq[int](seatCap)
  clusters = newJArray()
  lastClusterSample = 0

while replay.playing:
  replay.stepReplay(game)
  let t = game.tickCount
  while seenPlayers < game.players.len and seenPlayers < seatCap:
    let p = game.players[seenPlayers]
    joins.add(%*{"i": seenPlayers, "slot": p.joinOrder, "team": teamText(p.team),
                 "addr": p.address})
    prevHp[seenPlayers] = p.hp
    inc seenPlayers

  # grenade flight tracking
  var current = initHashSet[int]()
  for g in game.airborneGrenades:
    let key = g.launchTick * 100 + g.thrower
    current.incl key
    if key notin liveNades:
      nadeInfo[key] = %*{"t": g.launchTick, "thrower": g.thrower,
        "sx": g.sx, "sy": g.sy, "tx": g.tx, "ty": g.ty,
        "land": g.launchTick + g.flightTicks}
  # landed this tick: attribute blast damage from hp drops near the target
  for key in liveNades:
    if key notin current and key in nadeInfo:
      var info = nadeInfo[key]
      var hits = newJArray()
      for i in 0 ..< min(game.players.len, seatCap):
        let p = game.players[i]
        let dx = (p.x + CollisionW div 2) - info["tx"].getInt
        let dy = (p.y + CollisionH div 2) - info["ty"].getInt
        if dx*dx + dy*dy <= (GrenadeBlastRadius + 30) * (GrenadeBlastRadius + 30) and
            p.hp < prevHp[i]:
          hits.add(%*{"i": i, "dmg": prevHp[i] - p.hp, "died": not p.alive})
      info["hits"] = hits
      throws.add(info)
  liveNades = current

  for i in 0 ..< min(game.players.len, seatCap):
    let p = game.players[i]
    if p.hasGrenade: inc nadeHeldTicks[i]
    if p.arcTicksLeft > 0 and prevArcTicks[i] == 0: inc arcFires[i]
    prevArcTicks[i] = p.arcTicksLeft
    prevHasNade[i] = p.hasGrenade
    prevHp[i] = p.hp

  # cluster sampling every 25 ticks: same-team pairs within 110px
  if t - lastClusterSample >= 25 and game.players.len >= seatCap:
    lastClusterSample = t
    for team in game.teams:
      var members: seq[int]
      for i in 0 ..< min(game.players.len, seatCap):
        if game.players[i].team == team and game.players[i].alive:
          members.add i
      var counted = initHashSet[int]()
      for a in 0 ..< members.len:
        for b in (a+1) ..< members.len:
          let pa = game.players[members[a]]
          let pb = game.players[members[b]]
          let dx = pa.x - pb.x
          let dy = pa.y - pb.y
          if dx*dx + dy*dy <= 110*110:
            counted.incl members[a]
            counted.incl members[b]
      if counted.len >= 2:
        var cx, cy = 0
        for m in counted: (cx += game.players[m].x; cy += game.players[m].y)
        clusters.add(%*{"t": t, "team": teamText(team), "n": counted.len,
          "x": cx div counted.len, "y": cy div counted.len})

var summary = newJArray()
for i in 0 ..< min(game.players.len, seatCap):
  summary.add(%*{"i": i, "nadeHeld": nadeHeldTicks[i], "arcFires": arcFires[i],
    "kills": game.players[i].kills})
echo $(%*{"ticks": game.tickCount, "joins": joins, "throws": throws,
  "clusters": clusters, "summary": summary})
