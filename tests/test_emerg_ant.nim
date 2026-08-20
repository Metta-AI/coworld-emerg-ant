import
  helpers,
  std/[json, unittest],
  bitworld/spriteprotocol,
  ctf/[global, sim]

proc antGame(goal = DefaultForageGoal): SimServer =
  var config = defaultGameConfig()
  config.gameMode = EmergAntMode
  config.forageGoal = goal
  result = initCtfForTest(config)
  discard result.addPlayer("red-ant")
  discard result.addPlayer("blue-ant")
  result.startGame()
  result.players[0].team = Red
  result.players[1].team = Blue

proc returnFood(sim: var SimServer, playerIndex: int, foodTeam: Team) =
  let
    source = sim.gameMap.flagHome(foodTeam)
    home = sim.gameMap.flagHome(sim.players[playerIndex].team)
  sim.players[playerIndex].placeAtCenter(source.x, source.y)
  sim.tryPickupFlags(playerIndex)
  doAssert sim.flags[foodTeam].carrier == playerIndex
  sim.players[playerIndex].placeAtCenter(home.x, home.y)
  sim.checkWinCondition()

suite "Emerg-ant config":
  test "mode is opt-in and replay-pins its forage goal":
    let plain = parseJson(defaultGameConfig().configJson())
    check not plain.hasKey("gameMode")
    check not plain.hasKey("forageGoal")
    var config = defaultGameConfig()
    config.update("""{"gameMode":"emerg-ant","forageGoal":7}""")
    check config.isEmergAnt()
    check config.forageGoal == 7
    let echoed = parseJson(config.configJson())
    check echoed["gameMode"].getStr() == EmergAntMode
    check echoed["forageGoal"].getInt() == 7

  test "unknown modes and non-positive goals are rejected":
    var config = defaultGameConfig()
    expect CtfError:
      config.update("""{"gameMode":"termites"}""")
    expect CtfError:
      config.update("""{"forageGoal":0}""")

suite "Emerg-ant foraging":
  test "returned food scores, replenishes, and reaches the goal":
    var sim = antGame(goal = 2)
    sim.returnFood(0, Blue)
    check sim.phase == Playing
    check sim.teamForageScore(Red) == 1
    check not sim.players[0].carryingFlag
    let blueHome = sim.gameMap.flagHome(Blue)
    check sim.flags[Blue].carrier == -1
    check sim.flags[Blue].x == blueHome.x
    check sim.flags[Blue].y == blueHome.y

    sim.returnFood(0, Blue)
    check sim.phase == GameOver
    check not sim.isDraw
    check sim.winner == Red
    check sim.teamForageScore(Red) == 2

  test "simultaneous tied goal returns draw without enum-order advantage":
    var sim = antGame(goal = 1)
    let
      redHome = sim.gameMap.flagHome(Red)
      blueHome = sim.gameMap.flagHome(Blue)
    sim.players[0].placeAtCenter(blueHome.x, blueHome.y)
    sim.players[1].placeAtCenter(redHome.x, redHome.y)
    sim.tryPickupFlags(0)
    sim.tryPickupFlags(1)
    sim.players[0].placeAtCenter(redHome.x, redHome.y)
    sim.players[1].placeAtCenter(blueHome.x, blueHome.y)
    sim.checkWinCondition()
    check sim.phase == GameOver
    check sim.isDraw
    check sim.teamForageScore(Red) == 1
    check sim.teamForageScore(Blue) == 1

  test "a unique score leader wins at the clock":
    var sim = antGame(goal = 5)
    sim.returnFood(0, Blue)
    sim.config.maxTicks = 1
    sim.gameStartTick = sim.tickCount
    sim.step(sim.none(), sim.none())
    check sim.phase == GameOver
    check not sim.isDraw
    check sim.winner == Red
    check sim.timeLimitReached

suite "Emerg-ant stigmergy":
  test "moving ants deposit public scout and food trails":
    var sim = antGame()
    sim.tickCount = PheromoneStepTicks
    sim.players[0].velX = sim.config.motionScale
    sim.players[1].velY = sim.config.motionScale
    sim.players[1].carryingFlag = true
    sim.updatePheromones()
    check sim.pheromones.len == 2
    check sim.pheromones[0].team == Red
    check not sim.pheromones[0].food
    check sim.pheromones[1].team == Blue
    check sim.pheromones[1].food

    var state: PlayerViewerState
    let messages = sim.buildPlayerMessages(0, state)
    var labels: seq[string] = @[]
    for message in messages:
      if message.kind == spkSprite:
        labels.add(message.sprite.label)
    check "pheromone red scout" in labels
    check "pheromone blue food" in labels
    check "food red cache" in labels
    check "food blue cache" in labels

  test "opposing deposits at one point cancel simultaneously":
    var sim = antGame()
    let p = sim.gameMap.center
    for i in 0 .. 1:
      sim.players[i].placeAtCenter(p.x, p.y)
      sim.players[i].velX = sim.config.motionScale
    sim.tickCount = PheromoneStepTicks
    sim.updatePheromones()
    check sim.pheromones.len == 0

  test "a fresh opposing trail erases old pheromone and marks expire":
    var sim = antGame()
    let p = sim.gameMap.center
    sim.pheromones = @[
      PheromoneMark(x: p.x, y: p.y, team: Red, tick: 1, food: false)
    ]
    sim.players[0].velX = 0
    sim.players[0].velY = 0
    sim.players[1].placeAtCenter(p.x, p.y)
    sim.players[1].velX = sim.config.motionScale
    sim.tickCount = PheromoneStepTicks
    sim.updatePheromones()
    check sim.pheromones.len == 1
    check sim.pheromones[0].team == Blue

    sim.players[1].velX = 0
    sim.tickCount += PheromoneLifetimeTicks
    sim.updatePheromones()
    check sim.pheromones.len == 0

  test "pheromone enters the hash only in ant mode":
    var ant = antGame()
    let before = ant.gameHash()
    ant.pheromones.add PheromoneMark(x: 10, y: 20, team: Red, tick: 1)
    check ant.gameHash() != before

    var ctf = twoTeamGame()
    let plain = ctf.gameHash()
    ctf.pheromones.add PheromoneMark(x: 10, y: 20, team: Red, tick: 1)
    check ctf.gameHash() == plain
