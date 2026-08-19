## Lobby join-timeout budget (league no-show attribution).
##
## A finite match with lobbyJoinTimeoutTicks set must trip lobbyJoinTimedOut
## once the roster has been short for that many LOBBY ticks — and joins are
## strictly slot-sequential, so at the trip the stuck seat is exactly
## nextPlayerSlot(). Default (0) and infinite-lobby (maxGames 0) shapes must
## never trip, and the budget clock must not run while the roster is full.

import std/[json, os], bitworld/spriteprotocol, ctf/sim, helpers

proc lobbySim(configPatch: string): SimServer =
  ## Initializes a lobby-phase sim from a patched default config (cwd pinned
  ## to the game dir so data/ resolves, matching test_ctf_game).
  var config = defaultGameConfig()
  config.update(configPatch)
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

const NoInput: seq[InputState] = @[]

proc testDefaultOffNeverTrips() =
  ## Tests that the default config (timeout 0) waits forever.
  var sim = lobbySim("""{"minPlayers": 2, "maxGames": 1}""")
  discard sim.addPlayer("red0")
  for _ in 0 ..< 500:
    sim.step(NoInput, NoInput)
  doAssert not sim.lobbyJoinTimedOut()
  doAssert sim.lobbyWaitTimer == 0

proc testInfiniteLobbyNeverTrips() =
  ## Tests that casual (maxGames 0) lobbies ignore the budget entirely.
  var sim = lobbySim("""{"minPlayers": 2, "maxGames": 0, "lobbyJoinTimeoutTicks": 10}""")
  discard sim.addPlayer("red0")
  for _ in 0 ..< 50:
    sim.step(NoInput, NoInput)
  doAssert not sim.lobbyJoinTimedOut()

proc testTimeoutTripsAndNamesStuckSlot() =
  ## Tests the trip after exactly the budgeted short-roster lobby ticks, and
  ## that the stuck seat is the next sequential join slot.
  var sim = lobbySim("""{"minPlayers": 2, "maxGames": 1, "lobbyJoinTimeoutTicks": 12}""")
  discard sim.addPlayer("red0")
  for _ in 0 ..< 11:
    sim.step(NoInput, NoInput)
  doAssert not sim.lobbyJoinTimedOut()
  sim.step(NoInput, NoInput)
  doAssert sim.lobbyJoinTimedOut()
  doAssert sim.nextPlayerSlot() == 1

proc testFullRosterDoesNotBurnBudget() =
  ## Tests that lobby ticks with a full roster leave the budget untouched
  ## (the start countdown is not join-waiting).
  var sim = lobbySim(
    """{"minPlayers": 2, "maxGames": 1, "lobbyJoinTimeoutTicks": 12, "startWaitTicks": 1000}"""
  )
  discard sim.addPlayer("red0")
  discard sim.addPlayer("blue0")
  for _ in 0 ..< 40:
    sim.step(NoInput, NoInput)
  doAssert sim.lobbyWaitTimer == 0
  doAssert not sim.lobbyJoinTimedOut()

proc testConfigEcho() =
  ## Tests that the field round-trips the config echo and validates.
  var config = defaultGameConfig()
  doAssert config.lobbyJoinTimeoutTicks == 0
  config.update("""{"lobbyJoinTimeoutTicks": 2880}""")
  doAssert config.lobbyJoinTimeoutTicks == 2880
  doAssert parseJson(config.configJson())["lobbyJoinTimeoutTicks"].getInt() == 2880
  var bad = false
  try:
    config.update("""{"lobbyJoinTimeoutTicks": -1}""")
  except CtfError:
    bad = true
  doAssert bad

echo "Testing lobby join timeout"
testDefaultOffNeverTrips()
testInfiniteLobbyNeverTrips()
testTimeoutTripsAndNamesStuckSlot()
testFullRosterDoesNotBurnBudget()
testConfigEcho()
echo "ok"
