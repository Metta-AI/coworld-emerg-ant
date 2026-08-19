import
  std/[os, strutils, tables, unittest],
  bitworld/spriteprotocol,
  ctf/[global, sim]

# FX pool capacity at the 32-player limit.
#
# The spectator render draws every combat-FX family from a fixed object pool
# and clamps with `min(list.len, cap)` — an over-cap effect is not an error,
# it just silently never reaches the wire. The pools were sized for the old
# 16-player maximum, so a full 32-seat episode (paintbot 4ffa8 seats 32)
# dropped half its tracers/flashes/shouts in the worst tick. These tests
# drive every family the roster can saturate to exactly MaxPlayers live
# effects at once and count the objects that actually land in the packet:
# each family must emit all MaxPlayers, none clamped. Object ids are private
# pool constants, so families are counted by their sprite-label contract,
# like the shout tests do.

const GameDir = currentSourcePath.parentDir.parentDir

proc initCtfForTest(config: GameConfig): SimServer =
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc fullRosterGame(): SimServer =
  ## A started game with the maximum roster seated.
  var config = defaultGameConfig()
  result = initCtfForTest(config)
  for i in 0 ..< MaxPlayers:
    discard result.addPlayer("p" & $i)
  result.startGame()

proc labelCounts(
  sim: var SimServer,
  packets: openArray[seq[uint8]]
): CountTable[string] =
  ## Counts drawn OBJECTS per sprite-label family prefix (first two words),
  ## applying packets in order with client semantics (defs before objects).
  var labels: Table[int, string]
  for packet in packets:
    for message in packet.parseSpritePacket():
      case message.kind
      of spkSprite:
        labels[message.sprite.id] = message.sprite.label
      of spkObject:
        let label = labels.getOrDefault(message.objectDef.spriteId, "")
        let words = label.split(' ')
        if words.len >= 2:
          result.inc(words[0] & " " & words[1])
      else:
        discard

proc boardPacket(sim: var SimServer, state: var GlobalViewerState): seq[uint8] =
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    var nextState: GlobalViewerState
    result = sim.buildSpriteProtocolUpdates(state, nextState)
    state = nextState
  finally:
    setCurrentDir(previousDir)

suite "combat FX pools hold a full 32-player roster":
  test "every shooter-scaled family draws all MaxPlayers effects at once":
    var game = fullRosterGame()
    check game.players.len == MaxPlayers
    let tick = game.tickCount
    for i in 0 ..< MaxPlayers:
      # One live tracer + struck-victim flash + damage pop per seat, spread
      # mid-arena so nothing clips a map edge.
      let
        x0 = 100 + (i div 8) * 200
        y0 = 100 + (i mod 8) * 60
      game.recentShots.add ShotFx(
        x0: x0, y0: y0, x1: x0 + 250, y1: y0,
        firedTick: tick, color: teamColor(game.players[i].team), hit: true)
      game.hitFlashes.add HitFlashFx(playerIndex: i, tick: tick)
      game.damagePops.add DamageFx(
        x: x0, y: y0, tick: tick, amount: 1,
        color: teamColor(game.players[i].team))
      # One live speech bubble per seat (applyShout enforces one per player).
      check game.applyShout(i, "go " & $i)
    var state = initGlobalViewerState()
    var counts = game.labelCounts([game.boardPacket(state)])
    # Every family must land one object per seat — the old 16-wide pools
    # clamped each of these to half the roster.
    check counts["muzzle bloom"] == MaxPlayers
    check counts["shot head"] == MaxPlayers
    check counts["hit flash"] == MaxPlayers
    check counts["damage pop"] == MaxPlayers
    var shoutObjects = 0
    for label, n in counts:
      if label.endsWith(" shout"):        # "<slot> shout: <text>" families
        shoutObjects += n
    check shoutObjects == MaxPlayers

  test "a player view receives every shot's impact ring":
    var game = fullRosterGame()
    let tick = game.tickCount
    for i in 0 ..< MaxPlayers:
      let
        x0 = 100 + (i div 8) * 200
        y0 = 100 + (i mod 8) * 60
      game.recentShots.add ShotFx(
        x0: x0, y0: y0, x1: x0 + 250, y1: y0,
        firedTick: tick, color: teamColor(game.players[i].team), hit: false)
    var
      state: PlayerViewerState
      nextState: PlayerViewerState
    let previousDir = getCurrentDir()
    setCurrentDir(GameDir)
    var packet: seq[uint8]
    try:
      packet = game.buildSpriteProtocolPlayerUpdates(0, state, nextState)
    finally:
      setCurrentDir(previousDir)
    let counts = game.labelCounts([packet])
    check counts["shot impact"] == MaxPlayers
