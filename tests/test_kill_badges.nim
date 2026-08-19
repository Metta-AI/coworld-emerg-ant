import
  helpers,
  std/[json, unittest],
  bitworld/spriteprotocol,
  ctf/[broadcast, sim]

proc badgeGame(redCount, blueCount: int): SimServer =
  ## A started game with redCount Red players followed by blueCount Blue.
  result = initCtfForTest(defaultGameConfig())
  for i in 0 ..< redCount:
    discard result.addPlayer("red" & $i)
  for i in 0 ..< blueCount:
    discard result.addPlayer("blue" & $i)
  result.startGame()
  for i in 0 ..< redCount:
    result.players[i].team = Red
  for i in redCount ..< result.players.len:
    result.players[i].team = Blue
  # (Spawn protection used to be cleared here. ab27fc8 removed the mechanic
  # outright — exposure-sampled partial cover replaced it — so there is nothing
  # left to clear. This file still referenced the dead field until 2026-07-28:
  # it was never imported by tests/tests.nim, so nothing ever compiled it.)

proc landGrenade(sim: var SimServer) =
  ## Steps with no input until the airborne grenade explodes.
  let flight = sim.airborneGrenades[0].flightTicks
  let input = sim.none()
  for _ in 0 .. flight:
    sim.step(input, input)

# The left capture column is protected floor — never walled — so these tests
# anchor the actors there for guaranteed line of sight (like test_plasma_arc).
# A template, not a `let`: MapHeight is a process `var`, and in a combined
# test binary an earlier module may leave a different (e.g. giant generated)
# map installed at this module's import time — the anchor must read the
# height AFTER badgeGame installs the default arena. Same as test_plasma_arc.
const ClearX = 60
template ClearY(): int = MapHeight div 2

suite "kill badges":
  test "a grenade blast killing two enemies mints one double, no backstab":
    var game = badgeGame(1, 2)
    game.players[0].aimBrads = 0
    game.players[0].hasGrenade = true
    game.players[0].placeAtCenter(ClearX, ClearY)
    game.players[0].hp = GrenadeDamage + 1  # thrower survives the tap blast
    # A tap lands GrenadeMinRange east of the thrower; both victims inside.
    for i in 1 .. 2:
      game.players[i].placeAtCenter(ClearX + GrenadeMinRange, ClearY + (i - 1) * 8)
      game.players[i].hp = GrenadeDamage
    game.chargeAndThrow(0, 1)
    game.landGrenade()
    check not game.players[1].alive
    check not game.players[2].alive
    check game.players[0].kills == 2
    check game.players[0].multiKills2 == 1
    check game.players[0].multiKills3 == 0
    check game.players[0].teamKills == 0

  test "a grenade blast killing three (one a teammate) mints a triple and a backstab":
    var game = badgeGame(2, 2)
    game.players[0].aimBrads = 0
    game.players[0].hasGrenade = true
    game.players[0].placeAtCenter(ClearX, ClearY)
    game.players[0].hp = GrenadeDamage + 1
    for i in 1 .. 3:
      game.players[i].placeAtCenter(ClearX + GrenadeMinRange, ClearY + (i - 2) * 8)
      game.players[i].hp = GrenadeDamage
    game.chargeAndThrow(0, 1)
    game.landGrenade()
    check game.players[0].kills == 3
    check game.players[0].multiKills3 == 1
    check game.players[0].multiKills2 == 0   # the triple is not also a double
    check game.players[0].teamKills == 1     # red1 was in the blast

  test "one spray burst killing two enemies mints one double":
    var game = badgeGame(1, 2)
    game.players[0].hasPlasmaArc = true
    game.players[0].aimBrads = 0
    game.players[0].placeAtCenter(ClearX, ClearY)
    let
      ax = game.players[0].x + CollisionW div 2
      ay = game.players[0].y + CollisionH div 2
    # Forward 100px the cone's half-width is 25px: both victims inside it.
    game.players[1].placeAtCenter(ax + 100, ay - 8)
    game.players[2].placeAtCenter(ax + 120, ay + 8)
    game.tryFireArc(0)
    check not game.players[1].alive
    check not game.players[2].alive
    check game.players[0].kills == 2
    check game.players[0].multiKills2 == 1
    check game.players[0].multiKills3 == 0

  test "one spray burst killing three upgrades the double to a triple":
    var game = badgeGame(1, 3)
    game.players[0].hasPlasmaArc = true
    game.players[0].aimBrads = 0
    game.players[0].placeAtCenter(ClearX, ClearY)
    let
      ax = game.players[0].x + CollisionW div 2
      ay = game.players[0].y + CollisionH div 2
    game.players[1].placeAtCenter(ax + 100, ay - 8)
    game.players[2].placeAtCenter(ax + 110, ay)
    game.players[3].placeAtCenter(ax + 120, ay + 8)
    game.tryFireArc(0)
    check game.players[0].kills == 3
    check game.players[0].multiKills2 == 0
    check game.players[0].multiKills3 == 1

  test "the broadcast roster carries the badge counters":
    var game = badgeGame(1, 2)
    game.players[0].multiKills2 = 1
    game.players[0].multiKills3 = 2
    game.players[0].teamKills = 3
    let state = parseJson(game.buildStateJson(
      newJArray(), false, 1, 0, false, true, -1, -1
    ))
    let roster = state["roster"]
    check roster[0]["mk2"].getInt == 1
    check roster[0]["mk3"].getInt == 2
    check roster[0]["tk"].getInt == 3
    check roster[1]["mk2"].getInt == 0
