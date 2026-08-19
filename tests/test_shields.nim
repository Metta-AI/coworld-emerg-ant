import
  helpers,
  std/unittest,
  bitworld/spriteprotocol,
  ctf/sim

proc standOn(sim: var SimServer, playerIndex, spawnIndex: int) =
  ## Puts one player exactly on a shield spawn point.
  sim.players[playerIndex].x = sim.shieldSpawns[spawnIndex].x - CollisionW div 2
  sim.players[playerIndex].y = sim.shieldSpawns[spawnIndex].y - CollisionH div 2

suite "shields":
  test "one shield spawns in each team's endzone on walkable floor":
    let sim = twoTeamGame()
    check sim.shieldSpawns.len == 2
    for spawn in sim.shieldSpawns:
      check spawn.present
      check sim.canOccupy(spawn.x, spawn.y)
      # Shields live in the BOTTOM half (three-quarter height); the plasma arcs
      # hold the matching top-half spots.
      check abs(spawn.y - 3 * MapHeight div 4) < 120
      check spawn.y > MapHeight div 2
    # One shield on the red (left) half, one on the blue (right) half.
    check sim.shieldSpawns[0].x < MapWidth div 2
    check sim.shieldSpawns[1].x > MapWidth div 2

  test "picking up a shield adds a full 3 hp shield layer over base hp":
    var sim = twoTeamGame()
    check ShieldLayerHp == 3
    check sim.players[0].hp == sim.config.hitPoints
    sim.standOn(0, 0)
    sim.tryPickupShields(0)
    check sim.players[0].hasShield
    check sim.players[0].hp == sim.config.hitPoints
    check sim.players[0].shieldHp == ShieldLayerHp
    check not sim.shieldSpawns[0].present
    check sim.shieldSpawns[1].present

  test "a shield pickup never heals base damage":
    # A hurt shieldless player gains the 3 hp layer on top of its damaged
    # base — the base damage stays until a med kit heals it.
    var sim = twoTeamGame()
    sim.players[0].hp = 1
    sim.standOn(0, 0)
    sim.tryPickupShields(0)
    check sim.players[0].hasShield
    check sim.players[0].hp == 1
    check sim.players[0].shieldHp == ShieldLayerHp
    check not sim.shieldSpawns[0].present

  test "damage depletes the shield layer before base hp":
    var sim = twoTeamGame()
    sim.players[0].hasShield = true
    sim.players[0].shieldHp = ShieldLayerHp
    sim.players[0].fireCooldown = 0
    sim.players[0].x = 300
    sim.players[0].y = 300
    sim.players[0].aimBrads = 0
    sim.players[1].x = 300 + 30
    sim.players[1].y = 300
    sim.players[1].hasShield = true
    sim.players[1].shieldHp = 2
    sim.tryFire(0)
    check sim.players[1].shieldHp == 1
    check sim.players[1].hp == sim.config.hitPoints
    # A hit larger than the remaining layer spills into base hp.
    sim.absorbDamage(1, 2)
    check sim.players[1].shieldHp == 0
    check sim.players[1].hp == sim.config.hitPoints - 1

  test "a worn carrier can take another shield to refill the layer":
    var sim = twoTeamGame()
    sim.players[0].hasShield = true
    sim.players[0].shieldHp = 0
    sim.players[0].hp = 2
    sim.standOn(0, 0)
    sim.tryPickupShields(0)
    check sim.players[0].hasShield
    check sim.players[0].shieldHp == ShieldLayerHp
    check sim.players[0].hp == 2
    check not sim.shieldSpawns[0].present
    check sim.shieldSpawns[0].respawnAt == sim.tickCount + ShieldRespawnTicks

  test "repeated pickups cannot launder base damage away":
    # Base damage + an intact layer: another shield grants nothing, so the
    # spawn is left untouched and the base stays hurt.
    var sim = twoTeamGame()
    sim.players[0].hasShield = true
    sim.players[0].shieldHp = ShieldLayerHp
    sim.players[0].hp = 1
    sim.standOn(0, 0)
    sim.tryPickupShields(0)
    check sim.players[0].hp == 1
    check sim.players[0].shieldHp == ShieldLayerHp
    check sim.shieldSpawns[0].present

  test "a med kit heals base damage under an intact shield":
    var sim = twoTeamGame()
    sim.players[0].hasShield = true
    sim.players[0].shieldHp = ShieldLayerHp
    sim.players[0].hp = 1
    sim.players[0].x = sim.medKitSpawns[0].x - CollisionW div 2
    sim.players[0].y = sim.medKitSpawns[0].y - CollisionH div 2
    sim.tryPickupMedKits(0)
    check sim.players[0].hp == sim.config.hitPoints
    check sim.players[0].shieldHp == ShieldLayerHp

  test "a shield carrier can still shoot and kill":
    var sim = twoTeamGame()
    sim.players[0].x = 300
    sim.players[0].y = 300
    sim.players[0].aimBrads = 0           # east
    sim.players[0].fireCooldown = 0
    sim.players[0].hasShield = true
    sim.players[1].x = 300 + 30
    sim.players[1].y = 300
    sim.players[1].hp = 1
    sim.tryFire(0)
    check not sim.players[1].alive

  test "a shield carrier's fire cooldown is 3x the normal cooldown":
    # Control: no shield, a shot starts the normal cooldown.
    var ctrl = twoTeamGame()
    ctrl.players[0].fireCooldown = 0
    ctrl.tryFire(0)
    check ctrl.players[0].fireCooldown == ctrl.config.fireCooldownTicks

    # Same shot with a shield: the cooldown is ShieldFireSlowdown times longer.
    var sim = twoTeamGame()
    sim.players[0].fireCooldown = 0
    sim.players[0].hasShield = true
    sim.tryFire(0)
    check ShieldFireSlowdown == 3
    check sim.players[0].fireCooldown ==
      sim.config.fireCooldownTicks * ShieldFireSlowdown

  test "a full-layer carrier does not waste a spawn":
    var sim = twoTeamGame()
    sim.standOn(0, 0)
    sim.tryPickupShields(0)
    check sim.players[0].hasShield
    check sim.players[0].shieldHp == ShieldLayerHp
    # Standing on the second shield with an intact layer takes nothing — a
    # pickup that would grant 0 leaves the spawn for a teammate.
    sim.standOn(0, 1)
    sim.tryPickupShields(0)
    check sim.shieldSpawns[1].present

  test "dead players cannot pick up a shield":
    var sim = twoTeamGame()
    sim.players[0].alive = false
    sim.standOn(0, 0)
    sim.tryPickupShields(0)
    check sim.shieldSpawns[0].present

  test "a taken shield respawns after 30 seconds":
    var sim = twoTeamGame()
    check ShieldRespawnTicks == 30 * ReplayFps
    sim.standOn(0, 0)
    sim.tryPickupShields(0)
    check not sim.shieldSpawns[0].present
    # Move the carrier away so the refilled shield is not retaken.
    sim.players[0].x = sim.players[0].homeX
    sim.players[0].y = sim.players[0].homeY
    let none = newSeq[InputState](sim.players.len)
    for _ in 0 ..< ShieldRespawnTicks + 1:
      sim.step(none, none)
    check sim.shieldSpawns[0].present

  test "a depleted shield layer breaks the shield outright":
    # GV23: when the last layer hp goes, the shield is GONE — carry icon,
    # " shield" label, and fire slowdown all end with the bubble.
    var sim = twoTeamGame()
    sim.standOn(0, 0)
    sim.tryPickupShields(0)
    check sim.players[0].hasShield
    # A slowed cooldown is mid-flight when the layer breaks: it re-clamps.
    sim.players[0].fireCooldown =
      sim.config.fireCooldownTicks * ShieldFireSlowdown
    sim.absorbDamage(0, ShieldLayerHp)
    check sim.players[0].shieldHp == 0
    check not sim.players[0].hasShield
    check sim.players[0].hp == sim.config.hitPoints
    check sim.players[0].fireCooldown <= sim.config.fireCooldownTicks
    # The next shot starts the NORMAL cooldown.
    sim.players[0].fireCooldown = 0
    sim.tryFire(0)
    check sim.players[0].fireCooldown == sim.config.fireCooldownTicks

  test "a partially depleted layer keeps the shield":
    var sim = twoTeamGame()
    sim.standOn(0, 0)
    sim.tryPickupShields(0)
    sim.absorbDamage(0, ShieldLayerHp - 1)
    check sim.players[0].hasShield
    check sim.players[0].shieldHp == 1

  test "a broken-shield player can take a fresh shield":
    var sim = twoTeamGame()
    sim.standOn(0, 0)
    sim.tryPickupShields(0)
    sim.absorbDamage(0, ShieldLayerHp)
    check not sim.players[0].hasShield
    sim.standOn(0, 1)
    sim.tryPickupShields(0)
    check sim.players[0].hasShield
    check sim.players[0].shieldHp == ShieldLayerHp

  test "dying loses the carried shield":
    var sim = twoTeamGame()
    sim.players[0].hasShield = true
    sim.players[0].shieldHp = 0
    sim.players[0].hp = 1
    sim.players[1].x = sim.players[0].x + 40
    sim.players[1].y = sim.players[0].y
    sim.players[1].aimBrads = 128         # west, at player 0
    var inputs = newSeq[InputState](sim.players.len)
    inputs[1].attack = true
    let none = newSeq[InputState](sim.players.len)
    var prev = none
    while sim.players[0].alive and sim.tickCount < 200:
      sim.step(inputs, prev)
      prev = inputs
    check not sim.players[0].alive
    check not sim.players[0].hasShield
    check sim.players[0].shieldHp == 0

  test "shield state is in the game hash":
    var sim1 = twoTeamGame()
    var sim2 = twoTeamGame()
    check sim1.gameHash == sim2.gameHash
    sim1.players[0].hasShield = true
    check sim1.gameHash != sim2.gameHash
    sim1.players[0].hasShield = false
    sim1.players[0].shieldHp = 2
    check sim1.gameHash != sim2.gameHash
    sim1.players[0].shieldHp = 0
    sim1.shieldSpawns[0].present = false
    check sim1.gameHash != sim2.gameHash
