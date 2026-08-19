import std/[os, tables], ../src/ctf/sim, toolutil

# Re-simulates a replay and reports, per policy, the evidence that each perk
# actually played: max hit points (armor), the fastest per-axis speed any seat
# reached (thruster), gun accuracy (scope), and gun hits that dealt more than
# 1 damage (luck). Ground-truth check for perk-configured recordings.

let path = commandLineParams()[0]
chdirGameDir()
var (game, replay) = openReplay(path)
game.collectEvents = true

type PolicyStats = object
  perks: PerkSet
  maxHp: int
  topSpeed: int
  shotsFired, shotsHit: int
  gunHits1, gunHits2plus: int

var stats = initOrderedTable[string, PolicyStats]()

proc policyOfSlot(game: SimServer, slot: int): string =
  for p in game.players:
    if p.joinOrder == slot:
      return policyName(p.address)
  ""

while replay.playing:
  replay.stepReplay(game)
  for p in game.players:
    let pol = policyName(p.address)
    discard stats.hasKeyOrPut(pol, PolicyStats())
    stats[pol].perks = p.perks
    stats[pol].maxHp = max(stats[pol].maxHp,
      game.config.maxHpFor(p.team, p.perks))
    stats[pol].topSpeed = max(stats[pol].topSpeed,
      max(abs(p.velX), abs(p.velY)))
  for e in game.events:
    if e.kind == Damage and e.weapon == "gun":
      let pol = game.policyOfSlot(e.source)
      if pol.len > 0:
        if e.amount >= 2: inc stats[pol].gunHits2plus
        else: inc stats[pol].gunHits1
  game.events.setLen(0)

for p in game.players:
  let pol = policyName(p.address)
  stats[pol].shotsFired += p.shotsFired
  stats[pol].shotsHit += p.shotsHit

echo "base: hitPoints=", game.config.hitPoints,
  " maxSpeed=", game.config.maxSpeed
for pol, s in stats:
  let acc =
    if s.shotsFired > 0: 100 * s.shotsHit div s.shotsFired
    else: 0
  echo pol, "  perks=", s.perks,
    "  maxHp=", s.maxHp,
    "  topSpeed=", s.topSpeed,
    "  shots=", s.shotsHit, "/", s.shotsFired, " (", acc, "%)",
    "  gunDmg1=", s.gunHits1, "  gunDmg2+=", s.gunHits2plus
