import
  helpers,
  std/unittest,
  bitworld/spriteprotocol,
  ctf/[global, sim]

const
  ShieldBubbleObjectBase = 19940  ## mirrors global.nim (private there).
  ShieldCarryObjectBase = 19900   ## mirrors global.nim (private there).

proc objectSpriteId(
  messages: openArray[SpritePacketMessage],
  objectId: int
): int =
  ## Returns the sprite id an object draws with, or -1 when absent.
  result = -1
  for message in messages:
    if message.kind == spkObject and message.objectDef.id == objectId:
      return message.objectDef.spriteId

const
  ShieldBubbleSpriteId = 1422
  ShieldBubbleDeformBase = 1424
  ShieldBubbleDeformCount = 16 * 4

suite "shield carrier bubble":
  test "bubble appears on pickup and pops when the shield layer is spent":
    var game = initCtfForTest(defaultGameConfig())
    let red = game.addPlayer("red0")
    discard game.addPlayer("blue0")
    game.startGame()

    var state = initGlobalViewerState()
    # No shield yet: no bubble, and no overhead carry marker either.
    var messages = game.buildGlobalMessages(state)
    check not messages.hasObject(ShieldBubbleObjectBase + red)
    check not messages.hasObject(ShieldCarryObjectBase + red)

    # A fresh carrier (full shield layer) shows the bubble — and ONLY the
    # bubble: the overhead carry marker would double-report the same state.
    game.players[red].hasShield = true
    game.players[red].shieldHp = ShieldLayerHp
    messages = game.buildGlobalMessages(state)
    check messages.hasObject(ShieldBubbleObjectBase + red)
    check not messages.hasObject(ShieldCarryObjectBase + red)

    # Worn down but still holding shield hp: the bubble stays at exactly 1.
    game.players[red].shieldHp = 1
    messages = game.buildGlobalMessages(state)
    check messages.hasObject(ShieldBubbleObjectBase + red)
    check not messages.hasObject(ShieldCarryObjectBase + red)

    # A spent layer pops the bubble; the small carry marker takes over (the
    # shield's fire slowdown is still on, so the state stays readable).
    game.players[red].shieldHp = 0
    messages = game.buildGlobalMessages(state)
    check not messages.hasObject(ShieldBubbleObjectBase + red)
    check messages.hasObject(ShieldCarryObjectBase + red)

    # Dead carriers never show a bubble — nor the marker.
    game.players[red].shieldHp = ShieldLayerHp
    game.players[red].alive = false
    messages = game.buildGlobalMessages(state)
    check not messages.hasObject(ShieldBubbleObjectBase + red)
    check not messages.hasObject(ShieldCarryObjectBase + red)

  test "a hit on the bubble blinks the bubble instead of the body FX":
    var game = initCtfForTest(defaultGameConfig())
    let
      red = game.addPlayer("red0")
      blue = game.addPlayer("blue0")
    game.startGame()
    game.players[red].team = Red
    game.players[blue].team = Blue
    # Blue shoots the bubbled carrier from the east (like test_shields).
    game.players[red].x = 300
    game.players[red].y = 300
    game.players[red].hasShield = true
    game.players[red].shieldHp = ShieldLayerHp
    game.players[blue].x = 300 + 30
    game.players[blue].y = 300
    game.players[blue].aimBrads = 128
    game.players[blue].fireCooldown = 0
    game.tryFire(blue)

    # The hit lands on the shield layer (3 -> 2, base hp untouched) but the
    # body FX are absorbed by the bubble: no struck-target flash, no body
    # paint spark — a bubble impact instead (the "-1" pop still reports the
    # damage).
    check game.players[red].shieldHp == ShieldLayerHp - 1
    check game.players[red].hp == game.config.hitPoints
    check game.bubbleImpacts.len == 1
    check game.bubbleImpacts[0].playerIndex == red
    check game.hitFlashes.len == 0
    check game.splatters.len == 0
    check game.damagePops.len == 1

    # The bubble object now draws a blink/dent variant, not the idle ring.
    var state = initGlobalViewerState()
    var messages = game.buildGlobalMessages(state)
    let hitSprite = messages.objectSpriteId(ShieldBubbleObjectBase + red)
    check hitSprite >= ShieldBubbleDeformBase
    check hitSprite < ShieldBubbleDeformBase + ShieldBubbleDeformCount

    # Once the impact FX window passes, the bubble eases back to idle.
    let none = newSeq[InputState](game.players.len)
    for _ in 0 ..< BubbleImpactTicks + 1:
      game.step(none, none)
    messages = game.buildGlobalMessages(state)
    check messages.objectSpriteId(ShieldBubbleObjectBase + red) ==
      ShieldBubbleSpriteId

  test "a hit below the bubble threshold keeps the normal body FX":
    var game = initCtfForTest(defaultGameConfig())
    let
      red = game.addPlayer("red0")
      blue = game.addPlayer("blue0")
    game.startGame()
    game.players[red].team = Red
    game.players[blue].team = Blue
    # The carrier is already worn below the bubble threshold: no bubble, so
    # the ordinary struck-target flash and paint spark show as always.
    game.players[red].x = 300
    game.players[red].y = 300
    game.players[red].hasShield = true
    game.players[red].hp = 3
    game.players[blue].x = 300 + 30
    game.players[blue].y = 300
    game.players[blue].aimBrads = 128
    game.players[blue].fireCooldown = 0
    game.tryFire(blue)

    check game.players[red].hp == 2
    check game.bubbleImpacts.len == 0
    check game.hitFlashes.len == 1
    check game.splatters.len == 1
