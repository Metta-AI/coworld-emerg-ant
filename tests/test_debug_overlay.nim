import
  helpers,
  std/[os, tables, unittest],
  bitworld/spriteprotocol,
  ctf/[global, replays, server, sim]

proc packetHasSprite(packet: openArray[uint8], spriteId: int): bool =
  ## Returns true when a sprite packet defines one sprite id.
  for message in packet.parseSpritePacket():
    if message.kind == spkSprite and message.sprite.id == spriteId:
      return true

proc packetObject(
  packet: openArray[uint8],
  objectId: int
): SpritePacketObject =
  ## Returns one object definition from a sprite packet.
  for message in packet.parseSpritePacket():
    if message.kind == spkObject and message.objectDef.id == objectId:
      return message.objectDef
  result.id = -1

proc packetDeletesObject(packet: openArray[uint8], objectId: int): bool =
  ## Returns true when a sprite packet deletes one object id.
  for message in packet.parseSpritePacket():
    if message.kind == spkDeleteObject and message.objectId == objectId:
      return true

proc packetClearsObjects(packet: openArray[uint8]): bool =
  ## Returns true when a sprite packet clears all objects.
  for message in packet.parseSpritePacket():
    if message.kind == spkClearObjects:
      return true

proc corruptSpritePacket(spriteId: int): seq[uint8] =
  ## Builds a structurally valid sprite definition with invalid Snappy bytes.
  result.addU8(SpriteMessageSprite)
  result.addU16(spriteId)
  result.addU16(1)
  result.addU16(1)
  result.addU32(1)
  result.addU8(0xff)
  result.addU16(0)

proc addReplayHashes(data: var ReplayData, tickCount: int) =
  ## Adds deterministic hashes for a synthetic replay timeline.
  var
    game = initCtfForTest()
    replay = initReplayPlayer(data)
  for _ in 0 ..< tickCount:
    replay.stepReplay(game)
    data.hashes.add(ReplayHash(
      tick: uint32(game.tickCount),
      hash: game.gameHash()
    ))

suite "debug overlays":
  test "player messages buffer debug sprites and ignore ready":
    var
      state = initPlayerViewerState()
      inputMask = 0'u8
      pressedMask = 0'u8
      chatText = ""
      debugPacket: seq[uint8] = @[]
    debugPacket.addClearObjects()
    state.applyPlayerViewerMessage(
      blobFromSpriteReady() &
        blobFromSpriteDebugSprites(debugPacket) &
        blobFromSpriteMask(ButtonA),
      inputMask,
      pressedMask,
      chatText
    )

    check state.pendingDebugSprites == @[debugPacket]
    check inputMask == ButtonA
    check pressedMask == ButtonA

  test "ctf replay round trips debug records with inputs":
    let path = getTempDir() / "ctf-debug-overlay-roundtrip.bitreplay"
    defer:
      if fileExists(path):
        removeFile(path)
    var
      firstPacket: seq[uint8] = @[]
      secondPacket: seq[uint8] = @[]
    firstPacket.addClearObjects()
    secondPacket.addObject(4, 5, 6, 7, 0, 8)
    var writer = openReplayWriter(path, "{}")
    writer.writeInput(ReplayInput(time: 10'u32, player: 0, keys: ButtonLeft))
    writer.writeDebugSprite(20'u32, 0, firstPacket)
    writer.writeInput(ReplayInput(time: 30'u32, player: 1, keys: ButtonA))
    writer.writeDebugSprite(40'u32, 1, secondPacket)
    writer.closeReplayWriter()

    let data = parseReplayBytes(readFile(path))
    check data.inputs.len == 2
    check data.inputs[0].time == 10'u32
    check data.inputs[1].keys == ButtonA
    check data.debugSprites.len == 2
    check data.debugSprites[0].time == 20'u32
    check data.debugSprites[0].player == 0'u8
    check data.debugSprites[0].packet == firstPacket
    check data.debugSprites[1].time == 40'u32
    check data.debugSprites[1].player == 1'u8
    check data.debugSprites[1].packet == secondPacket

  test "overlay fold defines upserts deletes and clears":
    var
      overlay: DebugOverlay
      packet: seq[uint8] = @[]
    packet.addViewport(3, 100, 80)
    packet.addLayer(3, 1, 2)
    packet.addSprite(7, 1, 1, [1'u8, 2, 3, 4], "first")
    packet.addObject(9, 10, 11, 12, 3, 7)
    overlay.applyDebugSpritePacket(packet)

    check overlay.sprites.len == 1
    check overlay.sprites[7].label == "first"
    check overlay.objects[9].x == 10

    packet = @[]
    packet.addSprite(7, 1, 1, [5'u8, 6, 7, 8], "second")
    packet.addObject(9, 20, 21, 22, 4, 7)
    overlay.applyDebugSpritePacket(packet)
    check overlay.sprites[7].label == "second"
    check overlay.objects[9].x == 20

    packet = @[]
    packet.addDeleteObject(9)
    overlay.applyDebugSpritePacket(packet)
    check 9 notin overlay.objects

    packet = @[]
    packet.addObject(10, 0, 0, 0, 0, 7)
    packet.addClearObjects()
    overlay.applyDebugSpritePacket(packet)
    check overlay.objects.len == 0
    check overlay.sprites.len == 1

  test "keyframe snapshots restore overlays across shifted player indices":
    var
      firstPacket: seq[uint8] = @[]
      secondPacket: seq[uint8] = @[]
      shiftedPacket: seq[uint8] = @[]
      deletedPacket: seq[uint8] = @[]
    firstPacket.addSprite(7, 1, 1, [1'u8, 2, 3, 4], "first")
    firstPacket.addObject(9, 10, 0, 0, 0, 7)
    secondPacket.addSprite(7, 1, 1, [5'u8, 6, 7, 8], "second")
    secondPacket.addObject(9, 20, 0, 0, 0, 7)
    shiftedPacket.addObject(9, 30, 0, 0, 0, 7)
    deletedPacket.addDeleteObject(9)

    var data = ReplayData(
      joins: @[
        ReplayJoin(time: 0, player: 0, name: "red0", slot: -1),
        ReplayJoin(time: 0, player: 1, name: "blue0", slot: -1)
      ],
      leaves: @[
        ReplayLeave(time: tickTime(70), player: 0)
      ],
      debugSprites: @[
        ReplayDebugSprite(time: tickTime(2), player: 0, packet: firstPacket),
        ReplayDebugSprite(time: tickTime(2), player: 1, packet: secondPacket),
        ReplayDebugSprite(time: tickTime(3), player: 0, packet: @[0xff'u8]),
        ReplayDebugSprite(time: tickTime(70), player: 0, packet: shiftedPacket),
        ReplayDebugSprite(time: tickTime(120), player: 0, packet: deletedPacket)
      ]
    )
    data.addReplayHashes(150)
    var
      game = initCtfForTest()
      replay = initReplayPlayer(data)
    replay.looping = false
    replay.mismatchQuit = true
    replay.buildReplayKeyframes(game, interval = 50)
    replay.seekReplay(game, 130)
    check replay.overlays.len == 1
    check replay.overlays[0].objects.len == 0

    replay.seekReplay(game, 110)
    check replay.debugSpriteIndex == 4
    check replay.overlays.len == 1
    check replay.overlays[0].sprites[7].label == "second"
    check replay.overlays[0].objects[9].x == 30

    replay.seekReplay(game, 60)
    check replay.debugSpriteIndex == 3
    check replay.overlays.len == 2
    check replay.overlays[0].sprites[7].label == "first"
    check replay.overlays[0].objects[9].x == 10
    check replay.overlays[1].sprites[7].label == "second"
    check replay.overlays[1].objects[9].x == 20

    replay.seekReplay(game, 0)
    check replay.debugSpriteIndex == 0
    check replay.overlays.len == 0

  test "player id namespaces do not collide":
    check debugSpriteId(0, 7) != debugSpriteId(1, 7)
    check debugObjectId(0, 9) != debugObjectId(1, 9)
    # Debug sprite ids go through the dense wire remap (the raw key space
    # 40000..72767 crosses the u16 wire ceiling): the id is not the raw
    # formula anymore, but it must be stable across calls — even with other
    # dynamic-pool assignments interleaved — and inside the dynamic window.
    let first = debugSpriteId(1, 7)
    discard debugSpriteId(2, 8)
    check debugSpriteId(1, 7) == first
    check first >= DynamicSpriteWireBase
    check first <= 65535
    check debugObjectId(1, 9) ==
      DebugObjectBase + DebugPlayerIdStride + 9

  test "selected overlay renders and uses the viewer differ":
    var game = initCtfForTest()
    discard game.addPlayer("red0")
    discard game.addPlayer("blue0")
    var overlays = newSeq[DebugOverlay](2)
    var packet: seq[uint8] = @[]
    packet.addSprite(7, 1, 1, [1'u8, 2, 3, 4], "selected")
    packet.addObject(9, 10, 11, -10, 5, 7)
    overlays[0].applyDebugSpritePacket(packet)
    packet = @[]
    packet.addSprite(7, 1, 1, [5'u8, 6, 7, 8], "other")
    packet.addObject(9, 20, 21, 0, 0, 7)
    overlays[1].applyDebugSpritePacket(packet)

    var
      state = initGlobalViewerState()
      next: GlobalViewerState
    state.selectedJoinOrder = game.players[0].joinOrder
    let first = game.buildSpriteProtocolUpdates(state, next, overlays)
    let objectDef = first.packetObject(debugObjectId(0, 9))
    check first.packetHasSprite(debugSpriteId(0, 7))
    check not first.packetHasSprite(debugSpriteId(1, 7))
    check objectDef.id == debugObjectId(0, 9)
    check objectDef.z == DebugOverlayZ
    check objectDef.layer == 0

    state = next
    let unchanged = game.buildSpriteProtocolUpdates(state, next, overlays)
    check not unchanged.packetHasSprite(debugSpriteId(0, 7))

    packet = @[]
    packet.addSprite(7, 1, 1, [9'u8, 10, 11, 12], "selected")
    overlays[0].applyDebugSpritePacket(packet)
    state = next
    let changed = game.buildSpriteProtocolUpdates(state, next, overlays)
    check changed.packetHasSprite(debugSpriteId(0, 7))

    packet = @[]
    packet.addDeleteObject(9)
    packet.addObject(10, 0, 0, 0, 0, 99)
    overlays[0].applyDebugSpritePacket(packet)
    state = next
    let removed = game.buildSpriteProtocolUpdates(state, next, overlays)
    check removed.packetDeletesObject(debugObjectId(0, 9))
    check removed.packetObject(debugObjectId(0, 10)).id == -1

    state = next
    state.selectedJoinOrder = -1
    let deselected = game.buildSpriteProtocolUpdates(state, next, overlays)
    check deselected.packetClearsObjects()

  test "render skips corrupt sprites and objects that reference them":
    var game = initCtfForTest()
    discard game.addPlayer("red0")
    var overlays = newSeq[DebugOverlay](1)
    let corrupt = corruptSpritePacket(7).parseSpritePacket()[0].sprite
    overlays[0].sprites[7] = corrupt
    overlays[0].objects[9] = SpritePacketObject(
      id: 9, x: 10, y: 11, spriteId: 7
    )
    var validPacket: seq[uint8] = @[]
    validPacket.addSprite(8, 1, 1, [1'u8, 2, 3, 4], "valid")
    validPacket.addObject(10, 12, 13, 0, 0, 8)
    overlays[0].applyDebugSpritePacket(validPacket)

    var
      state = initGlobalViewerState()
      next: GlobalViewerState
    state.selectedJoinOrder = game.players[0].joinOrder
    let rendered = game.buildSpriteProtocolUpdates(state, next, overlays)
    check not rendered.packetHasSprite(debugSpriteId(0, 7))
    check rendered.packetObject(debugObjectId(0, 9)).id == -1
    check rendered.packetHasSprite(debugSpriteId(0, 8))
    check rendered.packetObject(debugObjectId(0, 10)).id ==
      debugObjectId(0, 10)

  test "drain drops oversized and malformed packets but records small packets":
    let path = getTempDir() / "ctf-debug-overlay-cap.bitreplay"
    defer:
      if fileExists(path):
        removeFile(path)
    var
      smallPacket: seq[uint8] = @[]
      corruptPacket = corruptSpritePacket(6)
      overlay: DebugOverlay
      state = initPlayerViewerState()
    smallPacket.addSprite(7, 1, 1, [1'u8, 2, 3, 4], "small")
    state.pendingDebugSprites = @[
      newSeq[uint8](MaxDebugSpriteBytesPerTick + 1),
      @[0xff'u8],
      corruptPacket,
      smallPacket
    ]
    var writer = openReplayWriter(path, "{}")
    state.drainPlayerDebugSprites(25'u32, 0, writer, overlay)
    writer.closeReplayWriter()

    let data = parseReplayBytes(readFile(path))
    check state.pendingDebugSprites.len == 0
    check state.debugSpriteLimitWarned
    check data.debugSprites.len == 1
    check data.debugSprites[0].packet == smallPacket
    check 6 notin overlay.sprites
    check overlay.sprites[7].label == "small"
