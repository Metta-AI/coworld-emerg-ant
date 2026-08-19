import
  helpers,
  std/[json, sets, unittest],
  bitworld/spriteprotocol,
  ctf/[broadcast, global, labels, sim]

# Per-team handicaps: a single 0..1 knob per team (stored as permille 0..1000)
# that interpolates a bundle of weakenings — 50% miss, 1 life, 1 hit point,
# half max speed at full. See docs/plans/2026-08-05-per-team-handicaps-design.md.

suite "handicap interpolation (pure math)":
  # A base config with room to interpolate: 3 lives, 3 hit points, 704 speed.
  proc baseConfig(): GameConfig =
    result = defaultGameConfig()
    result.lives = 3
    result.hitPoints = 3
    result.maxSpeed = 704

  test "permille 0 returns the exact base values (no handicap)":
    var cfg = baseConfig()
    cfg.handicaps[Red] = 0
    check cfg.hitPointsFor(Red) == 3
    check cfg.livesFor(Red) == 3
    check cfg.maxSpeedFor(Red) == 704
    check cfg.missPermilleFor(Red) == 0

  test "full handicap: 1 life, 1 hit point, half speed, 50% miss":
    var cfg = baseConfig()
    cfg.handicaps[Blue] = 1000
    check cfg.hitPointsFor(Blue) == 1
    check cfg.livesFor(Blue) == 1
    check cfg.maxSpeedFor(Blue) == 352
    check cfg.missPermilleFor(Blue) == 500

  test "half handicap interpolates linearly":
    var cfg = baseConfig()
    cfg.handicaps[Green] = 500
    check cfg.hitPointsFor(Green) == 2      # 3 - 2*500/1000
    check cfg.livesFor(Green) == 2
    check cfg.maxSpeedFor(Green) == 528     # 704 * 1500/2000
    check cfg.missPermilleFor(Green) == 250

  test "each team is independent":
    var cfg = baseConfig()
    cfg.handicaps[Red] = 1000
    cfg.handicaps[Blue] = 0
    check cfg.hitPointsFor(Red) == 1
    check cfg.hitPointsFor(Blue) == 3
    check cfg.maxSpeedFor(Red) == 352
    check cfg.maxSpeedFor(Blue) == 704

  test "interpolated hit points never fall below 1":
    var cfg = baseConfig()
    cfg.hitPoints = 1                        # already at the floor
    cfg.handicaps[Red] = 1000
    check cfg.hitPointsFor(Red) == 1

suite "handicap config parsing":
  test "a per-team float map parses into permille":
    var cfg = defaultGameConfig()
    cfg.update("""{"handicaps": {"red": 0.0, "blue": 0.6}}""")
    check cfg.handicaps[Red] == 0
    check cfg.handicaps[Blue] == 600
    check cfg.handicaps[Green] == 0

  test "an integer 1 parses as full handicap":
    var cfg = defaultGameConfig()
    cfg.update("""{"handicaps": {"green": 1}}""")
    check cfg.handicaps[Green] == 1000

  test "the default config has no handicaps":
    let cfg = defaultGameConfig()
    for team in Red .. Yellow:
      check cfg.handicaps[team] == 0

  test "a value above 1 is rejected":
    var cfg = defaultGameConfig()
    expect CtfError:
      cfg.update("""{"handicaps": {"red": 1.5}}""")

  test "a negative value is rejected":
    var cfg = defaultGameConfig()
    expect CtfError:
      cfg.update("""{"handicaps": {"red": -0.1}}""")

  test "an unknown team key is rejected":
    var cfg = defaultGameConfig()
    expect CtfError:
      cfg.update("""{"handicaps": {"purple": 0.5}}""")

  test "a non-object handicaps block is rejected":
    var cfg = defaultGameConfig()
    expect CtfError:
      cfg.update("""{"handicaps": 0.5}""")

suite "handicap config echo (configJson)":
  test "a default game echoes no handicaps key":
    let cfg = defaultGameConfig()
    let echoed = configJson(cfg).parseJson()
    check not echoed.hasKey("handicaps")

  test "only handicapped teams round-trip as floats":
    var cfg = defaultGameConfig()
    cfg.handicaps[Blue] = 600
    let echoed = configJson(cfg).parseJson()
    check echoed.hasKey("handicaps")
    check echoed["handicaps"].hasKey("blue")
    check not echoed["handicaps"].hasKey("red")
    check abs(echoed["handicaps"]["blue"].getFloat() - 0.6) < 1e-9
    # And it re-parses to the same permille.
    var reparsed = defaultGameConfig()
    reparsed.update(configJson(cfg))
    check reparsed.handicaps[Blue] == 600

suite "handicap applied in the sim":
  test "a handicapped team spawns with reduced hp and lives":
    var sim = initCtfForTest(defaultGameConfig())
    sim.config.lives = 3
    sim.config.hitPoints = 3
    discard sim.addPlayer("red0")
    discard sim.addPlayer("blue0")
    sim.startGame()
    sim.players[0].team = Red
    sim.players[1].team = Blue
    # Handicap Red fully, then re-run the spawn init via startGame.
    sim.config.handicaps[Red] = 1000
    sim.startGame()
    check sim.players[0].hp == 1
    check sim.players[0].lives == 1
    check sim.players[1].hp == 3
    check sim.players[1].lives == 3

  test "a handicap changes the game hash (it is hashed state)":
    var plain = initCtfForTest(defaultGameConfig())
    var hcap = initCtfForTest(defaultGameConfig())
    discard plain.addPlayer("red0"); discard plain.addPlayer("blue0")
    discard hcap.addPlayer("red0"); discard hcap.addPlayer("blue0")
    plain.startGame()
    hcap.config.handicaps[Red] = 1000
    hcap.startGame()
    check plain.gameHash() != hcap.gameHash()

  test "a med kit heals only to the team's handicapped max":
    var sim = initCtfForTest(defaultGameConfig())
    sim.config.hitPoints = 3
    discard sim.addPlayer("red0")
    discard sim.addPlayer("blue0")
    sim.startGame()
    sim.players[0].team = Red
    sim.players[1].team = Blue
    sim.config.handicaps[Red] = 500          # max hp 2
    # Hurt the handicapped player to 1 and stand it on a kit.
    sim.players[0].hp = 1
    sim.players[0].x = sim.medKitSpawns[0].x - CollisionW div 2
    sim.players[0].y = sim.medKitSpawns[0].y - CollisionH div 2
    sim.tryPickupMedKits(0)
    check sim.players[0].hp == 2              # healed to its OWN max, not 3

  test "a handicapped player's max speed is halved at full":
    var sim = initCtfForTest(defaultGameConfig())
    sim.config.maxSpeed = 704
    let red = sim.addPlayer("red")
    let blue = sim.addPlayer("blue")
    sim.players[red].team = Red
    sim.players[blue].team = Blue
    sim.config.handicaps[Red] = 1000         # half speed
    sim.blockAll()
    sim.openField(40, 40, 400, 400)
    sim.placeStill(red, 100, 100)
    sim.placeStill(blue, 100, 300)
    # Drive both east well past acceleration saturation; velocity clamps at the
    # per-team max.
    for _ in 0 .. 30:
      sim.applyInput(red, InputState(right: true))
      sim.applyInput(blue, InputState(right: true))
    check sim.players[blue].velX == 704
    check sim.players[red].velX == 352

  test "the broadcast chrome carries a handicapped team's deltas, omits others":
    var sim = initCtfForTest(defaultGameConfig())
    discard sim.addPlayer("red0")
    discard sim.addPlayer("blue0")
    sim.startGame()
    sim.players[0].team = Red
    sim.players[1].team = Blue
    sim.config.handicaps[Red] = 600            # 0.6
    let state = parseJson(sim.buildStateJson(
      newJArray(), false, 1, 1000, false, true, -1, -1
    ))
    # Blue is unhandicapped → no badge data at all.
    check not state["teams"]["blue"].hasKey("hcap")
    # Red carries the fraction plus the resolved deltas the tooltip shows.
    let hcap = state["teams"]["red"]["hcap"]
    check hcap["h"].getInt == 600
    check hcap["hp0"].getInt == sim.config.hitPoints
    check hcap["hp"].getInt == sim.config.hitPointsFor(Red)
    check hcap["lives0"].getInt == sim.config.lives
    check hcap["lives"].getInt == sim.config.livesFor(Red)
    check hcap["spd"].getInt ==
      sim.config.maxSpeedFor(Red) * 100 div sim.config.maxSpeed
    check hcap["miss"].getInt == sim.config.missPermilleFor(Red) div 10

  test "a fully handicapped shooter misses roughly half its point-blank shots":
    proc hitsWithHandicap(permille: int): int =
      var sim = initCtfForTest(defaultGameConfig())
      let shooter = sim.addPlayer("red0")
      let target = sim.addPlayer("blue0")
      sim.startGame()
      sim.players[shooter].team = Red
      sim.players[target].team = Blue
      sim.config.handicaps[Red] = permille
      # Point-blank due-east geometry: an unhandicapped shot always connects,
      # so any miss is the handicap, not aim jitter.
      sim.players[shooter].x = sim.gameMap.center.x
      sim.players[shooter].y = sim.gameMap.center.y
      sim.players[shooter].aimBrads = 0
      sim.players[target].x = sim.gameMap.center.x + 40
      sim.players[target].y = sim.gameMap.center.y
      sim.players[target].hp = 100000        # never dies over the sample
      for _ in 0 ..< 200:
        sim.armToFire(shooter)
        sim.tryFire(shooter)
      sim.players[shooter].shotsHit

    let controlHits = hitsWithHandicap(0)
    let handicapHits = hitsWithHandicap(1000)
    check controlHits >= 190                 # ~all point-blank shots connect
    check handicapHits < controlHits         # the handicap drops shots
    check handicapHits in 60 .. 140          # centered on ~50% of 200

suite "handicap init markers (stated to policies)":
  # Both init streams carry one `handicap <color> ...` marker per team (see
  # LabelPrefixHandicap) — RAW labels on purpose (no normalization), collected
  # exactly the way the endzone-marker values test does, so the assertion pins
  # the emitted bytes and not a re-derivation.
  proc rawLabels(sim: var SimServer): seq[HashSet[string]] =
    var
      gstate = initGlobalViewerState()
      pstate: PlayerViewerState
    for stream in [sim.buildGlobalMessages(gstate),
                   sim.buildPlayerMessages(0, pstate)]:
      var raw: HashSet[string]
      for message in stream:
        if message.kind == spkSprite:
          raw.incl(message.sprite.label)
      result.add(raw)

  test "both init streams state a handicapped team's exact deltas":
    var sim = initCtfForTest(defaultGameConfig())
    discard sim.addPlayer("red0")
    discard sim.addPlayer("blue0")
    sim.startGame()
    sim.config.handicaps[Red] = 600
    # Literal expected strings, not accessor round-trips: defaults are 3 hp,
    # 3 lives, 704 speed, so 0.6 resolves to 2 hp, 2 lives, 69% speed
    # (704*1400/2000 = 492 -> 492*100/704 = 69) and 30% point-blank miss.
    check labelHandicap(teamText(Red), 600, 2, 2, 69, 30) ==
      "handicap red 600 hp 2 lives 2 spd 69 miss 30"
    for raw in sim.rawLabels():
      check "handicap red 600 hp 2 lives 2 spd 69 miss 30" in raw
      # The unhandicapped team is stated too — 0 means "no handicap",
      # a MISSING marker would mean an engine without the contract.
      check "handicap blue 0 hp 3 lives 3 spd 100 miss 0" in raw

  test "an unhandicapped default game states base values for every team":
    var sim = initCtfForTest(defaultGameConfig())
    discard sim.addPlayer("red0")
    discard sim.addPlayer("blue0")
    sim.startGame()
    for raw in sim.rawLabels():
      for team in sim.gameMap.teams():
        check labelHandicap(
          teamText(team), 0,
          sim.config.hitPoints, sim.config.lives, 100, 0
        ) in raw
