import
  std/[json, os, unittest],
  ctf/[broadcast, sim]
import helpers except initCtfForTest

proc initCtfForTest(): SimServer =
  ## Initializes the CTF sim from the game directory.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(defaultGameConfig())
    result.gameEventLoggingEnabled = false
  finally:
    setCurrentDir(previousDir)

proc killEvents(events: JsonNode): seq[JsonNode] =
  for e in events:
    if e["k"].getStr == "kill":
      result.add e

suite "provable same-tick trade pairing":
  test "two players who kill only each other are paired into a linked trade":
    var game = initCtfForTest()
    let
      a = game.addPlayer("red0")
      b = game.addPlayer("blue0")
    game.startGame()
    game.players[a].team = Red
    game.players[b].team = Blue

    # Prime the tracker on the current state, then simulate a mutual same-tick
    # trade by bumping both players' kill AND death counters by one.
    var tracker = initBroadcastTracker()
    var warmup = newJArray()
    game.stepEvents(tracker, warmup)

    inc game.players[a].kills
    inc game.players[a].deaths
    inc game.players[b].kills
    inc game.players[b].deaths

    var events = newJArray()
    game.stepEvents(tracker, events)
    let kills = events.killEvents()
    check kills.len == 2
    # Both events stay honestly killer = -1 / ambiguous (parity with the
    # timeline tool), but each now carries its provable trade partner's slot.
    for e in kills:
      check e["killer"].getInt == -1
      check e["amb"].getBool == true
      check e.hasKey("trade")
    let
      slotA = game.players[a].joinOrder
      slotB = game.players[b].joinOrder
    # Each victim's trade partner is the OTHER player.
    for e in kills:
      if e["victim"].getInt == slotA:
        check e["trade"].getInt == slotB
      elif e["victim"].getInt == slotB:
        check e["trade"].getInt == slotA
      else:
        check false

  test "a 3-way pileup stays honestly ambiguous (no trade pairing)":
    var game = initCtfForTest()
    let
      a = game.addPlayer("red0")
      b = game.addPlayer("blue0")
      c = game.addPlayer("red1")
    game.startGame()
    game.players[a].team = Red
    game.players[b].team = Blue
    game.players[c].team = Red

    var tracker = initBroadcastTracker()
    var warmup = newJArray()
    game.stepEvents(tracker, warmup)

    # Three players die; only two scored kills — killers != victims, so the
    # pairing is NOT provable and must fall back to the ambiguous marker.
    inc game.players[a].kills
    inc game.players[a].deaths
    inc game.players[b].kills
    inc game.players[b].deaths
    inc game.players[c].deaths

    var events = newJArray()
    game.stepEvents(tracker, events)
    let kills = events.killEvents()
    check kills.len == 3
    for e in kills:
      check e["amb"].getBool == true
      check not e.hasKey("trade")

  test "two independent same-tick kills across the map are not a trade":
    var game = initCtfForTest()
    let
      a = game.addPlayer("red0")
      b = game.addPlayer("blue0")
      c = game.addPlayer("red1")
      d = game.addPlayer("blue1")
    game.startGame()
    game.players[a].team = Red
    game.players[b].team = Blue
    game.players[c].team = Red
    game.players[d].team = Blue

    var tracker = initBroadcastTracker()
    var warmup = newJArray()
    game.stepEvents(tracker, warmup)

    # A kills D, C kills B (killers {a,c} != victims {b,d}): not a mutual trade.
    inc game.players[a].kills
    inc game.players[c].kills
    inc game.players[b].deaths
    inc game.players[d].deaths

    var events = newJArray()
    game.stepEvents(tracker, events)
    let kills = events.killEvents()
    check kills.len == 2
    for e in kills:
      check e["amb"].getBool == true
      check not e.hasKey("trade")
