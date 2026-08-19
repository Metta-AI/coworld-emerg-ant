import
  helpers,
  std/[sequtils, strutils, unittest],
  bitworld/spriteprotocol,
  ctf/[global, sim]

proc mapLabels(sim: var SimServer): seq[string] =
  ## Builds one map-view sprite packet and returns its sprite labels. The
  ## initial state must come from initGlobalViewerState: a zeroed state has
  ## selectedJoinOrder 0, which silently builds slot 0's POV instead of the
  ## map view.
  var
    state = initGlobalViewerState()
    nextState: GlobalViewerState
  let messages = sim.buildSpriteProtocolUpdates(state, nextState)
    .parseSpritePacket()
  for message in messages:
    if message.kind == spkSprite:
      result.add(message.sprite.label)

suite "floating damage numbers":
  test "a non-fatal shot leaves a fading -1 pop that a fatal shot's death does not remove":
    var game = initCtfForTest(defaultGameConfig())
    let
      shooter = game.addPlayer("red0")
      target = game.addPlayer("blue0")
    game.startGame()
    game.players[shooter].team = Red
    game.players[target].team = Blue
    # Shooter aims due east (brads 0) at a target a short distance right, with
    # cooldown cleared so the shot lands this tick.
    game.players[shooter].x = game.gameMap.center.x
    game.players[shooter].y = game.gameMap.center.y
    game.players[shooter].aimBrads = 0
    game.players[shooter].windupBrads = -1
    game.players[shooter].fireCooldown = 0
    game.players[target].x = game.gameMap.center.x + 40
    game.players[target].y = game.gameMap.center.y

    let hpBefore = game.players[target].hp
    check hpBefore >= 2                     # needs a non-fatal hit to survive.
    game.tryFire(shooter)
    check game.players[target].hp == hpBefore - 1
    check game.damagePops.len == 1
    check game.damagePops[0].amount == 1
    # The connect also rings the victim with a struck-target flash.
    check game.hitFlashes.len == 1
    check game.hitFlashes[0].playerIndex == target

    # The pop renders as a blue "-1" sprite in the map view, and the victim
    # is ringed by the fresh hit flash.
    let labels = game.mapLabels()
    check labels.anyIt(it.startsWith("damage pop blue -1 stage 0"))
    check "hit flash stage 0" in labels

  test "a fatal shot adds a KO kill marker beside the -1 pop":
    var game = initCtfForTest(defaultGameConfig())
    let
      shooter = game.addPlayer("red0")
      target = game.addPlayer("blue0")
      bystander = game.addPlayer("blue1")
    game.startGame()
    game.players[shooter].team = Red
    game.players[target].team = Blue
    game.players[bystander].team = Blue
    # Shooter aims due east at a one-hp target; the second blue player stands
    # behind the shooter so the death is not a team wipe (no GameOver phase).
    game.players[shooter].x = game.gameMap.center.x
    game.players[shooter].y = game.gameMap.center.y
    game.players[shooter].aimBrads = 0
    game.players[shooter].windupBrads = -1
    game.players[shooter].fireCooldown = 0
    game.players[target].x = game.gameMap.center.x + 40
    game.players[target].y = game.gameMap.center.y
    game.players[target].hp = 1
    game.players[bystander].x = game.gameMap.center.x - 40
    game.players[bystander].y = game.gameMap.center.y

    game.tryFire(shooter)
    check not game.players[target].alive
    # The fatal hit leaves both the "-1" pop and the "KO" kill marker.
    check game.damagePops.len == 2
    check game.damagePops.anyIt(it.kill)
    let labels = game.mapLabels()
    check labels.anyIt(it.startsWith("damage pop blue -1 stage 0"))
    check labels.anyIt(it.startsWith("damage pop blue KO stage 0"))

  test "the pop is cosmetic: it never enters the game hash":
    var a = initCtfForTest(defaultGameConfig())
    var b = initCtfForTest(defaultGameConfig())
    discard a.addPlayer("red0")
    discard b.addPlayer("red0")
    a.startGame()
    b.startGame()
    let hashBefore = a.gameHash()
    check hashBefore == b.gameHash()
    # Injecting a cosmetic pop into one sim must not diverge the hashes.
    a.damagePops.add DamageFx(
      x: 10, y: 10, tick: a.tickCount, amount: 2, color: a.players[0].color
    )
    check a.gameHash() == hashBefore
    check a.gameHash() == b.gameHash()
    # Same for the cosmetic struck-target flash.
    a.hitFlashes.add HitFlashFx(playerIndex: 0, tick: a.tickCount)
    check a.gameHash() == hashBefore
    check a.gameHash() == b.gameHash()

  test "pops expire after their cosmetic lifetime":
    var game = initCtfForTest(defaultGameConfig())
    # Two players on opposite teams so neither side is wiped (a lone team
    # would win by wipe and enter GameOver, which skips cosmetic pruning).
    let a = game.addPlayer("red0")
    let b = game.addPlayer("blue0")
    game.startGame()
    game.players[a].team = Red
    game.players[b].team = Blue
    game.damagePops.add DamageFx(
      x: 10, y: 10, tick: game.tickCount, amount: 1, color: game.players[a].color
    )
    check game.damagePops.len == 1
    let noInput = newSeq[InputState](game.players.len)
    for _ in 0 ..< DamageFxTicks + 2:
      game.step(noInput, noInput)
    check game.damagePops.len == 0

  test "kill markers outlive -1 pops, then expire":
    var game = initCtfForTest(defaultGameConfig())
    let a = game.addPlayer("red0")
    let b = game.addPlayer("blue0")
    game.startGame()
    game.players[a].team = Red
    game.players[b].team = Blue
    game.damagePops.add DamageFx(
      x: 10, y: 10, tick: game.tickCount, amount: 1,
      color: game.players[a].color, kill: true
    )
    let noInput = newSeq[InputState](game.players.len)
    # Past a plain pop's lifetime the kill marker is still up...
    for _ in 0 ..< DamageFxTicks + 2:
      game.step(noInput, noInput)
    check game.damagePops.len == 1
    # ...and past its own longer lifetime it is gone.
    for _ in 0 ..< KillFxTicks:
      game.step(noInput, noInput)
    check game.damagePops.len == 0

  test "spray and trench-grenade amounts show their real value, not clamped to -2":
    # Spray deals PlasmaArcDamage=3 and a trench-trapped grenade deals
    # GrenadeTrenchDamage=6; both exceed the historical 2-hp cap and must not
    # be clamped down to "-2" in the displayed label.
    var game = initCtfForTest(defaultGameConfig())
    discard game.addPlayer("red0")
    game.startGame()
    game.players[0].team = Red
    let
      cx = game.gameMap.center.x
      cy = game.gameMap.center.y
    game.damagePops.add DamageFx(
      x: cx, y: cy, tick: game.tickCount, amount: 3, color: game.players[0].color
    )
    game.damagePops.add DamageFx(
      x: cx + 20, y: cy, tick: game.tickCount, amount: 6,
      color: game.players[0].color
    )
    let labels = game.mapLabels()
    check labels.anyIt(it.startsWith("damage pop red -3 stage 0"))
    check labels.anyIt(it.startsWith("damage pop red -6 stage 0"))
    check not labels.anyIt(it.startsWith("damage pop red -2 stage 0"))
