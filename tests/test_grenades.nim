import
  helpers,
  std/[math, unittest],
  bitworld/spriteprotocol,
  ctf/sim

proc stepWith(sim: var SimServer, inputs, prev: seq[InputState]) =
  sim.step(inputs, prev)

proc landGrenadeAt(sim: var SimServer, throwerIndex, tx, ty: int) =
  ## Bursts one grenade on an exact map point, bypassing aim and charge so a
  ## test can place the blast center to the pixel.
  sim.airborneGrenades.add AirborneGrenade(
    sx: tx, sy: ty, tx: tx, ty: ty,
    launchTick: sim.tickCount, flightTicks: 1,
    thrower: throwerIndex,
    throwerSlot: sim.players[throwerIndex].joinOrder,
    throwerAccount: -1
  )
  let prev = sim.none()
  sim.stepWith(sim.none(), prev)

suite "grenades":
  test "corner pickups exist on both sides and refill after 5 seconds":
    var game = twoTeamGame()
    check game.grenadeSpawns.len == 4
    for spawn in game.grenadeSpawns:
      check spawn.present
      check game.isWalkable(spawn.x, spawn.y)
    # Two spawns on the red (left) half, two on the blue (right) half.
    var left = 0
    for spawn in game.grenadeSpawns:
      if spawn.x < MapWidth div 2:
        inc left
    check left == 2
    # Pick one up and watch the corner refill exactly 5s later.
    game.players[0].x = game.grenadeSpawns[0].x
    game.players[0].y = game.grenadeSpawns[0].y
    let prev = game.none()
    game.stepWith(game.none(), prev)
    check game.players[0].hasGrenade
    check not game.grenadeSpawns[0].present
    game.players[0].x = 300
    while not game.grenadeSpawns[0].present:
      game.stepWith(game.none(), prev)
    check game.tickCount <= 2 + GrenadeRespawnTicks + 1

  test "a player carries at most one grenade":
    var game = twoTeamGame()
    game.players[0].x = game.grenadeSpawns[0].x
    game.players[0].y = game.grenadeSpawns[0].y
    let prev = game.none()
    game.stepWith(game.none(), prev)
    check game.players[0].hasGrenade
    # Standing on the second spawn with a grenade in hand takes nothing.
    game.players[0].x = game.grenadeSpawns[1].x
    game.players[0].y = game.grenadeSpawns[1].y
    game.stepWith(game.none(), prev)
    check game.grenadeSpawns[1].present

  test "charge picks the distance and max is a fifth of the field":
    check GrenadeMaxRange == MapWidth div 5
    var game = twoTeamGame()
    game.players[0].x = 300
    game.players[0].y = 300
    game.players[0].aimBrads = 0          # east
    game.players[0].hasGrenade = true
    game.chargeAndThrow(0, GrenadeChargeTicks + 10)
    check game.airborneGrenades.len == 1
    let grenade = game.airborneGrenades[0]
    check grenade.tx - grenade.sx == GrenadeMaxRange
    check grenade.ty == grenade.sy
    check not game.players[0].hasGrenade

  test "a tap throws short":
    var game = twoTeamGame()
    game.players[0].x = 300
    game.players[0].y = 300
    game.players[0].aimBrads = 0
    game.players[0].hasGrenade = true
    game.chargeAndThrow(0, 1)
    check game.airborneGrenades.len == 1
    let grenade = game.airborneGrenades[0]
    check grenade.tx - grenade.sx <
      GrenadeMinRange + (GrenadeMaxRange - GrenadeMinRange) div 4

  test "grenades fly over walls and explode on landing":
    var game = twoTeamGame()
    # The chevron wall pair straddles x=479..506 near the vertical center;
    # a bullet cannot cross it, a grenade sails over.
    game.players[0].x = 460
    game.players[0].y = game.gameMap.center.y
    game.players[0].aimBrads = 0
    game.players[0].hasGrenade = true
    game.players[1].x = 460 + GrenadeMaxRange
    game.players[1].y = game.gameMap.center.y
    game.players[1].hp = GrenadeDamage
    var wallBetween = false
    for x in 461 ..< 460 + GrenadeMaxRange:
      if game.isWall(x, game.gameMap.center.y):
        wallBetween = true
    check wallBetween
    game.chargeAndThrow(0, GrenadeChargeTicks)
    check game.airborneGrenades.len == 1
    let flight = game.airborneGrenades[0].flightTicks
    let prev = game.none()
    for _ in 0 .. flight:
      game.stepWith(game.none(), prev)
    check game.airborneGrenades.len == 0
    check not game.players[1].alive
    check game.players[0].kills == 1

  test "the burst is a fixed two shot windups after release, near or far":
    for charge in [1, GrenadeChargeTicks div 2, GrenadeChargeTicks]:
      var game = twoTeamGame()
      game.players[0].x = 300
      game.players[0].y = 300
      game.players[0].aimBrads = 0
      game.players[0].hasGrenade = true
      game.chargeAndThrow(0, charge)
      check game.airborneGrenades.len == 1
      check game.airborneGrenades[0].flightTicks ==
        GrenadeFlightMultiple * game.config.fireWindupTicks

  test "the blast hurts everyone in the radius, thrower and teammates too":
    var game = initCtfForTest(defaultGameConfig())
    discard game.addPlayer("red0")
    discard game.addPlayer("red1")
    discard game.addPlayer("blue0")
    game.startGame()
    game.players[0].team = Red
    game.players[1].team = Red
    game.players[2].team = Blue
    for i in 0 ..< 3:
      game.players[i].x = 300
      game.players[i].y = 300 + i * 4    # all inside the blast radius
      game.players[i].hp = GrenadeDamage + 1
    game.players[0].aimBrads = 0
    game.players[0].hasGrenade = true
    game.chargeAndThrow(0, 1)            # short toss lands nearby
    let flight = game.airborneGrenades[0].flightTicks
    let prev = game.none()
    for _ in 0 .. flight:
      game.stepWith(game.none(), prev)
    for i in 0 ..< 3:
      check game.players[i].hp == 1
    check game.recentBlasts.len == 1

  test "the blast catches a body whose footprint overlaps the circle":
    # A blast tests the 12px body box, not the position point — the same rule
    # the gun's bullet corridor already uses. On-axis that puts the last
    # damaging center exactly GrenadeBlastRadius + PlayerHalf away.
    for (offset, expectHit) in [
      (GrenadeBlastRadius, true),
      (GrenadeBlastRadius + PlayerHalf, true),
      (GrenadeBlastRadius + PlayerHalf + 1, false)
    ]:
      var game = twoTeamGame()
      game.players[0].x = 300          # thrower parked well clear of the burst
      game.players[0].y = 500
      game.players[1].x = 300 + offset
      game.players[1].y = 300
      game.players[1].hp = GrenadeDamage + 1
      game.landGrenadeAt(0, 300, 300)
      check (game.players[1].hp < GrenadeDamage + 1) == expectHit

  test "a blast absorbed by a bubble blinks the bubble and leaves the body clean":
    var game = twoTeamGame()
    game.players[0].x = 300
    game.players[0].y = 500
    game.players[1].x = 300
    game.players[1].y = 300
    game.players[1].hp = HitPoints
    game.players[1].hasShield = true
    game.players[1].shieldHp = ShieldLayerHp
    game.players[1].paintHitTick = -1
    game.landGrenadeAt(0, 300, 300)
    check game.players[1].hp == HitPoints
    check game.players[1].shieldHp == ShieldLayerHp - GrenadeDamage
    check game.bubbleImpacts.len == 1
    check game.bubbleImpacts[0].playerIndex == 1
    # A bubble that eats the blast keeps the body clean, exactly as with a
    # paintball — so no visor splat fires for an absorbed hit.
    check game.players[1].paintHitTick == -1

  test "a blast on a bare cog paints it and blinks no bubble":
    var game = twoTeamGame()
    game.players[0].x = 300
    game.players[0].y = 500
    game.players[1].x = 300
    game.players[1].y = 300
    game.players[1].hp = GrenadeDamage + 1
    game.players[1].paintHitTick = -1
    game.landGrenadeAt(0, 300, 300)
    check game.bubbleImpacts.len == 0
    check game.players[1].paintHitTick == game.tickCount

  test "dying drops nothing: the carried grenade is simply lost":
    var game = twoTeamGame()
    game.players[0].hasGrenade = true
    game.players[0].hp = 1
    game.players[1].x = game.players[0].x + 40
    game.players[1].y = game.players[0].y
    game.players[1].aimBrads = 128       # west, at player 0
    var inputs = game.none()
    inputs[1].attack = true
    let prev = game.none()
    while game.players[0].alive and game.tickCount < 200:
      game.stepWith(inputs, prev)
    check not game.players[0].alive
    check not game.players[0].hasGrenade

  test "grenade state is in the game hash":
    var game = twoTeamGame()
    let before = game.gameHash()
    game.players[0].hasGrenade = true
    check game.gameHash() != before
    game.players[0].hasGrenade = false
    game.grenadeSpawns[0].present = false
    check game.gameHash() != before
