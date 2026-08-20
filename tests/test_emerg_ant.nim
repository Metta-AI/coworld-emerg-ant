import
  helpers,
  std/[json, unittest],
  bitworld/spriteprotocol,
  ctf/[broadcast, global, sim]

proc antGame(goal = DefaultForageGoal): SimServer =
  var config = defaultGameConfig()
  config.gameMode = EmergAntMode
  config.forageGoal = goal
  result = initCtfForTest(config)
  discard result.addPlayer("red-ant")
  discard result.addPlayer("blue-ant")
  # Keep one worker alive behind each queen so focused foraging/combat tests do
  # not accidentally exercise the queen-only colony-collapse rule.
  discard result.addPlayer("red-worker")
  discard result.addPlayer("blue-worker")
  result.startGame()
  result.players[0].team = Red
  result.players[1].team = Blue

proc antColonyGame(goal = DefaultForageGoal): SimServer =
  ## Four connected copies per policy. Two start alive in this compact test,
  ## and two wait as brood. Alternating assignment mirrors production.
  var config = defaultGameConfig()
  config.gameMode = EmergAntMode
  config.forageGoal = goal
  config.startingAntsPerColony = 2
  config.slots.setLen(8)
  result = initCtfForTest(config)
  for i in 0 ..< 8:
    discard result.addPlayer("ant-" & $i)
  result.startGame()

proc returnFood(sim: var SimServer, playerIndex: int, foodTeam: Team) =
  let
    source = (x: sim.flags[foodTeam].x, y: sim.flags[foodTeam].y)
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
    config.update("""{"gameMode":"emerg-ant","forageGoal":7,"startingAntsPerColony":6}""")
    check config.isEmergAnt()
    check config.forageGoal == 7
    check config.startingAntsPerColony == 6
    let echoed = parseJson(config.configJson())
    check echoed["gameMode"].getStr() == EmergAntMode
    check echoed["forageGoal"].getInt() == 7
    check echoed["startingAntsPerColony"].getInt() == 6

  test "unknown modes and non-positive goals are rejected":
    var config = defaultGameConfig()
    expect CtfError:
      config.update("""{"gameMode":"termites"}""")
    expect CtfError:
      config.update("""{"forageGoal":0}""")
    expect CtfError:
      config.update("""{"startingAntsPerColony":1}""")

  test "Emerg-ant is always a two-policy 1v1 match":
    var config = defaultGameConfig()
    expect CtfError:
      config.update("""{"gameMode":"emerg-ant","teams":4}""")

suite "Emerg-ant colonies":
  test "the published roster starts eight ants and keeps eight brood per colony":
    var config = defaultGameConfig()
    config.gameMode = EmergAntMode
    config.forageGoal = 9
    config.startingAntsPerColony = 8
    config.slots.setLen(32)
    var sim = initCtfForTest(config)
    for i in 0 ..< 32:
      discard sim.addPlayer("ant-" & $i)
    sim.startGame()
    check sim.teamActiveAnts(Red) == 8
    check sim.teamActiveAnts(Blue) == 8
    for i, player in sim.players:
      if not player.alive:
        continue
      for j in i + 1 ..< sim.players.len:
        if sim.players[j].alive:
          check max(abs(player.x - sim.players[j].x),
                    abs(player.y - sim.players[j].y)) > PlayerSolidSpan
    check not sim.players[16].alive
    sim.returnFood(2, Blue)
    check sim.teamForageScore(Red) == 1
    check sim.teamActiveAnts(Red) == 9
    check sim.players[16].alive

  test "configured founders begin alive and the remainder wait as brood":
    var sim = antColonyGame()
    for team in [Red, Blue]:
      let queen = sim.queenIndex(team)
      check queen >= 0
      check sim.players[queen].alive
      check sim.players[queen].skin == CrownSkin
      check sim.teamActiveAnts(team) == 2
      let nest = sim.gameMap.flagHome(team)
      check sim.players[queen].x + CollisionW div 2 == nest.x
      check sim.players[queen].y + CollisionH div 2 == nest.y

  test "the queen stays at the nest while still able to defend by contact":
    var sim = antColonyGame()
    let
      queen = sim.queenIndex(Red)
      before = (sim.players[queen].x, sim.players[queen].y)
    var input = sim.none()
    input[queen].right = true
    input[queen].down = true
    sim.step(input, sim.none())
    check (sim.players[queen].x, sim.players[queen].y) == before

  test "each delivered food hatches exactly one connected policy copy":
    var sim = antColonyGame(goal = 9)
    let redWorker = 2
    check sim.players[redWorker].team == Red
    check sim.teamActiveAnts(Red) == 2
    sim.returnFood(redWorker, Blue)
    check sim.teamForageScore(Red) == 1
    check sim.teamActiveAnts(Red) == 3
    check sim.colonyFood[Red] == 0
    check sim.players[4].alive
    check not sim.players[6].alive

  test "killing a queen immediately collapses the colony":
    var sim = antColonyGame(goal = 9)
    let
      redQueen = sim.queenIndex(Red)
      blueQueen = sim.queenIndex(Blue)
    sim.killPlayer(redQueen, blueQueen)
    sim.checkWinCondition()
    check sim.phase == GameOver
    check sim.winner == Blue
    for player in sim.players:
      if player.team == Red:
        check not player.alive

  test "losing the last worker immediately collapses the colony":
    var sim = antColonyGame(goal = 9)
    let
      redQueen = sim.queenIndex(Red)
      blueWorker = 3
    for i in 0 ..< sim.players.len:
      if sim.players[i].team == Red and i != redQueen:
        sim.players[i].alive = false
        sim.players[i].lives = 0
    sim.colonyFood[Red] = 0
    sim.checkWinCondition()
    check sim.phase == GameOver
    check sim.winner == Blue
    check sim.players[blueWorker].alive
    check not sim.players[redQueen].alive

  test "stored food hatches a worker before a queen-only colony collapses":
    var sim = antColonyGame(goal = 9)
    let redQueen = sim.queenIndex(Red)
    for i in 0 ..< sim.players.len:
      if sim.players[i].team == Red and i != redQueen:
        sim.players[i].alive = false
        sim.players[i].lives = 0
    sim.colonyFood[Red] = BroodFoodCost
    sim.checkWinCondition()
    check sim.phase == Playing
    check sim.players[redQueen].alive
    check sim.teamHasLivingWorker(Red)
    check sim.colonyFood[Red] == 0

suite "Emerg-ant foraging":
  test "food touch radius covers the complete rendered patch":
    check FoodPickupRange >= FoodPatchSize div 2 + PlayerHalf

  test "returned food scores, replenishes, and reaches the goal":
    var sim = antGame(goal = 2)
    let firstPatch = (x: sim.flags[Blue].x, y: sim.flags[Blue].y)
    sim.returnFood(0, Blue)
    check sim.phase == Playing
    check sim.teamForageScore(Red) == 1
    check not sim.players[0].carryingFlag
    check sim.flags[Blue].carrier == -1
    check (sim.flags[Blue].x, sim.flags[Blue].y) != firstPatch
    check sim.canOccupy(sim.flags[Blue].x, sim.flags[Blue].y)
    for team in sim.teams():
      check not sim.captureZone(team).inCaptureZone(
        sim.flags[Blue].x, sim.flags[Blue].y)

    sim.returnFood(0, Blue)
    check sim.phase == GameOver
    check not sim.isDraw
    check sim.winner == Red
    check sim.teamForageScore(Red) == 2

  test "a food delivery produces a replay-safe food beat":
    var
      sim = antGame(goal = 9)
      tracker = initBroadcastTracker()
      events = newJArray()
    tracker.resync(sim)
    sim.returnFood(0, Blue)
    sim.stepEvents(tracker, events)
    check events.len == 1
    check events[0]["k"].getStr() == "capture"
    check events[0]["flag"].getStr() == "food"
    check events[0]["food"].getBool()

  test "simultaneous tied goal still produces one deterministic winner":
    var sim = antGame(goal = 1)
    let
      redHome = sim.gameMap.flagHome(Red)
      blueHome = sim.gameMap.flagHome(Blue)
      redFood = (x: sim.flags[Red].x, y: sim.flags[Red].y)
      blueFood = (x: sim.flags[Blue].x, y: sim.flags[Blue].y)
    sim.players[0].placeAtCenter(blueFood.x, blueFood.y)
    sim.players[1].placeAtCenter(redFood.x, redFood.y)
    sim.tryPickupFlags(0)
    sim.tryPickupFlags(1)
    sim.players[0].placeAtCenter(redHome.x, redHome.y)
    sim.players[1].placeAtCenter(blueHome.x, blueHome.y)
    sim.checkWinCondition()
    check sim.phase == GameOver
    check not sim.isDraw
    check sim.winner in [Red, Blue]
    check sim.teamForageScore(Red) == 1
    check sim.teamForageScore(Blue) == 1

  test "food slots are neutral and either colony can collect either one":
    var sim = antGame()
    let redFood = sim.flags[Red]
    sim.players[0].placeAtCenter(redFood.x, redFood.y)
    sim.tryPickupFlags(0)
    check sim.flags[Red].carrier == 0
    check sim.players[0].carryingFlag

  test "food starts reproducibly on open field away from every nest":
    var first = antGame()
    var second = antGame()
    var looseFood = 0
    for foodSlot in first.objectiveSlots():
      inc looseFood
      check first.flags[foodSlot].x == second.flags[foodSlot].x
      check first.flags[foodSlot].y == second.flags[foodSlot].y
      check first.canOccupy(first.flags[foodSlot].x, first.flags[foodSlot].y)
      for nest in first.teams():
        check not first.captureZone(nest).inCaptureZone(
          first.flags[foodSlot].x, first.flags[foodSlot].y)
    check looseFood == 4

  test "every living ant smells loose food outside its field of view":
    var sim = antGame()
    let center = sim.gameMap.center
    sim.players[0].placeAtCenter(center.x, center.y)
    sim.players[0].aimBrads = 0
    sim.flags[Red].carrier = -1
    sim.flags[Red].captured = false
    sim.flags[Red].x = center.x - sim.visionRange()
    sim.flags[Red].y = center.y
    sim.fovCaches[0].valid = false
    discard sim.refreshPlayerFov(0)
    check sim.flagVisibleTo(0, Red)

    sim.flags[Red].x = center.x + min(40, sim.visionRange() div 2)
    sim.fovCaches[0].valid = false
    discard sim.refreshPlayerFov(0)
    check sim.flagVisibleTo(0, Red)

    sim.players[0].alive = false
    check not sim.flagVisibleTo(0, Red)

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

  test "a perfectly tied clock uses the deterministic final tiebreak":
    var first = antColonyGame(goal = 9)
    var second = antColonyGame(goal = 9)
    for sim in [addr first, addr second]:
      sim[].config.maxTicks = 1
      sim[].gameStartTick = sim[].tickCount
      sim[].step(sim[].none(), sim[].none())
      check sim[].phase == GameOver
      check not sim[].isDraw
      check sim[].timeLimitReached
    check first.winner == second.winner

  test "even a fully disconnected finite round names a winner":
    var sim = antGame(goal = 9)
    sim.config.maxGames = 1
    sim.players.setLen(0)
    sim.step(sim.none(), sim.none())
    check sim.phase == GameOver
    check not sim.isDraw
    check sim.winner in [Red, Blue]

suite "Emerg-ant combat":
  test "weapons and pickups are absent and shooting APIs are inert":
    var sim = antGame()
    for spawn in sim.grenadeSpawns:
      check not spawn.present
    for spawn in sim.medKitSpawns:
      check not spawn.present
    for spawn in sim.shieldSpawns:
      check not spawn.present
    for spawn in sim.plasmaArcSpawns:
      check not spawn.present
    for spawn in sim.barrierSpawns:
      check not spawn.present
    check sim.airborneGrenades.len == 0
    check sim.placedBarriers.len == 0

    let hpBefore = sim.players[1].hp
    sim.armToFire(0)
    sim.tryFire(0)
    sim.tryFireArc(0)
    check sim.players[1].hp == hpBefore
    check sim.recentShots.len == 0

  test "mandibles damage only a physically touching enemy":
    var sim = antGame()
    let center = sim.gameMap.center
    sim.players[0].placeAtCenter(center.x, center.y)
    sim.players[1].placeAtCenter(center.x + ContactAttackRange + 1, center.y)
    var input = sim.none()
    input[0].attack = true
    let hpBefore = sim.players[1].hp
    sim.step(input, sim.none())
    check sim.players[1].hp == hpBefore

    sim.players[1].placeAtCenter(center.x + ContactAttackRange, center.y)
    sim.players[0].fireCooldown = 0
    sim.step(input, sim.none())
    check sim.players[1].hp == hpBefore - ContactAttackDamage
    check sim.players[0].fireCooldown > 0

  test "same-tick mandible strikes can kill both ants":
    var sim = antGame()
    let center = sim.gameMap.center
    for i in 0 .. 1:
      sim.players[i].placeAtCenter(center.x, center.y)
      sim.players[i].hp = ContactAttackDamage
      sim.players[i].fireCooldown = 0
    var input = sim.none()
    input[0].attack = true
    input[1].attack = true
    sim.step(input, sim.none())
    check not sim.players[0].alive
    check not sim.players[1].alive
    check sim.players[0].kills == 1
    check sim.players[1].kills == 1
    check sim.phase == GameOver
    check not sim.isDraw
    check sim.winner in [Red, Blue]

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
    check "food patch" in labels
    check "food carried" in labels
    check "weapon mandibles" in labels
    check "self queen red left" in labels or "self queen red right" in labels
    check "queen blue left" in labels or "queen blue right" in labels

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
