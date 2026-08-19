import
  helpers,
  std/unittest,
  bitworld/spriteprotocol,
  ctf/sim

proc fourTeamConfig(layout: string): GameConfig =
  result = defaultGameConfig()
  result.teams = 4
  result.mapPath = "gen"
  result.mapGen.layout = layout
  result.mapSeed = 42

proc fourTeamGame(layout = "corners"): SimServer =
  ## A started 4-team game with one player per team (slots deal mod 4).
  result = initCtfForTest(fourTeamConfig(layout))
  for i in 0 ..< 4:
    discard result.addPlayer("p" & $i)
  result.startGame()

proc centerOn(sim: var SimServer, playerIndex, x, y: int) =
  ## Places one player so its collision CENTER sits at (x, y).
  sim.players[playerIndex].x = x - CollisionW div 2
  sim.players[playerIndex].y = y - CollisionH div 2

suite "four team ctf":
  test "seats deal round all four teams":
    let sim = fourTeamGame()
    check sim.gameMap.teamCount() == 4
    check sim.teams() == Red .. Yellow
    for i in 0 ..< 4:
      check sim.players[i].team == Team(i)

  test "all four flags start home on their own pedestals":
    let sim = fourTeamGame()
    for team in sim.teams():
      let home = sim.gameMap.flagHome(team)
      check sim.flags[team].carrier == -1
      check sim.flags[team].x == home.x
      check sim.flags[team].y == home.y

  test "any enemy flag can be stolen, never your own":
    var sim = fourTeamGame()
    let greenHome = sim.gameMap.flagHome(Green)
    # Red walks onto the GREEN pedestal and takes the heart.
    sim.centerOn(0, greenHome.x, greenHome.y)
    sim.tryPickupFlags(0)
    check sim.flags[Green].carrier == 0
    check sim.players[0].carryingFlag
    # Green itself cannot interact with its own (returned) flag.
    sim.resetFlag(Green)
    sim.players[0].carryingFlag = false
    sim.centerOn(2, greenHome.x, greenHome.y)
    sim.tryPickupFlags(2)
    check sim.flags[Green].carrier == -1
    check not sim.players[2].carryingFlag

  proc captureHeart(sim: var SimServer, flagTeam: Team) =
    ## Has red player 0 steal one team's heart and run it home.
    let home = sim.gameMap.flagHome(flagTeam)
    sim.centerOn(0, home.x, home.y)
    sim.tryPickupFlags(0)
    check sim.flags[flagTeam].carrier == 0
    let anchor = sim.gameMap.teamAnchor(Red)
    sim.centerOn(0, anchor.x, anchor.y)
    sim.checkWinCondition()

  test "a capture eliminates the captured team and the game goes on":
    var sim = fourTeamGame()
    sim.captureHeart(Green)
    # Three teams still stand: no winner yet.
    check sim.phase == Playing
    # Green is out: its player is dead with no lives, its heart out of play.
    check not sim.players[2].alive
    check sim.players[2].lives == 0
    check sim.players[2].respawnTimer == 0
    check sim.flags[Green].captured
    check sim.flags[Green].carrier == -1
    # The captor's hands are free to steal the next heart.
    check not sim.players[0].carryingFlag

  test "elimination deaths never count in the stats (GV35)":
    var sim = fourTeamGame()
    sim.captureHeart(Green)
    # Green's player folded with its team but was never killed: the deaths
    # stat (the endscreen D column) stays at zero, and the captor is not
    # credited with a kill.
    check not sim.players[2].alive
    check sim.players[2].deaths == 0
    check sim.players[0].kills == 0
    # A combat kill still counts as ever.
    sim.killPlayer(1, 0)
    check sim.players[1].deaths == 1

  test "a captured heart cannot be stolen again":
    var sim = fourTeamGame()
    sim.captureHeart(Green)
    # Blue walks onto the captured heart's resting spot: no steal.
    sim.centerOn(1, sim.flags[Green].x, sim.flags[Green].y)
    sim.tryPickupFlags(1)
    check sim.flags[Green].carrier == -1
    check not sim.players[1].carryingFlag

  test "eliminating a carrier's team returns the heart it was carrying":
    var sim = fourTeamGame()
    # Green steals the YELLOW heart, then Red captures the GREEN heart.
    let yellowHome = sim.gameMap.flagHome(Yellow)
    sim.centerOn(2, yellowHome.x, yellowHome.y)
    sim.tryPickupFlags(2)
    check sim.flags[Yellow].carrier == 2
    sim.captureHeart(Green)
    # Green's elimination sends the yellow heart home, still in play.
    check sim.flags[Yellow].carrier == -1
    check not sim.flags[Yellow].captured
    check sim.flags[Yellow].x == yellowHome.x
    check sim.flags[Yellow].y == yellowHome.y

  test "wiping a team retires its heart and the game goes on":
    var sim = fourTeamGame()
    # Green dies out with its heart still home: the heart leaves play.
    sim.players[2].alive = false
    sim.players[2].lives = 0
    sim.checkWinCondition()
    check sim.phase == Playing
    check sim.flags[Green].captured
    check sim.flags[Green].carrier == -1
    # A retired heart cannot be stolen off its resting spot.
    sim.centerOn(1, sim.flags[Green].x, sim.flags[Green].y)
    sim.tryPickupFlags(1)
    check sim.flags[Green].carrier == -1
    check not sim.players[1].carryingFlag

  test "wiping a team drops its heart off an enemy carrier's back":
    var sim = fourTeamGame()
    # Red steals the GREEN heart and runs with it...
    let greenHome = sim.gameMap.flagHome(Green)
    sim.centerOn(0, greenHome.x, greenHome.y)
    sim.tryPickupFlags(0)
    check sim.flags[Green].carrier == 0
    check sim.players[0].carryingFlag
    # ...then Green is wiped from the field: the heart retires straight off
    # the carrier's back and the ex-carrier's hands are free again.
    sim.players[2].alive = false
    sim.players[2].lives = 0
    sim.checkWinCondition()
    check sim.phase == Playing
    check sim.flags[Green].captured
    check sim.flags[Green].carrier == -1
    check not sim.players[0].carryingFlag

  test "capturing all three rival hearts pays the winner +3 and each loser -1":
    var sim = fourTeamGame()
    sim.captureHeart(Green)
    check sim.phase == Playing
    sim.captureHeart(Yellow)
    check sim.phase == Playing
    # The third capture leaves red the only team standing.
    sim.captureHeart(Blue)
    check sim.phase == GameOver
    check sim.winner == Red
    check not sim.isDraw
    check sim.players[0].reward == 3
    check sim.players[0].captures == 3
    for i in 1 ..< 4:
      check sim.players[i].reward == -1

  test "the game continues at two teams and ends on the last survivor":
    var sim = fourTeamGame()
    # Wipe Green and Yellow: two teams still stand, the game goes on.
    for i in [2, 3]:
      sim.players[i].alive = false
      sim.players[i].lives = 0
    sim.checkWinCondition()
    check sim.phase == Playing
    # Wipe Blue too: Red is the last team standing and wins +3.
    sim.players[1].alive = false
    sim.players[1].lives = 0
    sim.checkWinCondition()
    check sim.phase == GameOver
    check sim.winner == Red
    check not sim.isDraw
    check sim.players[0].reward == 3
    check sim.players[1].reward == -1

  test "config round-trips teams and layout through replay JSON":
    let sim = fourTeamGame()
    var config = defaultGameConfig()
    config.update(sim.config.configJson())
    check config.teams == 4
    check config.mapSpec.len > 0
    let rebuilt = resolveCtfMapMetadata(config)
    check rebuilt.layout == layoutCorners
    check rebuilt.teamCount() == 4
    check rebuilt == sim.gameMap

  test "plus layout anchors the four teams on the four arms":
    let sim = fourTeamGame("plus")
    let gameMap = sim.gameMap
    check gameMap.layout == layoutPlus
    let
      red = gameMap.teamAnchor(Red)
      blue = gameMap.teamAnchor(Blue)
      green = gameMap.teamAnchor(Green)
      yellow = gameMap.teamAnchor(Yellow)
    check red.x < gameMap.center.x
    check blue.x > gameMap.center.x
    check green.y < gameMap.center.y
    check yellow.y > gameMap.center.y
    # Each opposing pair straddles the board's TRUE symmetry axis at
    # (side-1)/2 — a half pixel off the integer center on an even side, so
    # the pair sums to side-1 rather than both sitting on center exactly.
    # Pinning them to center would put the anchors off the rot90 orbit.
    check red.y + blue.y == gameMap.height - 1
    check green.x + yellow.x == gameMap.width - 1
    # North team's capture zone is the arm mouth: bounded on y by the
    # anchor threshold and on x by the arm span (the corners are open
    # field, not endzone).
    let
      zone = gameMap.captureZone(Green)
      band = gameMap.plusArmBand()
    check zone.yHi < gameMap.height - 1
    check zone.xLo == band.lo
    check zone.xHi == band.hi
    # The arm mouth is its own quarter turn: the north zone's x-span is the
    # west zone's y-span rotated, exactly.
    let west = gameMap.captureZone(Red)
    check west.yLo == zone.xLo
    check west.yHi == zone.xHi
    check gameMap.width - 1 - west.yHi == zone.xLo

  test "corner endzones are diagonal":
    let sim = fourTeamGame()
    let zone = sim.gameMap.captureZone(Red)
    check zone.diag
    # The map corner itself is deep inside; the anchor is inside; a point
    # past the 45-degree threshold on one axis alone is not.
    check zone.inCaptureZone(ArenaBorder, ArenaBorder)
    let anchor = sim.gameMap.teamAnchor(Red)
    check zone.inCaptureZone(anchor.x, anchor.y)
    check not zone.inCaptureZone(zone.diagLimit - 5, zone.diagLimit - 5)

  test "a stepped 4-team episode is deterministic and respawns in-zone":
    proc runGame(): SimServer =
      result = initCtfForTest(fourTeamConfig("corners"))
      for i in 0 ..< 8:
        discard result.addPlayer("p" & $i)
      result.startGame()
      # Kill one player so the respawn path (diagonal-zone sampling) runs.
      result.killPlayer(5, 0)
      let none = newSeq[InputState](0)
      for tick in 0 ..< 400:
        result.step(none, none)
    var a = runGame()
    let b = runGame()
    check a.gameHash() == b.gameHash()
    check a.tickCount == b.tickCount
    # The killed player respawned somewhere inside its OWN diagonal zone.
    check a.players[5].alive
    let
      zone = a.gameMap.captureZone(a.players[5].team)
      cx = a.players[5].x + CollisionW div 2
      cy = a.players[5].y + CollisionH div 2
    check zone.inCaptureZone(cx, cy)

  test "bad 4-team configs fail loudly":
    var config = defaultGameConfig()
    expect CtfError:
      config.update("""{"teams": 3}""")
    expect CtfError:
      config.update("""{"teams": 4, "mapPath": "arena"}""")
    expect CtfError:
      config.update("""{"teams": 4, "mapPath": "pool"}""")
    expect CtfError:
      config.update("""{"teams": 2, "mapPath": "gen", "mapLayout": "corners"}""")
    expect CtfError:
      config.update(
        """{"teams": 4, "mapPath": "gen", "mapSymmetry": "mirror"}""")

  test "classic 2-team configs reject green and yellow slots":
    var config = defaultGameConfig()
    config.slots = @[PlayerSlotConfig(team: Green, hasTeam: true)]
    expect CtfError:
      config.update("""{"teams": 2}""")

suite "pot scoring":
  ## Every team antes one point; the winning team takes the whole pot and the
  ## losing teams split the forfeit. 2 teams: +2/-2. 4 teams: +4/-1/-1/-1.

  proc twoTeamPotGame(): SimServer =
    var config = defaultGameConfig()
    config.scoring = PotScoring
    result = initCtfForTest(config)
    for i in 0 ..< 2:
      discard result.addPlayer("p" & $i)
    result.startGame()

  proc fourTeamPotGame(): SimServer =
    var config = fourTeamConfig("corners")
    config.scoring = PotScoring
    result = initCtfForTest(config)
    for i in 0 ..< 4:
      discard result.addPlayer("p" & $i)
    result.startGame()

  test "classic scoring is the default and is untouched":
    check defaultGameConfig().scoring == ClassicScoring
    var sim = fourTeamGame()
    sim.players[1].alive = false
    sim.players[1].lives = 0
    for i in [2, 3]:
      sim.players[i].alive = false
      sim.players[i].lives = 0
    sim.checkWinCondition()
    check sim.winner == Red
    check sim.players[0].reward == 3
    for i in 1 ..< 4:
      check sim.players[i].reward == -1

  test "two teams pay the winner +2 and the loser -2":
    var sim = twoTeamPotGame()
    sim.players[1].alive = false
    sim.players[1].lives = 0
    sim.checkWinCondition()
    check sim.phase == GameOver
    check sim.winner == Red
    check sim.players[0].reward == 2
    check sim.players[1].reward == -2

  test "four teams pay the winner +4 and each loser -1":
    var sim = fourTeamPotGame()
    for i in 1 ..< 4:
      sim.players[i].alive = false
      sim.players[i].lives = 0
    sim.checkWinCondition()
    check sim.phase == GameOver
    check sim.winner == Red
    check sim.players[0].reward == 4
    for i in 1 ..< 4:
      check sim.players[i].reward == -1

  test "a time-limit draw still costs every player one point":
    var sim = fourTeamPotGame()
    sim.finishGame(Red, isDraw = true, timeLimitReached = true)
    check sim.isDraw
    for i in 0 ..< 4:
      check sim.players[i].reward == TimeoutReward

  test "scoring round-trips through replay JSON and rejects unknown rules":
    let sim = fourTeamPotGame()
    var config = defaultGameConfig()
    config.update(sim.config.configJson())
    check config.scoring == PotScoring
    var bad = defaultGameConfig()
    expect CtfError:
      bad.update("""{"scoring": "winner-take-all"}""")

  test "4ffa8 shape: 32 seats deal 8 per team on a locked giant board":
    ## The paintbot 4ffa8 variant: MaxPlayers seats, teams 4, mapSize giant.
    var config = fourTeamConfig("")   # layout drawn from the map seed
    config.mapGen.size = "giant"
    var sim = initCtfForTest(config)
    for i in 0 ..< MaxPlayers:
      discard sim.addPlayer("p" & $i)
    sim.startGame()
    check sim.gameMap.teamCount() == 4
    check sim.gameMap.width == 2496   # 960 * 2.6: the giant lock took
    var counts: array[Team, int]
    for i in 0 ..< MaxPlayers:
      inc counts[sim.players[i].team]
    for team in sim.teams():
      check counts[team] == 8
    # No two players share a spawn pixel.
    for i in 0 ..< MaxPlayers:
      for j in i + 1 ..< MaxPlayers:
        check sim.players[i].x != sim.players[j].x or
          sim.players[i].y != sim.players[j].y
