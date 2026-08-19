import
  helpers,
  std/unittest,
  bitworld/spriteprotocol,
  ctf/sim

proc standOn(sim: var SimServer, playerIndex, spawnIndex: int) =
  ## Puts one player exactly on a med kit spawn point.
  sim.players[playerIndex].x = sim.medKitSpawns[spawnIndex].x - CollisionW div 2
  sim.players[playerIndex].y = sim.medKitSpawns[spawnIndex].y - CollisionH div 2

suite "med kits":
  test "two kits spawn on the walkable center line":
    let sim = twoTeamGame()
    for spawn in sim.medKitSpawns:
      check spawn.present
      check sim.canOccupy(spawn.x, spawn.y)
      check abs(spawn.x - MapWidth div 2) < 120
    check sim.medKitSpawns[0].y < MapHeight div 2
    check sim.medKitSpawns[1].y > MapHeight div 2

  test "a hurt player picks a kit up by touch and heals to full":
    var sim = twoTeamGame()
    sim.players[0].hp = 1
    sim.standOn(0, 0)
    sim.tryPickupMedKits(0)
    check sim.players[0].hp == sim.config.hitPoints
    check not sim.medKitSpawns[0].present
    check sim.medKitSpawns[1].present

  test "a healthy player never consumes a kit":
    var sim = twoTeamGame()
    sim.standOn(0, 0)
    sim.tryPickupMedKits(0)
    check sim.medKitSpawns[0].present
    check sim.players[0].hp == sim.config.hitPoints

  test "dead players cannot pick up a kit":
    var sim = twoTeamGame()
    sim.players[0].hp = 1
    sim.players[0].alive = false
    sim.standOn(0, 0)
    sim.tryPickupMedKits(0)
    check sim.medKitSpawns[0].present

  test "a taken kit respawns after its timer":
    var sim = twoTeamGame()
    sim.players[0].hp = 1
    sim.standOn(0, 0)
    sim.tryPickupMedKits(0)
    check not sim.medKitSpawns[0].present
    # Move the healed player away so the refilled kit is not retaken.
    sim.players[0].x = sim.players[0].homeX
    sim.players[0].y = sim.players[0].homeY
    let none = newSeq[InputState](sim.players.len)
    for _ in 0 ..< MedKitRespawnTicks + 1:
      sim.step(none, none)
    check sim.medKitSpawns[0].present

  test "med kits never block bullets":
    var sim = twoTeamGame()
    # A shot fired straight across a med kit spawn kills the target behind
    # it: kits are not walls, not LOS blockers, and not in any mask.
    let kit = sim.medKitSpawns[0]
    check not sim.isWall(kit.x, kit.y)
    sim.players[0].x = kit.x - 24
    sim.players[0].y = kit.y
    sim.players[0].aimBrads = 0          # east, straight over the kit
    sim.players[0].fireCooldown = 0
    sim.players[1].x = kit.x + 24
    sim.players[1].y = kit.y
    sim.players[1].hp = 1
    sim.tryFire(0)
    check not sim.players[1].alive

  test "spinning center diamonds are solid at their core":
    let sim = twoTeamGame()
    check AnimatedDiamonds.len == 8
    for spot in AnimatedDiamonds:
      # The center pixel is inside the diamond at every spin angle, so it is
      # wall for movement, LOS, and bullets no matter where the rotation is.
      # (The EDGES move — see tests/test_spinning_diamonds.nim.)
      check sim.isWall(spot.cx, spot.cy)
      check isAnimatedDiamondPixel(spot.cx, spot.cy)

  test "med kit state is in the game hash":
    var sim1 = twoTeamGame()
    var sim2 = twoTeamGame()
    check sim1.gameHash == sim2.gameHash
    sim1.players[0].hp = 1
    sim1.standOn(0, 0)
    sim1.tryPickupMedKits(0)
    sim2.players[0].hp = 1
    check sim1.gameHash != sim2.gameHash
