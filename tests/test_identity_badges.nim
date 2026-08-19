import
  helpers,
  std/[sequtils, strutils, tables, unittest],
  bitworld/spriteprotocol,
  ctf/[global, sim]

proc boardMessages(sim: var SimServer): seq[SpritePacketMessage] =
  ## One spectator/board frame from throwaway viewer state, the board twin of
  ## `playerMessages`.
  var state = initGlobalViewerState()
  sim.buildGlobalMessages(state)

proc badgePlacement(
  messages: openArray[SpritePacketMessage],
  prefix: string
): tuple[x, y, size, spriteId: int] =
  ## Where the drawn badge whose label starts with `prefix` landed, plus the
  ## wire size of its sprite (badges are square) and the sprite id it drew.
  var
    idLabels: Table[int, string]
    idSizes: Table[int, int]
  for m in messages:
    if m.kind == spkSprite:
      idLabels[m.sprite.id.int] = m.sprite.label
      idSizes[m.sprite.id.int] = m.sprite.width.int
  for m in messages:
    if m.kind == spkObject and
        idLabels.getOrDefault(m.objectDef.spriteId.int).startsWith(prefix):
      return (
        m.objectDef.x.int,
        m.objectDef.y.int,
        idSizes.getOrDefault(m.objectDef.spriteId.int),
        m.objectDef.spriteId.int
      )
  raise newException(ValueError, "no badge object for " & prefix)

proc presentLabels(messages: openArray[SpritePacketMessage]): seq[string] =
  ## Labels of every sprite referenced by a present object.
  var idLabels: Table[int, string]
  for m in messages:
    if m.kind == spkSprite:
      idLabels[m.sprite.id.int] = m.sprite.label
  for m in messages:
    if m.kind == spkObject:
      let label = idLabels.getOrDefault(m.objectDef.spriteId.int, "")
      if label.len > 0:
        result.add(label)

suite "identity badges":
  test "identities assign alpha..theta by slot order within each team":
    # Identity derives from the slot config alone — no players needed.
    # Default slots alternate red/blue: 0=red alpha, 1=blue alpha,
    # 2=red beta, 3=blue beta.
    var game = initCtfForTest(defaultGameConfig())
    check game.slotIdentityIndex(0) == 0
    check game.slotIdentityIndex(1) == 0
    check game.slotIdentityIndex(2) == 1
    check game.slotIdentityIndex(3) == 1

  test "a visible enemy's identity badge is in the observation":
    var game = initCtfForTest(defaultGameConfig())
    let
      viewer = game.addPlayer("red0")
      foe = game.addPlayer("blue0")
    game.startGame()
    game.players[viewer].team = Red
    game.players[foe].team = Blue
    let
      cx = game.gameMap.center.x
      cy = game.gameMap.center.y
    # Enemy directly inside the viewer's aim cone so it renders.
    game.players[viewer].x = cx
    game.players[viewer].y = cy
    game.players[viewer].aimBrads = 64
    game.players[foe].x = cx
    game.players[foe].y = cy - 40

    let labels = game.playerMessages(viewer).presentLabels()
    check "identity blue alpha gun" in labels
    check "identity red alpha gun" in labels  # yourself: always visible

  test "a fogged enemy's identity badge is not in the observation":
    var game = initCtfForTest(defaultGameConfig())
    let
      viewer = game.addPlayer("red0")
      foe = game.addPlayer("blue0")
    game.startGame()
    game.players[viewer].team = Red
    game.players[foe].team = Blue
    let
      cx = game.gameMap.center.x
      cy = game.gameMap.center.y
    # Enemy far BEHIND the viewer's aim: outside cone and bubble.
    game.players[viewer].x = cx
    game.players[viewer].y = cy
    game.players[viewer].aimBrads = 64  # aiming north
    game.players[foe].x = cx
    game.players[foe].y = cy + 300      # deep south

    let labels = game.playerMessages(viewer).presentLabels()
    check labels.allIt(not it.startsWith("identity blue alpha"))

  test "badge label carries the wearer's loadout as suffixes":
    var game = initCtfForTest(defaultGameConfig())
    let viewer = game.addPlayer("red0")
    discard game.addPlayer("blue0")
    game.startGame()
    game.players[viewer].team = Red
    var labels = game.playerMessages(viewer).presentLabels()
    check "identity red alpha gun" in labels
    game.players[viewer].hasShield = true
    game.players[viewer].hasGrenade = true
    labels = game.playerMessages(viewer).presentLabels()
    # Prefix-preserving: the bare label is REPLACED by the suffixed one.
    check "identity red alpha shield nade gun" in labels
    check "identity red alpha gun" notin labels
    game.players[viewer].hasShield = false
    game.players[viewer].hasGrenade = false
    game.players[viewer].hasPlasmaArc = true
    labels = game.playerMessages(viewer).presentLabels()
    check "identity red alpha spray" in labels

  test "the board badge rides behind the visor and turns with the cog":
    # The cog's face LEADS its aim, so a badge centered on the rotation hub sat
    # squarely on the visor. On the board it steps back onto the bare head
    # plate — always opposite the aim — and its glyph is baked per aim step, so
    # a turning cog carries the letter around instead of spinning under it.
    var game = initCtfForTest(defaultGameConfig())
    let me = game.addPlayer("red0")
    discard game.addPlayer("blue0")
    game.startGame()
    game.players[me].team = Red
    game.players[me].x = game.gameMap.center.x
    game.players[me].y = game.gameMap.center.y
    var spriteIds: seq[int]
    for brads in [0, 64, 128, 192]:
      game.players[me].aimBrads = brads
      let
        badge = game.boardMessages().badgePlacement("identity red alpha")
        aim = aimVector(brads)
        # Board placements ship at RenderScale x map pixels.
        dx = float(badge.x + badge.size div 2) -
          float(game.players[me].x * RenderScale)
        dy = float(badge.y + badge.size div 2) -
          float(game.players[me].y * RenderScale)
        along = (dx * aim.x + dy * aim.y) / float(RenderScale)
        across = (dx * aim.y - dy * aim.x) / float(RenderScale)
      # Behind the hub by a few px, and dead on the aim line (never sideways).
      check along <= -3.0
      check along >= -8.0
      check abs(across) <= 1.0
      spriteIds.add(badge.spriteId)
    # One baked sprite per aim step: four headings, four distinct letters.
    check spriteIds.deduplicate().len == 4

  test "a player view keeps the badge centered and upright":
    # RULES.md documents the badge as centered on its player's body ("attach it
    # by proximity"), so the board's head-plate offset must NOT reach the
    # observation stream — same object position and same sprite at every aim.
    var game = initCtfForTest(defaultGameConfig())
    let me = game.addPlayer("red0")
    discard game.addPlayer("blue0")
    game.startGame()
    game.players[me].team = Red
    game.players[me].x = game.gameMap.center.x
    game.players[me].y = game.gameMap.center.y
    var placements: seq[(int, int, int)]
    for brads in [0, 64, 128, 192]:
      game.players[me].aimBrads = brads
      let badge = game.playerMessages(me).badgePlacement("identity red alpha")
      placements.add((badge.x, badge.y, badge.spriteId))
    check placements.deduplicate().len == 1

  test "a dead player's identity badge disappears":
    var game = initCtfForTest(defaultGameConfig())
    let
      viewer = game.addPlayer("red0")
      foe = game.addPlayer("blue0")
    game.startGame()
    game.players[viewer].team = Red
    game.players[foe].team = Blue
    game.players[foe].alive = false
    game.players[foe].hp = 0
    game.players[viewer].alive = false  # ghost viewer sees everything
    game.players[viewer].hp = 0

    let labels = game.playerMessages(viewer).presentLabels()
    check labels.allIt(not it.startsWith("identity blue alpha"))
