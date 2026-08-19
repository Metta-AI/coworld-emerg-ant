import
  helpers,
  std/[json, sets, unittest],
  bitworld/spriteprotocol,
  ctf/[broadcast, global, labels, replays, sim]

# Team perks: named, config-assigned buffs — armor (+hp), scope (tighter aim),
# grenade (longer throws), thruster (faster top speed), luck (double-damage
# shots) — with config-tunable magnitudes (perkMods) and per-policy groups for
# CTF-Doubles. See docs/plans/2026-08-07-team-perks-design.md. Like handicaps,
# the default (perk-free) config must play byte-identical to an engine without
# perks; the fixture re-simulation in test_replay guards that end to end.

suite "perk accessors (pure math)":
  proc baseConfig(): GameConfig =
    result = defaultGameConfig()
    result.lives = 3
    result.hitPoints = 3
    result.maxSpeed = 704

  test "no perks returns the exact base values":
    let cfg = baseConfig()
    check cfg.maxHpFor(Red, {}) == 3
    check cfg.maxSpeedFor(Red, {}) == 704
    check cfg.grenadeRangeFor(240, {}) == 240

  test "armor adds perkArmorHp to max hit points":
    var cfg = baseConfig()
    check cfg.maxHpFor(Red, {PerkArmor}) == 4
    cfg.perkMods.armorHp = 3
    check cfg.maxHpFor(Red, {PerkArmor}) == 6

  test "thruster boosts max speed by perkThrusterPermille":
    var cfg = baseConfig()
    check cfg.maxSpeedFor(Red, {PerkThruster}) == 774   # 704 * 1100 / 1000
    cfg.perkMods.thrusterSpeed = 500
    check cfg.maxSpeedFor(Red, {PerkThruster}) == 1056  # 704 * 1500 / 1000

  test "grenade stretches the throw range by perkGrenadePermille":
    var cfg = baseConfig()
    check cfg.grenadeRangeFor(240, {PerkGrenade}) == 300  # +25%
    cfg.perkMods.grenadeRange = 1000
    check cfg.grenadeRangeFor(240, {PerkGrenade}) == 480  # double

  test "an unrelated perk changes nothing":
    let cfg = baseConfig()
    check cfg.maxHpFor(Red, {PerkLuck, PerkScope}) == 3
    check cfg.maxSpeedFor(Red, {PerkLuck, PerkScope}) == 704
    check cfg.grenadeRangeFor(240, {PerkLuck, PerkScope}) == 240

  test "perks stack on top of the handicap interpolation":
    var cfg = baseConfig()
    cfg.handicaps[Red] = 1000            # 1 hp, half speed
    check cfg.maxHpFor(Red, {PerkArmor}) == 2         # 1 + 1
    check cfg.maxSpeedFor(Red, {PerkThruster}) == 387  # 352 * 1100 / 1000

suite "perk config parsing":
  test "a flat name array is one team-wide group":
    var cfg = defaultGameConfig()
    cfg.update("""{"perks": {"red": ["armor", "scope"]}}""")
    check cfg.perks[Red] == @[PerkGroup(perks: {PerkArmor, PerkScope})]
    check cfg.perks[Blue].len == 0

  test "nested arrays are per-policy groups":
    var cfg = defaultGameConfig()
    cfg.update(
      """{"perks": {"blue": [["grenade"], ["thruster", "luck"]]}}""")
    check cfg.perks[Blue] == @[
      PerkGroup(perks: {PerkGrenade}),
      PerkGroup(perks: {PerkThruster, PerkLuck})]

  test "the default config has no perks":
    let cfg = defaultGameConfig()
    for team in Red .. Yellow:
      check cfg.perks[team].len == 0

  test "an unknown perk name is rejected":
    var cfg = defaultGameConfig()
    expect CtfError:
      cfg.update("""{"perks": {"red": ["wings"]}}""")

  test "an unknown team key is rejected":
    var cfg = defaultGameConfig()
    expect CtfError:
      cfg.update("""{"perks": {"purple": ["armor"]}}""")

  test "a non-object perks block is rejected":
    var cfg = defaultGameConfig()
    expect CtfError:
      cfg.update("""{"perks": ["armor"]}""")

  test "a flat empty perk array is rejected (omit the team instead)":
    # An empty flat array would otherwise register as one empty group and
    # flip the has-perks gates (pmods, marker content) on a perk-free team.
    var cfg = defaultGameConfig()
    expect CtfError:
      cfg.update("""{"perks": {"red": []}}""")
    # An empty NESTED group stays legal: "this policy gets nothing".
    cfg.update("""{"perks": {"red": [["armor"], []]}}""")
    check cfg.perks[Red] == @[PerkGroup(perks: {PerkArmor}), PerkGroup()]

  test "a policy-name object pins groups to policies":
    var cfg = defaultGameConfig()
    cfg.update(
      """{"perks": {"red": {"alpha": ["armor"], "bravo": ["scope", "luck"]}}}""")
    check cfg.perks[Red].len == 2
    for group in cfg.perks[Red]:
      if group.pol == "alpha":
        check group.perks == {PerkArmor}
      else:
        check group.pol == "bravo"
        check group.perks == {PerkScope, PerkLuck}

  test "an empty policy-name object is rejected":
    var cfg = defaultGameConfig()
    expect CtfError:
      cfg.update("""{"perks": {"red": {}}}""")

  test "an absurd integer perk mod is rejected":
    var cfg = defaultGameConfig()
    expect CtfError:
      cfg.update("""{"perkMods": {"armorHp": 1000000}}""")

  test "perkMods parses fractions to permille and counts to ints":
    var cfg = defaultGameConfig()
    cfg.update("""{"perkMods": {"armorHp": 2, "scopeAim": 0.8,
      "grenadeRange": 0.5, "thrusterSpeed": 0.2, "luckChance": 1,
      "luckDamage": 3}}""")
    check cfg.perkMods == PerkMods(
      armorHp: 2, scopeAim: 800, grenadeRange: 500, thrusterSpeed: 200,
      luckChance: 1000, luckDamage: 3)

  test "an unknown perkMods key is rejected":
    var cfg = defaultGameConfig()
    expect CtfError:
      cfg.update("""{"perkMods": {"wingsSpan": 1}}""")

  test "an out-of-range perkMods fraction is rejected":
    var cfg = defaultGameConfig()
    expect CtfError:
      cfg.update("""{"perkMods": {"scopeAim": 1.5}}""")

  test "a zero luckDamage is rejected":
    var cfg = defaultGameConfig()
    expect CtfError:
      cfg.update("""{"perkMods": {"luckDamage": 0}}""")

suite "perk config echo (configJson)":
  test "a default game echoes no perks or perkMods keys":
    let echoed = configJson(defaultGameConfig()).parseJson()
    check not echoed.hasKey("perks")
    check not echoed.hasKey("perkMods")

  test "a flat group round-trips flat":
    var cfg = defaultGameConfig()
    cfg.update("""{"perks": {"red": ["scope", "armor"]}}""")
    let echoed = configJson(cfg).parseJson()
    check echoed["perks"]["red"] == %*["armor", "scope"]   # Perk enum order
    check not echoed["perks"].hasKey("blue")
    var reparsed = defaultGameConfig()
    reparsed.update(configJson(cfg))
    check reparsed.perks == cfg.perks

  test "per-policy groups round-trip nested":
    var cfg = defaultGameConfig()
    cfg.update(
      """{"perks": {"blue": [["grenade"], ["thruster", "luck"]]}}""")
    let echoed = configJson(cfg).parseJson()
    check echoed["perks"]["blue"] == %*[["grenade"], ["thruster", "luck"]]
    var reparsed = defaultGameConfig()
    reparsed.update(configJson(cfg))
    check reparsed.perks == cfg.perks

  test "named groups round-trip as a policy-name object":
    var cfg = defaultGameConfig()
    cfg.update(
      """{"perks": {"red": {"alpha": ["armor"], "bravo": ["luck"]}}}""")
    let echoed = configJson(cfg).parseJson()
    check echoed["perks"]["red"]["alpha"] == %*["armor"]
    check echoed["perks"]["red"]["bravo"] == %*["luck"]
    var reparsed = defaultGameConfig()
    reparsed.update(configJson(cfg))
    check reparsed.perks == cfg.perks

  test "non-default perkMods round-trip":
    var cfg = defaultGameConfig()
    cfg.update("""{"perkMods": {"luckChance": 0.25}}""")
    let echoed = configJson(cfg).parseJson()
    check abs(echoed["perkMods"]["luckChance"].getFloat() - 0.25) < 1e-9
    var reparsed = defaultGameConfig()
    reparsed.update(configJson(cfg))
    check reparsed.perkMods.luckChance == 250
    check reparsed.perkMods.luckDamage == cfg.perkMods.luckDamage

suite "perk group resolution at join (2v2 policies)":
  proc perkedSim(perksJson: string): SimServer =
    var config = defaultGameConfig()
    config.update("""{"perks": """ & perksJson & "}")
    initCtfForTest(config)

  test "a single group is team-wide":
    var sim = perkedSim("""{"red": ["armor"]}""")
    for address in ["polA", "polB", "polA_(2)", "polB_(2)"]:
      discard sim.addPlayer(address)
    # Slots alternate Red, Blue, Red, Blue; both Red seats share the group.
    check sim.players[0].perks == {PerkArmor}
    check sim.players[2].perks == {PerkArmor}
    check sim.players[1].perks == {}
    check sim.players[3].perks == {}

  test "two groups deal to the team's distinct policies in join order":
    var sim = perkedSim(
      """{"red": [["armor"], ["scope", "luck"]],
          "blue": [["thruster"], ["grenade"]]}""")
    # Red seats: polA (slot 0), polB (slot 2), polA (2) (slot 4);
    # Blue seats: polC (slot 1), polD (slot 3).
    for address in ["polA", "polC", "polB", "polD", "polA_(2)"]:
      discard sim.addPlayer(address)
    check sim.players[0].perks == {PerkArmor}          # polA -> group 0
    check sim.players[2].perks == {PerkScope, PerkLuck} # polB -> group 1
    check sim.players[4].perks == {PerkArmor}          # polA again -> group 0
    check sim.players[1].perks == {PerkThruster}       # polC -> group 0
    check sim.players[3].perks == {PerkGrenade}        # polD -> group 1

  test "a third policy clamps to the last group":
    var sim = perkedSim("""{"red": [["armor"], ["scope"]]}""")
    for address in ["polA", "polC", "polB", "polD", "polE"]:
      discard sim.addPlayer(address)
    check sim.players[4].perks == {PerkScope}          # polE (Red) clamps

  test "named groups pin policies regardless of join order":
    var sim = perkedSim(
      """{"red": {"polB": ["armor"], "polA": ["scope"]},
          "blue": {"polC": ["luck"]}}""")
    # polA joins Red FIRST but is pinned to scope; polB second, pinned to
    # armor — connection order no longer decides. polD (Blue) matches no
    # named group and gets nothing.
    for address in ["polA", "polC", "polB", "polD", "polA_(2)"]:
      discard sim.addPlayer(address)
    check sim.players[0].perks == {PerkScope}          # polA (joined first)
    check sim.players[2].perks == {PerkArmor}          # polB
    check sim.players[4].perks == {PerkScope}          # polA's second seat
    check sim.players[1].perks == {PerkLuck}           # polC
    check sim.players[3].perks == {}                   # polD: unmatched

  test "live joins and trusted playback joins deal identical groups":
    # Replay playback re-runs joins via the trusted-slot path
    # (addPlayer(name, slot, token, trusted = true), replays.nim); a perked
    # replay is only deterministic if that path resolves the same groups the
    # live path did. Same addresses, both paths, seat for seat.
    let addresses = ["polA", "polC", "polB", "polD", "polA_(2)", "polC_(2)"]
    var live = perkedSim(
      """{"red": [["armor"], ["scope", "luck"]],
          "blue": [["thruster"], ["grenade"]]}""")
    for address in addresses:
      discard live.addPlayer(address)
    var played = perkedSim(
      """{"red": [["armor"], ["scope", "luck"]],
          "blue": [["thruster"], ["grenade"]]}""")
    for slot, address in addresses:
      discard played.addPlayer(address, slot, "", trusted = true)
    for i in 0 ..< addresses.len:
      check played.players[i].perks == live.players[i].perks

  test "a seat's perks survive the replay keyframe round-trip":
    var sim = perkedSim("""{"red": ["armor", "luck"], "blue": ["scope"]}""")
    discard sim.addPlayer("red0")
    discard sim.addPlayer("blue0")
    sim.startGame()
    let bytes = sim.serializeReplaySim()
    var restored = deserializeReplaySim(bytes, sim)
    check restored.players[0].perks == {PerkArmor, PerkLuck}
    check restored.players[1].perks == {PerkScope}
    check restored.players[0].hp ==
      restored.config.maxHpFor(Red, restored.players[0].perks)

suite "perks applied in the sim":
  test "an armored team spawns, respawns, and heals at +1 hp":
    var config = defaultGameConfig()
    config.update("""{"perks": {"red": ["armor"]}}""")
    var sim = initCtfForTest(config)
    discard sim.addPlayer("red0")
    discard sim.addPlayer("blue0")
    sim.startGame()
    check sim.players[0].hp == sim.config.hitPoints + 1
    check sim.players[1].hp == sim.config.hitPoints
    # Med kit heals back to the ARMORED max.
    sim.players[0].hp = 1
    sim.players[0].x = sim.medKitSpawns[0].x - CollisionW div 2
    sim.players[0].y = sim.medKitSpawns[0].y - CollisionH div 2
    sim.tryPickupMedKits(0)
    check sim.players[0].hp == sim.config.hitPoints + 1
    # A killed armored player respawns at the ARMORED max too (respawnPlayers
    # is its own maxHpFor call site).
    sim.killPlayer(0, 1)
    check not sim.players[0].alive
    sim.players[0].respawnTimer = 1
    var prev = sim.none()
    sim.step(sim.none(), prev)
    check sim.players[0].alive
    check sim.players[0].hp == sim.config.hitPoints + 1

  test "a thruster team tops out 10% faster":
    var config = defaultGameConfig()
    config.update("""{"maxSpeed": 704, "perks": {"red": ["thruster"]}}""")
    var sim = initCtfForTest(config)
    let red = sim.addPlayer("red0")
    let blue = sim.addPlayer("blue0")
    sim.blockAll()
    sim.openField(40, 40, 400, 400)
    sim.placeStill(red, 100, 100)
    sim.placeStill(blue, 100, 300)
    for _ in 0 .. 30:
      sim.applyInput(red, InputState(right: true))
      sim.applyInput(blue, InputState(right: true))
    check sim.players[blue].velX == 704
    check sim.players[red].velX == 774                  # 704 * 1100 / 1000

  test "a real full-charge throw lands at the perked distance":
    # throwGrenade resolves its own maxRange (independently of throwTarget's
    # preview math), so the actual airborne target is asserted too.
    var config = defaultGameConfig()
    config.update("""{"perks": {"red": ["grenade"]}}""")
    var sim = initCtfForTest(config)
    discard sim.addPlayer("red0")
    discard sim.addPlayer("blue0")
    sim.startGame()
    sim.blockAll()
    sim.openField(40, 40, 1000, 500)
    for i in [0, 1]:
      sim.placeStill(i, 300 - CollisionW div 2, (200 + i * 200) - CollisionH div 2)
      sim.players[i].aimBrads = 0
      sim.players[i].hasGrenade = true
    # Each throw is asserted right after its release: a grenade's flight is
    # far shorter than the next throw's charge, so the two are never airborne
    # together.
    sim.chargeAndThrow(0, GrenadeChargeTicks + 2)
    let perkedRange =
      sim.config.grenadeRangeFor(GrenadeMaxRange, sim.players[0].perks)
    check sim.airborneGrenades.len == 1
    check sim.airborneGrenades[0].tx == 300 + perkedRange
    sim.chargeAndThrow(1, GrenadeChargeTicks + 2)
    check sim.airborneGrenades.len >= 1
    check sim.airborneGrenades[^1].tx == 300 + GrenadeMaxRange

  test "a grenade-perked throw ring and throw reach 25% further":
    var config = defaultGameConfig()
    config.update("""{"perks": {"red": ["grenade"]}}""")
    var sim = initCtfForTest(config)
    discard sim.addPlayer("red0")
    discard sim.addPlayer("blue0")
    sim.startGame()
    # Full-charge throw target due east from a fixed point, for each seat.
    for i in [0, 1]:
      sim.players[i].x = 300 - CollisionW div 2
      sim.players[i].y = 300 - CollisionH div 2
      sim.players[i].aimBrads = 0
      sim.players[i].throwCharge = GrenadeChargeTicks
    let perkedRange =
      sim.config.grenadeRangeFor(GrenadeMaxRange, sim.players[0].perks)
    check perkedRange == GrenadeMaxRange * 1250 div 1000
    let (redX, _) = throwTarget(sim.players[0], perkedRange)
    let (blueX, _) = throwTarget(
      sim.players[1],
      sim.config.grenadeRangeFor(GrenadeMaxRange, sim.players[1].perks)
    )
    check blueX == 300 + GrenadeMaxRange
    check redX == 300 + perkedRange

  test "a certain-luck shooter always deals perkLuckDamage":
    var config = defaultGameConfig()
    config.update("""{"perks": {"red": ["luck"]},
      "perkMods": {"luckChance": 1, "luckDamage": 2}}""")
    var sim = initCtfForTest(config)
    let shooter = sim.addPlayer("red0")
    let target = sim.addPlayer("blue0")
    sim.startGame()
    # Point-blank due-east geometry: the shot always connects.
    sim.players[shooter].x = sim.gameMap.center.x
    sim.players[shooter].y = sim.gameMap.center.y
    sim.players[shooter].aimBrads = 0
    sim.players[target].x = sim.gameMap.center.x + 40
    sim.players[target].y = sim.gameMap.center.y
    sim.players[target].hp = 100
    sim.armToFire(shooter)
    sim.tryFire(shooter)
    check sim.players[target].hp == 98
    # The unperked return shot deals the classic 1.
    sim.players[target].aimBrads = 128
    sim.players[shooter].hp = 100
    sim.armToFire(target)
    sim.tryFire(target)
    check sim.players[shooter].hp == 99

  test "perk mods alone (no perks assigned) leave the game hash unchanged":
    # The gating contract: magnitudes only matter for seats that carry the
    # perk, so a mods-only config re-simulates byte-for-byte with a default
    # one — same RNG stream, same hash, tick for tick.
    proc battle(configJsonText: string): uint64 =
      var config = defaultGameConfig()
      config.update(configJsonText)
      var sim = initCtfForTest(config)
      let shooter = sim.addPlayer("red0")
      let target = sim.addPlayer("blue0")
      sim.startGame()
      sim.players[shooter].x = sim.gameMap.center.x
      sim.players[shooter].y = sim.gameMap.center.y
      sim.players[shooter].aimBrads = 0
      sim.players[target].x = sim.gameMap.center.x + 40
      sim.players[target].y = sim.gameMap.center.y
      sim.players[target].hp = 100
      for _ in 0 ..< 50:
        sim.armToFire(shooter)
        sim.tryFire(shooter)
      sim.gameHash()
    check battle("{}") == battle("""{"perkMods": {"luckChance": 1,
      "luckDamage": 9, "scopeAim": 1, "thrusterSpeed": 1}}""")

suite "scope perk: tighter aim at range":
  # The gun_jitter lane: the widest fully clear corridor on the default arena
  # is ~313px, so live fire runs with a gunRange override of 250 inside it.
  # Jitter is calibrated to hit a fully visible max-range body 80% of the
  # time; halving sigma (the scope default) lifts that well above 90%.
  const
    ShortRange = 250
    ShooterX = 24
    ShooterY = 80

  proc laneSim(seed: int, perksJson: string): SimServer =
    var config = defaultGameConfig()
    config.update("""{"gunRange": """ & $ShortRange &
      """, "seed": """ & $seed & perksJson & "}")
    result = initCtfForTest(config)
    result.gameEventLoggingEnabled = false
    discard result.addPlayer("red0")
    discard result.addPlayer("blue0")
    result.startGame()
    result.players[0].x = ShooterX
    result.players[0].y = ShooterY
    result.players[0].aimBrads = 0
    result.players[1].y = ShooterY

  proc hitCount(game: var SimServer, targetX, shots: int): int =
    for _ in 0 ..< shots:
      game.players[1].x = targetX
      game.players[0].windupBrads = -1
      game.players[0].fireCooldown = 0
      game.players[1].hp = 3
      game.tryFire(0)
      if game.players[1].hp < 3:
        inc result

  test "a scoped shooter hits far more max-range shots":
    var control = laneSim(11, "")
    var scoped = laneSim(11, """, "perks": {"red": ["scope"]}""")
    let controlHits = control.hitCount(ShooterX + ShortRange, 200)
    let scopedHits = scoped.hitCount(ShooterX + ShortRange, 200)
    check controlHits in 130 .. 190          # calibrated ~80%
    check scopedHits > controlHits
    check scopedHits >= 190                  # half sigma -> ~99%

suite "perks stated to viewers and policies":
  test "labelPerks formats groups and the unperked dash":
    check labelPerks("red", @[], 1, 500, 250, 100, 100, 2) == "perks red -"
    check labelPerks("red", @["armor,scope"], 1, 500, 250, 100, 100, 2) ==
      "perks red armor,scope mods hp 1 aim 500 nade 250 spd 100 luck 100 dmg 2"
    check labelPerks("blue", @["grenade", "thruster,luck"], 1, 500, 250, 100, 100, 2) ==
      "perks blue grenade thruster,luck mods hp 1 aim 500 nade 250 spd 100 luck 100 dmg 2"
    check labelPerks("blue", @["", "luck"], 1, 500, 250, 100, 100, 2) ==
      "perks blue - luck mods hp 1 aim 500 nade 250 spd 100 luck 100 dmg 2"
    check labelPerks("red", @["luck"], 2, 100, 300, 50, 250, 3) ==
      "perks red luck mods hp 2 aim 100 nade 300 spd 50 luck 250 dmg 3"

  test "both init streams state every team's perk groups":
    var config = defaultGameConfig()
    config.update(
      """{"perks": {"red": [["armor", "scope"], ["thruster"]]}}""")
    var sim = initCtfForTest(config)
    discard sim.addPlayer("red0")
    discard sim.addPlayer("blue0")
    sim.startGame()
    var gstate = initGlobalViewerState()
    var pstate: PlayerViewerState
    for stream in [sim.buildGlobalMessages(gstate),
                   sim.buildPlayerMessages(0, pstate)]:
      var raw: HashSet[string]
      for message in stream:
        if message.kind == spkSprite:
          raw.incl(message.sprite.label)
      check "perks red armor,scope thruster" & " mods hp 1 aim 500 nade 250 spd 100 luck 100 dmg 2" in raw
      check "perks blue -" in raw

  test "the broadcast roster carries each perked seat's pk, omits others":
    var config = defaultGameConfig()
    config.update("""{"perks": {"red": ["luck", "armor"]}}""")
    var sim = initCtfForTest(config)
    discard sim.addPlayer("red0")
    discard sim.addPlayer("blue0")
    sim.startGame()
    let state = parseJson(sim.buildStateJson(
      newJArray(), false, 1, 1000, false, true, -1, -1
    ))
    for seat in state["roster"]:
      if seat["team"].getStr() == "red":
        check seat["pk"] == %*["armor", "luck"]        # Perk enum order
      else:
        check not seat.hasKey("pk")
    # The frame states the resolved perk magnitudes for the icon tooltips
    # (permille ints, sim-resolved) — present because a team has perks.
    check state["pmods"] == %*{
      "armorHp": 1, "scope": 500, "grenade": 250, "thruster": 100,
      "luck": 100, "luckDamage": 2
    }

  test "a perk-free game's frame carries no pmods":
    var sim = initCtfForTest(defaultGameConfig())
    discard sim.addPlayer("red0")
    discard sim.addPlayer("blue0")
    sim.startGame()
    let state = parseJson(sim.buildStateJson(
      newJArray(), false, 1, 1000, false, true, -1, -1
    ))
    check not state.hasKey("pmods")
