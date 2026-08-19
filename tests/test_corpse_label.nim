import
  helpers,
  std/[sequtils, strutils, tables, unittest],
  bitworld/spriteprotocol,
  ctf/sim

proc spriteIdLabels(messages: openArray[SpritePacketMessage]): Table[int, string] =
  for m in messages:
    if m.kind == spkSprite:
      result[m.sprite.id.int] = m.sprite.label

proc objectLabel(
  messages: openArray[SpritePacketMessage],
  objectId: int
): string =
  ## The label of the sprite a given object references, or "" if absent.
  let idLabels = messages.spriteIdLabels()
  for m in messages:
    if m.kind == spkObject and m.objectDef.id == objectId:
      return idLabels.getOrDefault(m.objectDef.spriteId.int, "")
  ""

suite "corpse observation labels":
  test "a dead body reads as `corpse <color> <side>`, never as a live player":
    var game = initCtfForTest(defaultGameConfig())
    let
      viewer = game.addPlayer("red0")
      foe = game.addPlayer("blue0")
    game.startGame()
    game.players[viewer].team = Red
    game.players[foe].team = Blue
    # The enemy is dead; the viewer is a ghost so the whole map (incl. bodies)
    # renders unfogged.
    game.players[foe].alive = false
    game.players[foe].hp = 0
    game.players[viewer].alive = false
    game.players[viewer].hp = 0

    let
      messages = game.playerMessages(viewer)
      foeObject = 1000 + game.players[foe].joinOrder
      label = messages.objectLabel(foeObject)
    # The body's own object must reference a corpse sprite — not a `player`/`self`
    # label a scanning policy would read as a live enemy (RULES.md).
    check label.startsWith("corpse blue ")
    check not label.startsWith("player ")
    check not label.startsWith("self ")

  test "a live player still reads as `player <color> <side>`":
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
    # Enemy directly in front of the viewer's aim cone so it renders.
    game.players[viewer].x = cx
    game.players[viewer].y = cy
    game.players[viewer].aimBrads = 64
    game.players[foe].x = cx
    game.players[foe].y = cy - 40

    let
      messages = game.playerMessages(viewer)
      foeObject = 1000 + game.players[foe].joinOrder
      label = messages.objectLabel(foeObject)
    check label.startsWith("player blue ")
