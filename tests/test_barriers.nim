import
  std/[json, unittest],
  bitworld/spriteprotocol,
  ctf/[global, labels, replays, sim]
import helpers except twoTeamGame

proc barrierGame(perTeam = 1): SimServer =
  ## A started game with one Red player (0) and one Blue player (1) on the
  ## classic map with `perTeam` barrier pickups per team — no map ships
  ## barriers by default.
  var config = defaultGameConfig()
  config.update("""{"barrierPickups": """ & $perTeam & "}")
  result = initCtfForTest(config)
  discard result.addPlayer("red0")
  discard result.addPlayer("blue0")
  result.startGame()
  result.players[0].team = Red
  result.players[1].team = Blue

proc standOn(sim: var SimServer, playerIndex, spawnIndex: int) =
  ## Puts one player's center exactly on a barrier spawn point.
  sim.players[playerIndex].x =
    sim.barrierSpawns[spawnIndex].x - CollisionW div 2
  sim.players[playerIndex].y =
    sim.barrierSpawns[spawnIndex].y - CollisionH div 2

proc pressPlace(sim: var SimServer, playerIndex: int) =
  ## One C press-edge tick followed by a release tick: the placement input.
  var held = sim.none()
  held[playerIndex].c = true
  sim.step(held, sim.none())
  sim.step(sim.none(), held)

proc plantFacing(sim: var SimServer, playerIndex, cx, cy, aimBrads: int):
    PlacedBarrier =
  ## Pins the player at a map point aiming `aimBrads`, places a barrier
  ## through the real input path, and returns the standing barrier.
  sim.placeStill(playerIndex, cx - CollisionW div 2, cy - CollisionH div 2)
  sim.players[playerIndex].aimBrads = aimBrads
  sim.players[playerIndex].hasBarrier = true
  sim.pressPlace(playerIndex)
  # At the placement cap the seq folds its oldest instead of growing, so the
  # proof of placement is the NEWEST barrier, not the length.
  doAssert sim.placedBarriers.len > 0
  result = sim.placedBarriers[^1]
  doAssert result.x == cx and result.y == cy
  doAssert result.facingBrads == aimBrads

suite "cardboard barriers":
  test "no barriers by default, and the config echo stays clean":
    let plain = initCtfForTest(defaultGameConfig())
    check plain.barrierSpawns.len == 0
    check plain.placedBarriers.len == 0
    # The default replay config carries NO barrier key: an unconditional echo
    # would change every existing fixture's bytes (the no-GV-bump rule).
    let echoed = parseJson(defaultGameConfig().configJson())
    check not echoed.hasKey("barrierPickups")
    var bad = defaultGameConfig()
    expect CtfError:
      bad.update("""{"barrierPickups": """ &
        $(MaxBarrierPickupsPerTeam + 1) & "}")

  test "barrierPickups:1 stages one walkable pickup per team":
    let sim = barrierGame()
    check sim.barrierSpawns.len == 2
    for spawn in sim.barrierSpawns:
      check spawn.present
      check sim.canOccupy(spawn.x, spawn.y)
    let echoed = parseJson(sim.config.configJson())
    check echoed["barrierPickups"].getInt == 1

  test "pickup by touch, one at a time, respawning on a timer":
    var sim = barrierGame()
    sim.standOn(0, 0)
    sim.tryPickupBarriers(0)
    check sim.players[0].hasBarrier
    check not sim.barrierSpawns[0].present
    # Carrying one blocks taking another.
    sim.standOn(0, 1)
    sim.tryPickupBarriers(0)
    check sim.barrierSpawns[1].present
    # The taken spawn refills after BarrierRespawnTicks.
    let none = sim.none()
    for _ in 0 ..< BarrierRespawnTicks + 1:
      sim.step(none, none)
    check sim.barrierSpawns[0].present

  test "grenade and barrier are mutually exclusive carries":
    var sim = barrierGame()
    # A grenade carrier walks over the barrier pickup untouched.
    sim.players[0].hasGrenade = true
    sim.standOn(0, 0)
    sim.tryPickupBarriers(0)
    check not sim.players[0].hasBarrier
    check sim.barrierSpawns[0].present
    # A barrier carrier walks over a grenade pickup untouched.
    sim.players[0].hasGrenade = false
    sim.players[0].hasBarrier = true
    sim.players[0].x = sim.grenadeSpawns[0].x - CollisionW div 2
    sim.players[0].y = sim.grenadeSpawns[0].y - CollisionH div 2
    sim.tryPickupGrenades(0)
    check not sim.players[0].hasGrenade
    check sim.grenadeSpawns[0].present

  test "pressing C unfolds a half-hex, flat side across the aim":
    var sim = barrierGame()
    let
      kit = sim.medKitSpawns[0]        # guaranteed open floor
      b = sim.plantFacing(0, kit.x, kit.y, 0)   # aim east
    check not sim.players[0].hasBarrier
    check b.hp == BarrierHp
    check b.facingBrads == 0
    # Flat middle side: a vertical band one apothem (~21px) east of center.
    check sim.barrierIndexAt(kit.x + 21, kit.y) == 0
    # The center and the ground behind stay open cardboard-free.
    check sim.barrierIndexAt(kit.x, kit.y) == -1
    check sim.barrierIndexAt(kit.x - 21, kit.y) == -1
    # Wing tips reach straight out to the placer's left and right.
    check sim.barrierIndexAt(kit.x, kit.y - BarrierRadius) == 0
    check sim.barrierIndexAt(kit.x, kit.y + BarrierRadius) == 0

  test "cardboard blocks paint but never sight":
    var sim = barrierGame()
    let kit = sim.medKitSpawns[0]
    # Placer stands on the kit spot aiming west, then steps aside: the flat
    # side stands between the shooter (west) and the target spot.
    discard sim.plantFacing(1, kit.x, kit.y, 128)
    sim.placeStill(1, kit.x + 24 - CollisionW div 2, kit.y - CollisionH div 2)
    let
      sx = kit.x - 40
      tx = kit.x + 24
    # Sight is untouched — the wall-only line test still passes...
    check sim.lineOfSightClear(sx, kit.y, tx, kit.y)
    # ...but every paint path is blocked.
    check not sim.paintPathClear(sx, kit.y, tx, kit.y)

  test "ten paintball hits shred a barrier, and shots stop at it":
    var sim = barrierGame()
    let kit = sim.medKitSpawns[0]
    discard sim.plantFacing(1, kit.x, kit.y, 128)
    # Target hides just east of its own cardboard; shooter lines up west.
    sim.placeStill(1, kit.x + 24 - CollisionW div 2, kit.y - CollisionH div 2)
    sim.placeStill(0, kit.x - 40 - CollisionW div 2, kit.y - CollisionH div 2)
    sim.players[0].aimBrads = 0
    for hit in 1 .. BarrierHp:
      sim.armToFire(0)
      sim.tryFire(0)
      if hit < BarrierHp:
        check sim.placedBarriers[0].hp == BarrierHp - hit
    # Ten hits: the cardboard is gone and the target never lost a point.
    check sim.placedBarriers.len == 0
    check sim.players[1].hp == sim.config.hitPoints
    # The eleventh shot sails through and connects.
    sim.armToFire(0)
    sim.tryFire(0)
    check sim.players[1].hp == sim.config.hitPoints - 1

  test "the spray cone is blocked by cardboard":
    var sim = barrierGame()
    let kit = sim.medKitSpawns[0]
    discard sim.plantFacing(1, kit.x, kit.y, 128)
    sim.placeStill(1, kit.x + 24 - CollisionW div 2, kit.y - CollisionH div 2)
    sim.placeStill(0, kit.x - 40 - CollisionW div 2, kit.y - CollisionH div 2)
    sim.players[0].aimBrads = 0
    sim.players[0].hasPlasmaArc = true
    sim.players[0].fireCooldown = 0
    sim.tryFireArc(0)
    let none = sim.none()
    for _ in 0 ..< PlasmaArcActiveTicks:
      sim.step(none, none)
    check sim.players[1].hp == sim.config.hitPoints

  test "driving into a barrier flattens it":
    var sim = barrierGame()
    let kit = sim.medKitSpawns[0]
    discard sim.plantFacing(0, kit.x, kit.y, 0)
    # Walk the OTHER player onto the flat side; the same-tick update crushes.
    sim.placeStill(1, kit.x + 21 - CollisionW div 2, kit.y - CollisionH div 2)
    let none = sim.none()
    sim.step(none, none)
    check sim.placedBarriers.len == 0

  test "the placer can stand inside their own half-hex safely":
    var sim = barrierGame()
    let kit = sim.medKitSpawns[0]
    discard sim.plantFacing(0, kit.x, kit.y, 0)
    let none = sim.none()
    sim.step(none, none)
    # Still standing: the apothem clears the placer's own footprint.
    check sim.placedBarriers.len == 1

  test "placing past the cap folds the oldest barrier":
    var sim = barrierGame()
    let kit = sim.medKitSpawns[0]
    var first: PlacedBarrier
    for i in 0 ..< MaxBarriersPlaced + 1:
      let b = sim.plantFacing(0, kit.x, kit.y, (i * 16) mod 256)
      if i == 0:
        first = b
    check sim.placedBarriers.len == MaxBarriersPlaced
    check sim.placedBarriers[0].facingBrads != first.facingBrads

  test "death loses the carried cardboard and grenades still throw":
    var sim = barrierGame()
    sim.players[0].hasBarrier = true
    sim.killPlayer(0, 1)
    check not sim.players[0].hasBarrier
    # The C button still charges and throws for a grenade carrier.
    sim.players[1].hasGrenade = true
    sim.chargeAndThrow(1, 6)
    check not sim.players[1].hasGrenade
    check sim.placedBarriers.len == 0

  test "barrier state stays out of the game hash":
    var sim = barrierGame()
    let hash = sim.gameHash()
    sim.players[0].hasBarrier = true
    sim.placedBarriers.add PlacedBarrier(
      x: 100, y: 100, hp: BarrierHp, team: Red,
      verts: [(90, 80), (110, 85), (110, 115), (90, 120)],
      minX: 87, minY: 77, maxX: 113, maxY: 123
    )
    check sim.gameHash() == hash

  test "a keyframe round-trips spawns, carries, and standing barriers":
    var sim = barrierGame()
    let kit = sim.medKitSpawns[0]
    discard sim.plantFacing(0, kit.x, kit.y, 32)
    sim.players[1].hasBarrier = true
    sim.standOn(0, 0)
    sim.tryPickupBarriers(0)   # spawn 0 taken, respawn armed
    let bytes = serializeReplaySim(sim)
    var restored = deserializeReplaySim(bytes, sim)
    check restored.placedBarriers == sim.placedBarriers
    check restored.barrierSpawns == sim.barrierSpawns
    check restored.players[0].hasBarrier
    check restored.players[1].hasBarrier

  test "both streams draw the pickup, the carry marker, and the half-hex":
    var sim = barrierGame()
    let kit = sim.medKitSpawns[0]
    discard sim.plantFacing(0, kit.x, kit.y, 0)
    sim.players[1].hasBarrier = true
    var gstate = initGlobalViewerState()
    let board = sim.buildGlobalMessages(gstate)
    var found: seq[string]
    for message in board:
      if message.kind == spkSprite:
        found.add(message.sprite.label)
    check LabelBarrier in found
    check LabelBarrierCarried in found
    check labelBarrierUp(kit.x, kit.y, 0, BarrierHp) in found
