import
  helpers,
  std/unittest,
  ctf/sim

proc pointBlank(sim: var SimServer, shooter, target: int) =
  ## Stands the target one body-width east of the shooter, both aimed so the
  ## shooter's shot locks onto the target, cooldown cleared for an instant fire.
  sim.players[shooter].x = 300
  sim.players[shooter].y = 300
  sim.players[shooter].aimBrads = 0            # east
  sim.players[shooter].fireCooldown = 0
  sim.players[target].x = 300 + 30
  sim.players[target].y = 300

proc lastDamage(sim: SimServer): SimEvent =
  ## The most recently emitted Damage event.
  for i in countdown(sim.events.high, 0):
    if sim.events[i].kind == Damage:
      return sim.events[i]
  raise newException(ValueError, "no Damage event emitted")

suite "blocked damage (shield-absorbed hp)":
  test "a hit on a full shield carrier reports blocked = 1":
    var sim = twoTeamGame(collectEvents = true)
    sim.pointBlank(0, 1)
    # GV22 models the shield as a separate layer (shieldHp), depleted before
    # base hp — not bonus hp stacked on top of the base pool.
    sim.players[1].hasShield = true
    sim.players[1].shieldHp = ShieldLayerHp      # 3: full shield layer
    let baseBefore = sim.players[1].hp           # base hp untouched by the hit
    sim.tryFire(0)
    let dmg = sim.lastDamage()
    check dmg.kind == Damage
    check dmg.amount == 1
    # The whole 1-hp hit landed on the shield layer, so base hp is unchanged.
    check dmg.hp == baseBefore
    check dmg.blocked == 1

  test "blocked stops once the shield layer is empty":
    # Walk a full-shield carrier down one hp per shot. Every hit taken while the
    # shield layer still has hp is soaked (blocked = 1); once the layer is empty
    # the hit touches the base cog and is NOT blocked.
    var sim = twoTeamGame(collectEvents = true)
    sim.pointBlank(0, 1)
    sim.players[1].hasShield = true
    sim.players[1].shieldHp = ShieldLayerHp      # 3
    var blockedTotal = 0
    for _ in 0 ..< 5:
      sim.players[0].fireCooldown = 0            # re-arm each shot
      if not sim.players[1].alive:
        break
      let shieldBefore = sim.players[1].shieldHp
      sim.tryFire(0)
      let dmg = sim.lastDamage()
      # Blocked iff the shield layer still had hp when the hit landed.
      if shieldBefore > 0:
        check dmg.blocked == 1
      else:
        check dmg.blocked == 0
      blockedTotal += dmg.blocked
    # Exactly the full shield layer (ShieldLayerHp) was ever shield-absorbed.
    check blockedTotal == ShieldLayerHp

  test "a hit on a shieldless cog blocks nothing":
    var sim = twoTeamGame(collectEvents = true)
    sim.pointBlank(0, 1)
    check not sim.players[1].hasShield
    check sim.players[1].shieldHp == 0
    check sim.players[1].hp == sim.config.hitPoints
    sim.tryFire(0)
    let dmg = sim.lastDamage()
    check dmg.amount == 1
    check dmg.blocked == 0

  test "blocked never enters the game hash":
    # The field rides the analysis-only event sink; it must not perturb the
    # replay-safe hash.
    var a = twoTeamGame(collectEvents = true)
    var b = twoTeamGame(collectEvents = true)
    a.pointBlank(0, 1)
    b.pointBlank(0, 1)
    a.players[1].hasShield = true
    b.players[1].hasShield = true
    a.players[1].shieldHp = ShieldLayerHp
    b.players[1].shieldHp = ShieldLayerHp
    a.tryFire(0)
    b.tryFire(0)
    check a.lastDamage().blocked == 1
    check a.gameHash == b.gameHash
