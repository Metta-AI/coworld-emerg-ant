import
  helpers,
  std/unittest,
  ctf/sim

suite "shot accuracy counters (analysis-only)":
  test "a shot that locks onto a live enemy counts as fired AND hit":
    var game = initCtfForTest(defaultGameConfig())
    let
      shooter = game.addPlayer("red0")
      target = game.addPlayer("blue0")
    game.startGame()
    game.players[shooter].team = Red
    game.players[target].team = Blue
    # Shooter aims due east at a target a short distance right.
    game.players[shooter].x = game.gameMap.center.x
    game.players[shooter].y = game.gameMap.center.y
    game.players[shooter].aimBrads = 0
    game.armToFire(shooter)
    game.players[target].x = game.gameMap.center.x + 40
    game.players[target].y = game.gameMap.center.y

    check game.players[shooter].shotsFired == 0
    check game.players[shooter].shotsHit == 0
    game.tryFire(shooter)
    check game.players[shooter].shotsFired == 1
    check game.players[shooter].shotsHit == 1
    # The victim never fired, so its own counters stay at zero.
    check game.players[target].shotsFired == 0

  test "a shot at empty space counts as fired but not hit":
    var game = initCtfForTest(defaultGameConfig())
    let shooter = game.addPlayer("red0")
    discard game.addPlayer("blue0")
    game.startGame()
    # Aim due east into open map with no enemy on the ray.
    game.players[shooter].x = game.gameMap.center.x
    game.players[shooter].y = game.gameMap.center.y
    game.players[shooter].aimBrads = 0
    game.armToFire(shooter)

    game.tryFire(shooter)
    check game.players[shooter].shotsFired == 1
    check game.players[shooter].shotsHit == 0

  test "the counters are analysis-only: they never enter the game hash":
    var a = initCtfForTest(defaultGameConfig())
    var b = initCtfForTest(defaultGameConfig())
    discard a.addPlayer("red0")
    discard b.addPlayer("red0")
    a.startGame()
    b.startGame()
    let hashBefore = a.gameHash()
    check hashBefore == b.gameHash()
    # Diverging only the accuracy counters must not diverge the hash — this is
    # what lets a re-simulating reporter read them off existing replays.
    a.players[0].shotsFired = 7
    a.players[0].shotsHit = 3
    check a.gameHash() == hashBefore
    check a.gameHash() == b.gameHash()
