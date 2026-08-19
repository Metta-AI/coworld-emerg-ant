## Transport-free CTF lifecycle used by the native parity test and Wasm component.

import
  std/json,
  bitworld/spriteprotocol,
  ctf/[global, replays, sim]

type
  SeatMessage* = object
    seat*: int
    payload*: string

  ArenaStep* = object
    messages*: seq[SeatMessage]
    done*: bool

  ArenaGame* = object
    sim*: SimServer
    viewers: seq[PlayerViewerState]
    inputMasks: seq[uint8]
    pressedMasks: seq[uint8]
    previousInputs: seq[InputState]
    lastReplayMasks: seq[uint8]
    replayChunks: seq[string]
    hashes*: seq[uint64]
    finished: bool

proc addU16(bytes: var string, value: uint16) =
  bytes.add(char(value and 0xff'u16))
  bytes.add(char(value shr 8))

proc addU32(bytes: var string, value: uint32) =
  for shift in countup(0, 24, 8):
    bytes.add(char((value shr shift) and 0xff'u32))

proc addU64(bytes: var string, value: uint64) =
  for shift in countup(0, 56, 8):
    bytes.add(char((value shr shift) and 0xff'u64))

proc addReplayString(bytes: var string, value: string) =
  if value.len > high(uint16).int:
    raise newException(CtfError, "Replay string is too long.")
  bytes.addU16(uint16(value.len))
  bytes.add(value)

proc replayHeader(configJson: string): string =
  ## The file-backed writer cannot stream bytes to a component import, so this
  ## mirrors its format. A zero timestamp keeps identical runs byte-stable.
  result = "COWLDCTF"
  result.addU16(1)
  result.addReplayString(GameName)
  result.addReplayString(GameVersion)
  result.addU64(0)
  result.addReplayString(configJson)

proc replayJoin(time: uint32, seat: int, name: string): string =
  result.add(char(ReplayJoinRecord))
  result.addU32(time)
  result.add(char(seat))
  result.addReplayString(name)
  result.addU16(cast[uint16](int16(seat)))
  result.addReplayString("")

proc replayInput(time: uint32, seat: int, mask: uint8): string =
  result.add(char(ReplayInputRecord))
  result.addU32(time)
  result.add(char(seat))
  result.add(char(mask))

proc replayChat(time: uint32, seat: int, message: string): string =
  result.add(char(ReplayChatRecord))
  result.addU32(time)
  result.add(char(seat))
  result.addReplayString(message)

proc replayHash(tick: int, hash: uint64): string =
  result.add(char(ReplayTickHashRecord))
  result.addU32(uint32(tick))
  result.addU64(hash)

proc clearPressed(input: var InputState, mask: uint8) =
  if (mask and ButtonUp) != 0: input.up = false
  if (mask and ButtonDown) != 0: input.down = false
  if (mask and ButtonLeft) != 0: input.left = false
  if (mask and ButtonRight) != 0: input.right = false
  if (mask and ButtonSelect) != 0: input.select = false
  if (mask and ButtonA) != 0: input.attack = false
  if (mask and ButtonB) != 0: input.b = false
  if (mask and ButtonC) != 0: input.c = false

proc recordInput(game: var ArenaGame, seat: int, applied, pressed: uint8) =
  let time = tickTime(game.sim.tickCount)
  let repeated = pressed and game.lastReplayMasks[seat]
  if repeated != 0:
    let released = game.lastReplayMasks[seat] and not repeated
    game.replayChunks.add(replayInput(time, seat, released))
    game.lastReplayMasks[seat] = released
  if game.lastReplayMasks[seat] != applied:
    game.replayChunks.add(replayInput(time, seat, applied))
    game.lastReplayMasks[seat] = applied

proc initArenaGame*(configText: string, seats: int, seed: uint64): ArenaGame =
  if seats <= 0 or seats > MaxPlayers:
    raise newException(CtfError, "Arena seats must be between 1 and " & $MaxPlayers & ".")
  var
    config = defaultGameConfig()
    configNode =
      if configText.len == 0: newJObject()
      else: parseJson(configText)
  if configNode.kind != JObject:
    raise newException(CtfError, "Config must be a JSON object.")
  # Nim's int is 32-bit in wasm and 64-bit natively. Fold the WIT's u64 seed
  # identically so the two builds select the same simulation seed.
  configNode["seed"] = %int(seed and uint64(high(int32)))
  config.update($configNode)
  # Arena installs the complete roster synchronously, so there is no network
  # lobby to wait for. Keeping the transition as the first sim tick preserves
  # the canonical replay lifecycle instead of starting out of band.
  config.startWaitTicks = 0
  if config.closedRoster and config.slots.len != seats:
    raise newException(CtfError, "Arena seats must match the configured closed roster.")
  if config.slots.len > seats:
    raise newException(CtfError, "Arena seats cannot be smaller than the configured roster.")

  result.sim = initSimServer(config)
  result.viewers = newSeq[PlayerViewerState](seats)
  result.inputMasks = newSeq[uint8](seats)
  result.pressedMasks = newSeq[uint8](seats)
  result.previousInputs = newSeq[InputState](seats)
  result.lastReplayMasks = newSeq[uint8](seats)
  result.replayChunks.add(replayHeader(config.configJson()))
  for seat in 0 ..< seats:
    let name =
      if seat < config.slots.len and config.slots[seat].name.len > 0:
        config.slots[seat].name
      else:
        "player-" & $seat
    discard result.sim.addPlayer(name, seat, trusted = true)
    result.viewers[seat] = initPlayerViewerState()
    result.replayChunks.add(replayJoin(0, seat, name))

proc step*(game: var ArenaGame, actions: openArray[SeatMessage]): ArenaStep =
  if game.finished:
    raise newException(CtfError, "Arena game has already finished.")
  var chats = newSeq[string](game.viewers.len)
  for action in actions:
    if action.seat < 0 or action.seat >= game.viewers.len:
      raise newException(CtfError, "Arena action seat is outside the roster.")
    game.viewers[action.seat].applyPlayerViewerMessage(
      action.payload,
      game.inputMasks[action.seat],
      game.pressedMasks[action.seat],
      chats[action.seat]
    )

  var
    inputs = newSeq[InputState](game.viewers.len)
    previous = game.previousInputs
  for seat in 0 ..< game.viewers.len:
    let applied = game.inputMasks[seat] or game.pressedMasks[seat]
    inputs[seat] = decodeInputMask(applied)
    previous[seat].clearPressed(game.pressedMasks[seat])
    game.recordInput(seat, applied, game.pressedMasks[seat])
    game.pressedMasks[seat] = 0
    let shout = sanitizeShout(chats[seat])
    if shout.len > 0 and game.sim.applyShout(seat, shout):
      game.replayChunks.add(replayChat(tickTime(game.sim.tickCount), seat, shout))

  game.sim.step(inputs, previous)
  game.previousInputs = inputs
  let hash = game.sim.gameHash()
  game.hashes.add(hash)
  game.replayChunks.add(replayHash(game.sim.tickCount, hash))

  for seat in 0 ..< game.viewers.len:
    var nextState: PlayerViewerState
    let packet = game.sim.buildSpriteProtocolPlayerUpdates(
      seat,
      game.viewers[seat],
      nextState,
      spritesOff = true
    ).stripSpritePixels()
    game.viewers[seat] = nextState
    var payload = newString(packet.len)
    if packet.len > 0:
      copyMem(payload[0].addr, packet[0].unsafeAddr, packet.len)
    result.messages.add(SeatMessage(seat: seat, payload: payload))
  result.done = game.sim.phase == GameOver

proc finish*(game: var ArenaGame): string =
  if game.finished:
    raise newException(CtfError, "Arena game finish was already called.")
  if game.sim.phase != GameOver:
    raise newException(CtfError, "Arena game cannot finish before game over.")
  game.finished = true
  game.sim.playerResultsJson()

proc takeReplayChunks*(game: var ArenaGame): seq[string] =
  result = move(game.replayChunks)
