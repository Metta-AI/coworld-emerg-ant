import
  helpers,
  std/[sequtils, strutils, unittest],
  bitworld/spriteprotocol,
  ctf/[global, sim]

proc spriteLabels(messages: openArray[SpritePacketMessage]): seq[string] =
  for message in messages:
    if message.kind == spkSprite:
      result.add(message.sprite.label)

suite "player fog-of-war protocol":
  test "full-map POV: fog runs, self marker, no arrows, fov-culled enemies":
    var game = initCtfForTest(defaultGameConfig())
    let viewer = game.addPlayer("red0")
    let foe = game.addPlayer("blue0")
    game.startGame()
    game.players[viewer].team = Red
    game.players[foe].team = Blue
    let
      cx = game.gameMap.center.x
      cy = game.gameMap.center.y
    # Viewer at the center aiming up the open corridor; enemy fogged behind.
    game.players[viewer].x = cx
    game.players[viewer].y = cy
    game.players[viewer].aimBrads = 64
    game.players[foe].x = cx
    game.players[foe].y = 550

    var state: PlayerViewerState
    let messages = game.buildPlayerMessages(viewer, state)
    let labels = messages.spriteLabels()

    # The old 128x128 shadow view and the flag arrows are gone.
    for label in labels:
      check not label.contains("arrow")
      check label != "shadow"
    # The fog overlay and the distinct self marker are present. The viewer reads
    # as a white-outlined rotating soldier (aim shown by the held gun's sweep),
    # not the retired floating aim dots — but the marker keeps the DOCUMENTED
    # `self <color> <side>` label (RULES.md) so exact-match label readers work.
    # Aim 64 (east-ish) faces right.
    check "fog" in labels
    check "self red right" in labels
    check labels.anyIt(it.startsWith("self red ") or it.startsWith("self blue "))
    # The map object sits at the origin: object coords are map coords.
    var mapAtOrigin = false
    for message in messages:
      if message.kind == spkObject and message.objectDef.id == 1 and
          message.objectDef.spriteId == 1:
        mapAtOrigin = message.objectDef.x == 0 and message.objectDef.y == 0
    check mapAtOrigin
    # The fogged enemy is culled; the viewer itself is present.
    check not messages.hasObject(1000 + game.players[foe].joinOrder)
    check messages.hasObject(1000 + game.players[viewer].joinOrder)
    # Both pedestal flags are always present (5009 red, 5010 blue).
    check messages.hasObject(5009)
    check messages.hasObject(5010)

    # Turn the viewer around: the enemy enters the cone and appears.
    game.players[viewer].aimBrads = 192
    let turned = game.buildPlayerMessages(viewer, state)
    check turned.hasObject(1000 + game.players[foe].joinOrder)

  test "teammates and a teammate-carried flag fog like enemies":
    var game = initCtfForTest(defaultGameConfig())
    let viewer = game.addPlayer("red0")
    discard game.addPlayer("blue0")
    let mate = game.addPlayer("red1")
    game.startGame()
    game.players[viewer].team = Red
    game.players[1].team = Blue
    game.players[mate].team = Red
    let
      cx = game.gameMap.center.x
      cy = game.gameMap.center.y
    game.players[viewer].x = cx
    game.players[viewer].y = cy
    game.players[viewer].aimBrads = 64
    # The teammate runs the stolen blue flag far behind the viewer.
    game.players[mate].x = cx
    game.players[mate].y = 550
    game.flags[Blue].carrier = mate
    game.players[mate].carryingFlag = true
    game.flags[Blue].x = cx
    game.flags[Blue].y = 550

    var state: PlayerViewerState
    # The mate is behind the viewer (aiming north): fogged, flag and all.
    let messages = game.buildPlayerMessages(viewer, state)
    check not messages.hasObject(1000 + game.players[mate].joinOrder)
    check not messages.hasObject(5010)

    # Turn around: the mate and its carried flag appear.
    game.players[viewer].aimBrads = 192
    var state2: PlayerViewerState
    let turned = game.buildPlayerMessages(viewer, state2)
    check turned.hasObject(1000 + game.players[mate].joinOrder)
    check turned.hasObject(5010)

  test "only a shot's landing rings for players; tracers are spectator-only":
    var game = initCtfForTest(defaultGameConfig())
    let viewer = game.addPlayer("red0")
    discard game.addPlayer("blue0")
    game.startGame()
    game.players[viewer].team = Red
    game.players[1].team = Blue
    let
      cx = game.gameMap.center.x
      cy = game.gameMap.center.y
    game.players[viewer].x = cx
    game.players[viewer].y = cy
    game.players[viewer].aimBrads = 64   # looking up the open corridor.
    # A shot fired dead ahead, fully inside the viewer's vision cone (the
    # same corridor the fov tests above rely on being open and visible).
    game.recentShots.add ShotFx(
      x0: cx, y0: cy - 40, x1: cx, y1: cy - 140,
      firedTick: game.tickCount, color: game.players[1].color, hit: true
    )
    game.hitFlashes.add HitFlashFx(playerIndex: 1, tick: game.tickCount)

    var state: PlayerViewerState
    let messages = game.buildPlayerMessages(viewer, state)
    let labels = messages.spriteLabels()
    # Even a fully seen shot yields ONLY the jittered landing ring: the
    # muzzle emits no signal...
    check messages.hasObject(19120)      # impact ring (ShotImpactObjectBase).
    check "shot impact" in labels
    check not messages.hasObject(19100)  # retired muzzle sound-ring pool.
    check "shot sound" notin labels
    # ...and never any tracer pixels or struck-target flashes: those are
    # spectator render only.
    for label in labels:
      check not label.startsWith("shot trail")
      check not label.startsWith("shot head")
      check not label.startsWith("muzzle bloom")
      check not label.startsWith("hit flash")

    # A shot fired and landing well behind the viewer still rings at the
    # landing: sound ignores fov.
    game.recentShots.add ShotFx(
      x0: cx, y0: 550, x1: cx + 200, y1: 550,
      firedTick: game.tickCount, color: game.players[1].color, hit: false
    )
    var state2: PlayerViewerState
    let unseen = game.buildPlayerMessages(viewer, state2)
    check unseen.hasObject(19121)        # second shot's impact ring.
    check not unseen.hasObject(19101)    # and still no muzzle ring.

    # The broadcast/global view still draws the full tracer comet. Both shots
    # are brand new (age stage 0), but only the HIT draws full-bright: the
    # miss pre-ages by MissStagePenalty (2) fade stages across its whole
    # comet, so hits pop and misses read as faded ghosts.
    var
      globalState = initGlobalViewerState()
      globalNext: GlobalViewerState
    let globalLabels = game.buildSpriteProtocolUpdates(globalState, globalNext)
      .parseSpritePacket().spriteLabels()
    check globalLabels.anyIt(it.startsWith("shot trail"))
    check globalLabels.anyIt(it.startsWith("shot head") and
      it.endsWith("stage 0"))          # the hit: full-bright.
    check globalLabels.anyIt(it.startsWith("shot head") and
      it.endsWith("stage 2"))          # the miss: pre-faded.
    check "muzzle bloom stage 0" in globalLabels
    check "muzzle bloom stage 2" in globalLabels
    # ...and rings the struck target with the fresh hit flash.
    check "hit flash stage 0" in globalLabels
