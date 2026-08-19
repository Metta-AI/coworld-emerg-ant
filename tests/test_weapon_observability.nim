import
  helpers,
  std/[os, sequtils, strutils, unittest],
  bitworld/spriteprotocol,
  ctf/[global, sim]

proc labels(sim: var SimServer, playerIndex: int): seq[string] =
  var state, nextState: PlayerViewerState
  for m in sim.buildSpriteProtocolPlayerUpdates(playerIndex, state, nextState)
      .parseSpritePacket():
    if m.kind == spkSprite:
      result.add m.sprite.label

proc boardLabels(sim: var SimServer): seq[string] =
  ## Sprite labels from the spectator/replay board packet (where the cog rig,
  ## and so the held weapon, is drawn — the player stream has no rig).
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    var state = initGlobalViewerState()
    var nextState: GlobalViewerState
    for m in sim.buildSpriteProtocolUpdates(state, nextState).parseSpritePacket():
      if m.kind == spkSprite:
        result.add m.sprite.label
  finally:
    setCurrentDir(previousDir)

suite "weapon observability":
  test "own HUD names the weapon; badges carry an explicit weapon token":
    var game = initCtfForTest(defaultGameConfig())
    let viewer = game.addPlayer("red0")
    discard game.addPlayer("blue0")
    game.startGame()
    var ls = game.labels(viewer)
    check "weapon gun" in ls
    check ls.anyIt(it.startsWith("identity ") and it.endsWith(" gun"))
    game.players[viewer].hasPlasmaArc = true
    ls = game.labels(viewer)
    check "weapon spray" in ls
    check ls.anyIt(it.startsWith("identity ") and it.endsWith(" spray"))

  test "the board swaps the HELD weapon art to the can while one is carried":
    # A cog holds exactly one weapon, so the held art must follow the sim's
    # gun/spray swap — otherwise a spraying cog is drawn brandishing a marker.
    var game = initCtfForTest(defaultGameConfig())
    let viewer = game.addPlayer("red0")
    discard game.addPlayer("blue0")
    game.startGame()
    var ls = game.boardLabels()
    check ls.anyIt(it.startsWith("cog gun "))
    check not ls.anyIt(it.startsWith("cog spray can "))
    game.players[viewer].hasPlasmaArc = true
    ls = game.boardLabels()
    check ls.anyIt(it.startsWith("cog spray can "))
