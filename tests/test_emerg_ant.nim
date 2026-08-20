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

proc harvestAndReturn(sim: var SimServer, playerIndex: int, patch: Team) =
  let
    source = sim.flags[patch]
    home = sim.gameMap.flagHome(sim.players[playerIndex].team)
  sim.players[playerIndex].placeAtCenter(source.x, source.y)
  sim.tryPickupFlags(playerIndex)
  doAssert sim.flags[patch].carrier == playerIndex
  sim.players[playerIndex].placeAtCenter(home.x, home.y)
  sim.checkWinCondition()

suite "Emerg-ant v0.4 config":
  test "mode is opt-in and replay-pins every ecology rule":
    let plain = parseJson(defaultGameConfig().configJson())
    check not plain.hasKey("gameMode")
    check not plain.hasKey("foodRespawnTicks")
    var config = defaultGameConfig()
    config.update("""{
      "gameMode":"emerg-ant",
      "forageGoal":7,
      "foodRespawnTicks":99,
      "pheromoneWashTick":321,
      "antSenseRadius":123,
      "biteDamage":2,
      "biteCooldownTicks":11
    }""")
    check config.isEmergAnt()
    check config.forageGoal == 7
    check config.foodRespawnTicks == 99
    check config.pheromoneWashTick == 321
    check config.antSenseRadius == 123
    check config.biteDamage == 2
    check config.biteCooldownTicks == 11
    let echoed = parseJson(config.configJson())
    check echoed["gameMode"].getStr() == EmergAntMode
    check echoed["forageGoal"].getInt() == 7
    check echoed["foodRespawnTicks"].getInt() == 99
    check echoed["pheromoneWashTick"].getInt() == 321
    check echoed["antSenseRadius"].getInt() == 123
    check echoed["biteDamage"].getInt() == 2
    check echoed["biteCooldownTicks"].getInt() == 11

  test "invalid ecology values and four-team colonies are rejected":
    for bad in [
      """{"gameMode":"termites"}""",
      """{"forageGoal":0}""",
      """{"foodRespawnTicks":0}""",
      """{"pheromoneWashTick":-1}""",
      """{"antSenseRadius":0}""",
      """{"biteDamage":0}""",
      """{"biteCooldownTicks":0}""",
      """{"gameMode":"emerg-ant","teams":4}"""
    ]:
      var config = defaultGameConfig()
      expect CtfError:
        config.update(bad)

suite "Emerg-ant neutral foraging":
  test "all 16 wake points are distinct and inside the colony nest":
    var config = defaultGameConfig()
    config.gameMode = EmergAntMode
    var sim = initCtfForTest(config)
    var seen: seq[tuple[x, y: int]]
    for team in [Red, Blue]:
      let zone = sim.captureZone(team)
      for order in 0 ..< 16:
        let spawn = sim.spawnPosition(team, order)
        check zone.inCaptureZone(
          spawn.x + CollisionW div 2, spawn.y + CollisionH div 2)
        check spawn notin seen
        seen.add(spawn)

  test "CTF keeps the inherited wide spawn fan":
    var sim = initCtfForTest(defaultGameConfig())
    let
      inner = sim.spawnPosition(Red, 0)
      outer = sim.spawnPosition(Red, 15)
    check abs(outer.y - inner.y) > 100

  test "fruit sites cover the arena and begin as a symmetric pair":
    var sim = antGame()
    let sites = sim.foodSpawnSites()
    check sites.len == FoodSiteCount
    for i, site in sites:
      check sim.canOccupy(site.x, site.y)
      check site notin sites[0 ..< i]
    check sim.flags[Red].foodSite == 0
    check sim.flags[Blue].foodSite == FoodSitePairOffset
    check (sim.flags[Red].x, sim.flags[Red].y) == sites[0]
    check (sim.flags[Blue].x, sim.flags[Blue].y) ==
      sites[FoodSitePairOffset]

    let patch = sim.flags[Red]
    sim.players[1].placeAtCenter(patch.x, patch.y)
    sim.tryPickupFlags(1)
    check sim.flags[Red].carrier == 1
    check sim.players[1].carryingFlag

  test "a delivery scores, empties the patch, and regrows on its timer":
    var sim = antGame(goal = 2)
    sim.config.foodRespawnTicks = 5
    sim.harvestAndReturn(0, Red)
    check sim.phase == Playing
    check sim.teamForageScore(Red) == 1
    check not sim.players[0].carryingFlag
    check sim.flags[Red].captured
    check sim.flags[Red].carrier == -1
    check sim.flags[Red].respawnAt == sim.tickCount + 5

    sim.tickCount = sim.flags[Red].respawnAt - 1
    sim.updateFoodPatches()
    check sim.flags[Red].captured
    inc sim.tickCount
    sim.updateFoodPatches()
    check not sim.flags[Red].captured
    check sim.flags[Red].respawnAt == 0
    check sim.flags[Red].foodSite == 1
    check (sim.flags[Red].x, sim.flags[Red].y) == sim.foodSpawnSites()[1]

  test "simultaneous tied goal deliveries draw without processing advantage":
    var sim = antGame(goal = 1)
    let
      redHome = sim.gameMap.flagHome(Red)
      blueHome = sim.gameMap.flagHome(Blue)
    sim.players[0].placeAtCenter(sim.flags[Red].x, sim.flags[Red].y)
    sim.players[1].placeAtCenter(sim.flags[Blue].x, sim.flags[Blue].y)
    sim.tryPickupFlags(0)
    sim.tryPickupFlags(1)
    sim.players[0].placeAtCenter(redHome.x, redHome.y)
    sim.players[1].placeAtCenter(blueHome.x, blueHome.y)
    sim.checkWinCondition()
    check sim.phase == GameOver
    check sim.isDraw
    check sim.teamForageScore(Red) == 1
    check sim.teamForageScore(Blue) == 1

  test "a unique forage leader wins at the clock":
    var sim = antGame(goal = 5)
    sim.harvestAndReturn(0, Red)
    sim.config.maxTicks = 1
    sim.gameStartTick = sim.tickCount
    sim.step(sim.none(), sim.none())
    check sim.phase == GameOver
    check not sim.isDraw
    check sim.winner == Red
    check sim.timeLimitReached

suite "Emerg-ant explicit local stigmergy":
  test "player protocol advertises ant actions and hides CTF pickups":
    var sim = antGame()
    var state: PlayerViewerState
    let messages = sim.buildPlayerMessages(0, state)
    var labels: seq[string] = @[]
    for message in messages:
      if message.kind == spkSprite:
        labels.add(message.sprite.label)
    check "neutral food patch" in labels
    check "neutral food carried" in labels
    check "bite ready" in labels
    check "bite cooldown" in labels
    check "med kit" notin labels
    check "grenade" notin labels

  test "B and C explicitly deposit home and food channels":
    var sim = antGame()
    sim.tickCount = PheromoneStepTicks
    var inputs = sim.none()
    inputs[0].b = true
    inputs[1].c = true
    sim.updatePheromones(inputs)
    check sim.pheromones.len == 2
    check sim.pheromones[0].team == Red
    check not sim.pheromones[0].food
    check sim.pheromones[1].team == Blue
    check sim.pheromones[1].food

  test "no pheromone input means no automatic trail":
    var sim = antGame()
    sim.tickCount = PheromoneStepTicks
    sim.players[0].velX = sim.config.motionScale
    sim.updatePheromones(sim.none())
    check sim.pheromones.len == 0

  test "opposing deposits at one point cancel simultaneously":
    var sim = antGame()
    let p = sim.gameMap.center
    for i in 0 .. 1:
      sim.players[i].placeAtCenter(p.x, p.y)
    var inputs = sim.none()
    inputs[0].b = true
    inputs[1].b = true
    sim.tickCount = PheromoneStepTicks
    sim.updatePheromones(inputs)
    check sim.pheromones.len == 0

  test "fresh opposing trail erases old marks and marks expire":
    var sim = antGame()
    let p = sim.gameMap.center
    sim.pheromones = @[
      PheromoneMark(x: p.x, y: p.y, team: Red, tick: 1, food: false)
    ]
    sim.players[1].placeAtCenter(p.x, p.y)
    var inputs = sim.none()
    inputs[1].c = true
    sim.tickCount = PheromoneStepTicks
    sim.updatePheromones(inputs)
    check sim.pheromones.len == 1
    check sim.pheromones[0].team == Blue
    check sim.pheromones[0].food

    sim.tickCount += PheromoneLifetimeTicks
    sim.updatePheromones(sim.none())
    check sim.pheromones.len == 0

  test "the disruption wash clears the field exactly once":
    var sim = antGame()
    sim.config.pheromoneWashTick = 100
    sim.pheromones.add PheromoneMark(x: 10, y: 20, team: Red, tick: 1)
    sim.tickCount = sim.gameStartTick + 100
    sim.updatePheromones(sim.none())
    check sim.pheromones.len == 0

    inc sim.tickCount
    var inputs = sim.none()
    inputs[0].b = true
    sim.tickCount += PheromoneStepTicks - (sim.tickCount mod PheromoneStepTicks)
    sim.updatePheromones(inputs)
    check sim.pheromones.len == 1

  test "food and pheromone observations are local":
    var sim = antGame()
    let patch = sim.flags[Red]
    sim.players[0].placeAtCenter(patch.x, patch.y)
    check sim.flagVisibleTo(0, Red)
    let redHome = sim.gameMap.flagHome(Red)
    sim.players[0].placeAtCenter(redHome.x, redHome.y)
    check not sim.flagVisibleTo(0, Red)

    let nearMark = PheromoneMark(
      x: sim.players[0].x, y: sim.players[0].y, team: Red, tick: sim.tickCount)
    let farMark = PheromoneMark(
      x: sim.gameMap.flagHome(Blue).x,
      y: sim.gameMap.flagHome(Blue).y,
      team: Blue, tick: sim.tickCount)
    check sim.pheromoneVisibleTo(0, nearMark)
    check not sim.pheromoneVisibleTo(0, farMark)

  test "food respawn and pheromone state enter only the ant-mode hash":
    var ant = antGame()
    let before = ant.gameHash()
    ant.flags[Red].respawnAt = 99
    ant.pheromones.add PheromoneMark(x: 10, y: 20, team: Red, tick: 1)
    check ant.gameHash() != before

    var ctf = twoTeamGame()
    let plain = ctf.gameHash()
    ctf.flags[Red].respawnAt = 99
    ctf.pheromones.add PheromoneMark(x: 10, y: 20, team: Red, tick: 1)
    check ctf.gameHash() == plain

suite "Emerg-ant contact combat":
  test "A damages only an enemy body in physical contact":
    var sim = antGame()
    let p = sim.gameMap.center
    sim.players[0].placeAtCenter(p.x, p.y)
    sim.players[1].placeAtCenter(p.x + AntBiteRange, p.y)
    let hpBefore = sim.players[1].hp
    sim.resolveContactAttacks(@[0])
    check sim.players[1].hp == hpBefore - sim.config.biteDamage
    check sim.players[0].fireCooldown == sim.config.biteCooldownTicks

    sim.players[1].placeAtCenter(p.x + AntBiteRange + 1, p.y)
    sim.players[0].fireCooldown = 0
    let safeHp = sim.players[1].hp
    sim.resolveContactAttacks(@[0])
    check sim.players[1].hp == safeHp
    check sim.players[0].fireCooldown == 0

  test "mutual contact kills resolve simultaneously":
    var sim = antGame()
    let p = sim.gameMap.center
    sim.players[0].placeAtCenter(p.x, p.y)
    sim.players[1].placeAtCenter(p.x + AntBiteRange, p.y)
    sim.players[0].hp = 1
    sim.players[1].hp = 1
    sim.resolveContactAttacks(@[0, 1])
    check not sim.players[0].alive
    check not sim.players[1].alive
    check sim.players[0].kills == 1
    check sim.players[1].kills == 1

  test "movement heading replaces turret controls in ant mode":
    var sim = antGame()
    sim.applyInput(0, InputState(down: true, b: true))
    check sim.players[0].aimBrads == bradsOfVector(0, 1)
