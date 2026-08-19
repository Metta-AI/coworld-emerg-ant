## Shared test helpers. These used to be copy-pasted per test module; the
## bodies here are byte-for-byte the common variants, so migrating a test onto
## this module must not change the game state it constructs.
##
## Tests run from the repo root (see AGENTS.md), but sim construction and
## sprite-packet building lazily load `data/` assets relative to the cwd — so
## the builders here pin the cwd to the game directory for the duration of the
## call, exactly like every local copy did.

import
  std/os,
  bitworld/spriteprotocol,
  ctf/[global, sim]

const GameDir* = currentSourcePath.parentDir.parentDir

proc initCtfForTest*(config = defaultGameConfig()): SimServer =
  ## Initializes the CTF sim from the game directory (so data/ resolves).
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc twoTeamGame*(collectEvents = false): SimServer =
  ## A started game with one Red player (0) and one Blue player (1). Pass
  ## `collectEvents = true` to turn the tier-2 event sink on.
  result = initCtfForTest(defaultGameConfig())
  discard result.addPlayer("red0")
  discard result.addPlayer("blue0")
  result.startGame()
  result.players[0].team = Red
  result.players[1].team = Blue
  result.collectEvents = collectEvents

proc namedGame*(seats: int): SimServer =
  ## `seats` players whose addresses are unmistakable inside a label and share
  ## no substring with the team colors or the slot letters. Seats alternate
  ## Red, Blue, Red, Blue... by slot order, as teamForSlot assigns them.
  result = initCtfForTest(defaultGameConfig())
  for i in 0 ..< seats:
    discard result.addPlayer("policy" & $i)
  result.startGame()

proc none*(sim: SimServer): seq[InputState] =
  ## An all-idle input frame sized to the roster.
  newSeq[InputState](sim.players.len)

proc chargeAndThrow*(sim: var SimServer, playerIndex, holdTicks: int) =
  ## Holds C for holdTicks then releases.
  var held = sim.none()
  held[playerIndex].c = true
  var prev = sim.none()
  for _ in 0 ..< holdTicks:
    sim.step(held, prev)
    prev = held
  sim.step(sim.none(), prev)

proc armToFire*(game: var SimServer, shooter: int) =
  ## Clears the gates so the shooter's next tryFire releases this tick.
  game.players[shooter].windupBrads = -1
  game.players[shooter].fireCooldown = 0

proc placeAtCenter*(player: var Player, x, y: int) =
  ## Centers a player's collision box on a map point.
  player.x = x - CollisionW div 2
  player.y = y - CollisionH div 2

proc segmentBlocked*(sim: SimServer, ax, ay, bx, by: int): bool =
  ## Returns true when a wall pixel blocks the straight segment between two
  ## map points (same stepping as the sim's line-of-sight routine).
  let
    dx = bx - ax
    dy = by - ay
    steps = max(abs(dx), abs(dy))
  for s in 1 .. steps:
    if sim.isWall(ax + dx * s div steps, ay + dy * s div steps):
      return true
  false

proc fovAt*(sim: SimServer, visible: seq[bool], x, y: int): bool =
  ## Reads one map point from a computed visibility grid.
  let (cx, cy) = fovCellAt(x, y)
  visible[fovCellIndex(cx, cy)]

proc blockAll*(sim: var SimServer) =
  ## Marks all map cells blocked for movement tests.
  for i in 0 ..< sim.walkMask.len:
    sim.walkMask[i] = false

proc openField*(sim: var SimServer, x0, y0, x1, y1: int) =
  ## Opens a rectangular block of walkable floor.
  for y in y0 .. y1:
    for x in x0 .. x1:
      sim.walkMask[mapIndex(x, y)] = true

proc placeStill*(sim: var SimServer, index, x, y: int) =
  ## Pins a player at a point with all motion state zeroed.
  sim.players[index].x = x
  sim.players[index].y = y
  sim.players[index].velX = 0
  sim.players[index].velY = 0
  sim.players[index].carryX = 0
  sim.players[index].carryY = 0

proc hasObject*(messages: openArray[SpritePacketMessage], objectId: int): bool =
  ## True when a sprite packet places the given object id.
  for message in messages:
    if message.kind == spkObject and message.objectDef.id == objectId:
      return true

proc buildGlobalMessages*(
  sim: var SimServer,
  state: var GlobalViewerState
): seq[SpritePacketMessage] =
  ## Builds and parses one global viewer sprite packet. Renders from the game
  ## directory so lazily-loaded sprite PNGs (hearts, shields) resolve.
  var nextState: GlobalViewerState
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = sim.buildSpriteProtocolUpdates(state, nextState).parseSpritePacket()
  finally:
    setCurrentDir(previousDir)
  state = nextState

proc buildPlayerMessages*(
  sim: var SimServer,
  playerIndex: int,
  state: var PlayerViewerState
): seq[SpritePacketMessage] =
  ## Builds and parses one sprite player packet, from the game directory.
  var nextState: PlayerViewerState
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = sim.buildSpriteProtocolPlayerUpdates(
      playerIndex, state, nextState).parseSpritePacket()
  finally:
    setCurrentDir(previousDir)
  state = nextState

proc playerMessages*(
  sim: var SimServer,
  playerIndex: int
): seq[SpritePacketMessage] =
  ## One player packet from throwaway viewer state (no state carried).
  var state, nextState: PlayerViewerState
  sim.buildSpriteProtocolPlayerUpdates(playerIndex, state, nextState)
    .parseSpritePacket()
