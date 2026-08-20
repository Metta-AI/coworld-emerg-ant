## Sim-state services shared by the roster machinery and the gameplay core:
## lobby status, spawn aim, team paint colors, game-event logging, the
## replay hash (gameHash/mixHash), walkability + spawn placement, the tier-2
## event sink (emitEvent), and flag reset. Stage 5 of
## docs/plans/2026-08-01-sim-split.md; re-exported by sim.nim.

import
  std/[random, strutils],
  bitworld/spriteprotocol, pixie,
  sim_types, arena, sim_config

proc lobbyIsStarting*(sim: SimServer): bool =
  ## Returns whether the lobby is in the start countdown.
  sim.players.len >= sim.config.minPlayers

proc lobbyStartTicksRemaining*(sim: SimServer): int =
  ## Returns ticks left before the lobby starts the game.
  if not sim.lobbyIsStarting() or sim.config.startWaitTicks <= 0:
    return 0
  if sim.startWaitTimer > 0:
    sim.startWaitTimer
  else:
    sim.config.startWaitTicks

proc lobbyStartSecondsRemaining*(sim: SimServer): int =
  ## Returns visible seconds left before the lobby starts the game.
  let ticks = sim.lobbyStartTicksRemaining()
  if ticks <= 0:
    return 0
  max(1, (ticks + TargetFps - 1) div TargetFps)

proc spawnAimBrads*(gameMap: CtfMap, team: Team): int =
  ## Returns the spawn/respawn aim angle: toward the map center, so every
  ## team wakes facing the fight. Sides maps keep the classic east/west pair;
  ## corner teams face the diagonal, plus arms face along their arm.
  ##
  ## The table keys on layout + team only, and that already serves BOTH
  ## 4-team symmetries: the corner aims are exactly the reflections of Red's
  ## south-east (Blue = its x-mirror SW, Green = its y-mirror NE, Yellow =
  ## its rot180 NW), which is what quad-mirror demands, and they equal the
  ## rot90 quarter turns of it too. Plus aims point along each arm either way.
  case gameMap.layout
  of layoutSides:
    if team == Red:
      0                        ## east, toward Blue.
    else:
      AimBradsTurn div 2       ## west, toward Red.
  of layoutCorners:
    ## 0 = east, counter-clockwise: SE 224, SW 160, NE 32, NW 96.
    case team
    of Red:
      AimBradsTurn - AimBradsTurn div 8      ## top-left faces south-east.
    of Blue:
      AimBradsTurn div 2 + AimBradsTurn div 8  ## top-right faces south-west.
    of Green:
      AimBradsTurn div 8                     ## bottom-left faces north-east.
    of Yellow:
      AimBradsTurn div 2 - AimBradsTurn div 8  ## bottom-right faces north-west.
  of layoutPlus:
    case team
    of Red:
      0                        ## west arm faces east.
    of Blue:
      AimBradsTurn div 2       ## east arm faces west.
    of Green:
      3 * AimBradsTurn div 4   ## north arm faces south.
    of Yellow:
      AimBradsTurn div 4       ## south arm faces north.

proc spawnFlipH*(gameMap: CtfMap, team: Team): bool =
  ## Returns whether a team's sprite spawns horizontally flipped: any spawn
  ## aim with a westward component faces the body left. Exactly `team ==
  ## Blue` on sides maps.
  let brads = gameMap.spawnAimBrads(team)
  brads > AimBradsTurn div 4 and brads < 3 * AimBradsTurn div 4

proc teamPaintRgba*(color: uint8): ColorRGBA =
  ## Maps a sprite's palette team color to the TRUE team display color — the
  ## vivid hues the soldier art and endzone floors actually show — rather than
  ## the retro palette slot. Use this for any new true-color team art:
  ## `Palette[BlueTeamColor]` is a muted lavender (131,118,156) that matches the
  ## blue a viewer sees nowhere else on the board. A non-team color (an
  ## individual player slot) falls back to its palette entry.
  if color == RedTeamColor:
    RedEndzoneColor
  elif color == BlueTeamColor:
    BlueEndzoneColor
  elif color == GreenTeamColor:
    GreenEndzoneColor
  elif color == YellowTeamColor:
    YellowEndzoneColor
  else:
    Palette[color and 0x0f]


proc playerText*(sim: SimServer, playerIndex: int): string =
  ## Returns the readable player color for one player index.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return "unknown"
  playerColorText(sim.players[playerIndex].color)

proc logGameEvent*(sim: SimServer, text: string) =
  ## Writes one game event to stdout for Docker logs.
  if sim.gameEventLoggingEnabled:
    echo text

proc logLobbyWaiting*(sim: var SimServer) =
  ## Logs waiting-for-player state when it changes.
  let
    needed = max(0, sim.config.minPlayers - sim.players.len)
    players = sim.players.len
  if players == sim.lastLobbyPlayersLogged and
      needed == sim.lastLobbyNeededLogged:
    return
  sim.lastLobbyPlayersLogged = players
  sim.lastLobbyNeededLogged = needed
  sim.lastLobbySecondsLogged = -1
  sim.logGameEvent(
    "waiting for players: " & $players & "/" &
      $sim.config.minPlayers & ", need " & $needed & " more"
  )

proc logLobbyCountdown*(sim: var SimServer) =
  ## Logs the lobby countdown once per visible second.
  let seconds = sim.lobbyStartSecondsRemaining()
  if seconds <= 0 or seconds == sim.lastLobbySecondsLogged:
    return
  sim.lastLobbySecondsLogged = seconds
  sim.logGameEvent("game starting in " & $seconds)

proc mapIndex*(x, y: int): int {.inline.} =
  y * MapWidth + x

proc mixHash(hash: var uint64, value: uint64) =
  ## Mixes one integer into a deterministic FNV-1a hash.
  hash = hash xor value
  hash *= 1099511628211'u64

proc mixHashInt(hash: var uint64, value: int) =
  ## Mixes one signed integer into a deterministic hash.
  hash.mixHash(cast[uint64](int64(value)))

proc mixHashBool(hash: var uint64, value: bool) =
  ## Mixes one boolean into a deterministic hash.
  hash.mixHashInt(ord(value))

proc grenadeThrowerSlot*(
  sim: SimServer,
  grenade: AirborneGrenade
): int {.inline.} =
  grenade.throwerSlot

proc gameHash*(sim: SimServer): uint64 =
  ## Returns a deterministic hash of gameplay state.
  result = 14695981039346656037'u64
  result.mixHashInt(sim.tickCount)
  result.mixHashInt(ord(sim.phase))
  result.mixHashInt(ord(sim.winner))
  result.mixHashInt(sim.gameOverTimer)
  result.mixHashInt(sim.gameStartTick)
  result.mixHashInt(sim.startWaitTimer)
  result.mixHashBool(sim.timeLimitReached)
  # Mixed only once the barrage latches: a barrage-off game contributes
  # nothing here, while a latched barrage pins its start tick and launch
  # accumulator into every replay hash from that tick on.
  if sim.barrageStartTick >= 0:
    result.mixHashInt(sim.barrageStartTick)
    result.mixHashInt(sim.barrageAccum)
  result.mixHashBool(sim.isDraw)
  result.mixHashBool(sim.needsReregister)
  result.mixHashInt(sim.nextJoinOrder)
  for team in sim.teams():
    result.mixHashInt(sim.flags[team].x)
    result.mixHashInt(sim.flags[team].y)
    result.mixHashInt(sim.flags[team].carrier)
    result.mixHashBool(sim.flags[team].captured)
  if sim.config.isEmergAnt():
    for team in sim.teams():
      result.mixHashInt(sim.colonyFood[team])
      result.mixHashInt(sim.queenSlot[team])
    result.mixHashInt(sim.pheromones.len)
    for mark in sim.pheromones:
      result.mixHashInt(mark.x)
      result.mixHashInt(mark.y)
      result.mixHashInt(ord(mark.team))
      result.mixHashInt(mark.tick)
      result.mixHashBool(mark.food)
  result.mixHashInt(sim.players.len)
  for player in sim.players:
    result.mixHashInt(player.x)
    result.mixHashInt(player.y)
    result.mixHashInt(player.homeX)
    result.mixHashInt(player.homeY)
    result.mixHashInt(player.velX)
    result.mixHashInt(player.velY)
    result.mixHashInt(player.carryX)
    result.mixHashInt(player.carryY)
    result.mixHashBool(player.flipH)
    result.mixHashInt(player.aimBrads)
    result.mixHashInt(ord(player.team))
    result.mixHashBool(player.alive)
    result.mixHashInt(player.lives)
    result.mixHashInt(player.hp)
    result.mixHashInt(player.respawnTimer)
    result.mixHashInt(player.fireCooldown)
    result.mixHashInt(player.fireWindup)
    result.mixHashInt(player.windupBrads)
    result.mixHashBool(player.carryingFlag)
    result.mixHashBool(player.hasGrenade)
    result.mixHashBool(player.hasShield)
    result.mixHashInt(player.shieldHp)
    result.mixHashBool(player.hasPlasmaArc)
    result.mixHashInt(player.arcTicksLeft)
    result.mixHashInt(player.arcAimBrads)
    # A 32-seat board can set bit 31 of the arc-hit mask; converting through
    # `int` overflows on wasm32 (same class as the color fix below). Widening
    # to uint64 hashes the identical value on both 32- and 64-bit targets.
    result.mixHash(uint64(player.arcHitMask))
    result.mixHashInt(player.throwCharge)
    result.mixHashInt(player.lastShoutTick)
    result.mixHashInt(player.joinOrder)
    # Color is an unsigned packed RGBA value. Converting it through `int`
    # overflows on wasm32 for colors with the high bit set; widening directly
    # preserves the native replay hash on both 32- and 64-bit targets.
    result.mixHash(uint64(player.color))
    result.mixHashInt(player.reward)
    result.mixHashInt(player.kills)
    result.mixHashInt(player.deaths)
    result.mixHashInt(player.captures)
  for spawn in sim.grenadeSpawns:
    result.mixHashBool(spawn.present)
    result.mixHashInt(spawn.respawnAt)
  for spawn in sim.medKitSpawns:
    result.mixHashBool(spawn.present)
    result.mixHashInt(spawn.respawnAt)
  for spawn in sim.shieldSpawns:
    result.mixHashBool(spawn.present)
    result.mixHashInt(spawn.respawnAt)
  for spawn in sim.plasmaArcSpawns:
    result.mixHashBool(spawn.present)
    result.mixHashInt(spawn.respawnAt)
  result.mixHashInt(sim.airborneGrenades.len)
  for grenade in sim.airborneGrenades:
    result.mixHashInt(grenade.sx)
    result.mixHashInt(grenade.sy)
    result.mixHashInt(grenade.tx)
    result.mixHashInt(grenade.ty)
    result.mixHashInt(grenade.launchTick)
    result.mixHashInt(grenade.flightTicks)
    result.mixHashInt(grenade.thrower)
  result.mixHashInt(sim.recentShouts.len)
  for shout in sim.recentShouts:
    for c in shout.address:
      result.mixHashInt(ord(c))
    result.mixHashInt(ord(shout.team))
    for c in shout.text:
      result.mixHashInt(ord(c))
    result.mixHashInt(shout.tick)
    result.mixHashInt(shout.x)
    result.mixHashInt(shout.y)

proc isWalkable*(sim: SimServer, x, y: int): bool =
  if x < 0 or y < 0 or x >= MapWidth or y >= MapHeight:
    return false
  sim.walkMask[mapIndex(x, y)]

proc canOccupy*(sim: SimServer, x, y: int): bool =
  ## True when the player's solid footprint, a box of half-extent PlayerHalf
  ## centered on (x, y), fits entirely on walkable floor.
  for dy in -PlayerHalf .. PlayerHalf:
    for dx in -PlayerHalf .. PlayerHalf:
      if not sim.isWalkable(x + dx, y + dy):
        return false
  true

proc nearestWalkable*(sim: SimServer, x, y: int): tuple[x, y: int] =
  ## Returns the nearest walkable cell to a point via expanding ring search.
  if sim.canOccupy(x, y):
    return (x, y)
  for r in 1 .. max(MapWidth, MapHeight):
    for dy in -r .. r:
      for dx in -r .. r:
        if abs(dx) != r and abs(dy) != r:
          continue
        let
          nx = x + dx
          ny = y + dy
        if sim.canOccupy(nx, ny):
          return (nx, ny)
  (x, y)

proc spawnPosition*(sim: SimServer, team: Team, order: int): tuple[x, y: int] =
  ## Returns a deterministic spawn position just inside a team's home edge:
  ## players stagger along the edge, perpendicular to their home axis (down
  ## the side for east/west teams, across for the plus layout's north/south
  ## arms).
  let
    anchor = sim.gameMap.teamAnchor(team)
    strip = order div 2          ## stagger players down the edge.
    spread = 36
    stepMajor = (strip - 1) * spread
    stepMinor = (if order mod 2 == 0: -6 else: 6)
    vertical = sim.gameMap.layout != layoutPlus or team in {Red, Blue}
    targetX = if vertical: anchor.x + stepMinor else: anchor.x + stepMajor
    targetY = if vertical: anchor.y + stepMajor else: anchor.y + stepMinor
  sim.nearestWalkable(targetX, targetY)

proc captureZone*(sim: SimServer, team: Team): CaptureZone =
  ## Returns one team's home capture zone on the installed map.
  sim.gameMap.captureZone(team)

proc randomEndzonePosition*(sim: var SimServer, team: Team):
    tuple[x, y: int] =
  ## Returns a random walkable position inside a team's endzone (the home
  ## capture zone), drawn from the deterministic sim RNG.
  let
    zone = sim.captureZone(team)
    inset = ArenaBorder + PlayerHalf
    xLo = max(zone.xLo, inset)
    xHi = min(zone.xHi, MapWidth - 1 - inset)
    yLo = max(zone.yLo, inset)
    yHi = min(zone.yHi, MapHeight - 1 - inset)
  var
    x = xLo + sim.rng.rand(xHi - xLo)
    y = yLo + sim.rng.rand(yHi - yLo)
  if zone.diag or zone.disc:
    ## A diagonal corner zone fills half its bounding box and a round
    ## compact zone about three quarters of it: redraw until the point falls
    ## inside (deterministic — pure rng sequence), with the anchor as a
    ## guaranteed landing spot if the draws run cold.
    var attempts = 0
    while not zone.inCaptureZone(x, y) and attempts < 16:
      x = xLo + sim.rng.rand(xHi - xLo)
      y = yLo + sim.rng.rand(yHi - yLo)
      inc attempts
    if not zone.inCaptureZone(x, y):
      let anchor = sim.gameMap.teamAnchor(team)
      x = anchor.x
      y = anchor.y
  sim.nearestWalkable(x, y)

proc placePlayer*(sim: var SimServer, playerIndex, x, y: int) =
  ## Moves one player to (x, y) with all motion state cleared.
  sim.players[playerIndex].x = x
  sim.players[playerIndex].y = y
  sim.players[playerIndex].velX = 0
  sim.players[playerIndex].velY = 0
  sim.players[playerIndex].carryX = 0
  sim.players[playerIndex].carryY = 0

proc resetPlayerToHome*(sim: var SimServer, playerIndex: int) =
  ## Moves one player back to its team home spawn position.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  sim.placePlayer(playerIndex,
    sim.players[playerIndex].homeX, sim.players[playerIndex].homeY)

proc arrangeHomePositions*(sim: var SimServer) =
  ## Saves and applies team home spawn positions for all players.
  var teamOrder: array[Team, int]
  for i in 0 ..< sim.players.len:
    let team = sim.players[i].team
    let spawn = sim.spawnPosition(team, teamOrder[team])
    inc teamOrder[team]
    sim.players[i].homeX = spawn.x
    sim.players[i].homeY = spawn.y
    sim.resetPlayerToHome(i)

proc eventSlot*(sim: SimServer, playerIndex: int): int {.inline.} =
  ## Returns a player's stable join slot for the tier-2 event stream, so an
  ## event survives roster changes; -1 for no/invalid player.
  if playerIndex >= 0 and playerIndex < sim.players.len:
    return sim.players[playerIndex].joinOrder
  -1

type EventActionKind* = enum
  GunAction
  GrenadeAction
  SprayAction

proc eventActionId*(
  sim: SimServer,
  playerIndex: int,
  kind: EventActionKind,
  tick = -1
): int64 {.inline.} =
  ## Encodes game, tick, action kind, and immutable slot.
  let
    eventTick = if tick >= 0: tick else: sim.tickCount
    slot = max(0, sim.eventSlot(playerIndex))
  var gameOrdinal = 0
  for account in sim.rewardAccounts:
    for team in Team:
      gameOrdinal += account.games[team]
  (int64(gameOrdinal) shl 48) or
    (int64(eventTick) shl 16) or
    (int64(ord(kind) + 1) shl 8) or
    int64(slot and 0xff)

proc eventActionIdForSlot*(
  sim: SimServer,
  slot: int,
  kind: EventActionKind,
  tick: int
): int64 {.inline.} =
  var gameOrdinal = 0
  for account in sim.rewardAccounts:
    for team in Team:
      gameOrdinal += account.games[team]
  (int64(gameOrdinal) shl 48) or
    (int64(tick) shl 16) or
    (int64(ord(kind) + 1) shl 8) or
    int64(max(0, slot) and 0xff)

proc eventDamage*(
  sim: SimServer,
  playerIndex, amount, hp, blocked: int
): EventDamage {.inline.} =
  EventDamage(
    slot: sim.eventSlot(playerIndex),
    amount: amount,
    hp: hp,
    blocked: blocked
  )

proc emitEvent*(
  sim: var SimServer,
  kind: SimEventKind,
  source = -1,
  target = -1,
  weapon = "",
  amount = 0,
  hp = -1,
  blocked = 0,
  x = 0.0,
  y = 0.0,
  actionId = 0'i64,
  headingBrads = -1,
  distance = 0.0,
  item = "",
  content = "",
  damages: seq[EventDamage] = @[],
  sourceSlot = -1,
  targetSlot = -1
) {.inline.} =
  ## Appends one tier-2 analysis event (see SimEvent); a no-op unless
  ## collectEvents is on, so live servers pay nothing. `source` and `target`
  ## are PLAYER INDICES here; they are recorded as stable join slots.
  if not sim.collectEvents:
    return
  sim.events.add SimEvent(
    tick: sim.tickCount,
    kind: kind,
    source: (if sourceSlot >= 0: sourceSlot else: sim.eventSlot(source)),
    target: (if targetSlot >= 0: targetSlot else: sim.eventSlot(target)),
    weapon: weapon,
    amount: amount,
    hp: hp,
    blocked: blocked,
    x: x,
    y: y,
    actionId: actionId,
    headingBrads: headingBrads,
    distance: distance,
    item: item,
    content: content,
    damages: damages
  )

proc emitPhaseChange*(sim: var SimServer, newPhase: GamePhase) {.inline.} =
  ## Appends one PhaseChange analysis event for a phase about to be entered
  ## (call BEFORE assigning sim.phase, with the phase being switched to).
  ## A no-op unless collectEvents is on.
  if not sim.collectEvents:
    return
  sim.emitEvent(
    PhaseChange,
    weapon = ($newPhase).toLowerAscii,
    amount = ord(newPhase)
  )

proc emitPickup*(
  sim: var SimServer,
  playerIndex: int,
  item: string,
  x, y: int
) {.inline.} =
  sim.emitEvent(
    Pickup,
    source = playerIndex,
    x = float(x),
    y = float(y),
    item = item
  )

proc foragePositionClear(sim: SimServer, x, y: int, slot: Team): bool =
  ## Whether a neutral Emerg-ant food patch may appear at this point. Food is
  ## field state, never a nest fixture: it must fit an ant footprint on floor,
  ## stay outside every capture zone and nest halo, and not overlap another
  ## loose patch or a living ant.
  if not sim.canOccupy(x, y):
    return false
  for team in sim.teams():
    let
      zone = sim.captureZone(team)
      nest = sim.gameMap.flagHome(team)
    if zone.inCaptureZone(x, y) or
        distSq(x, y, nest.x, nest.y) < FoodSpawnNestClear * FoodSpawnNestClear:
      return false
  for team in sim.teams():
    if team == slot:
      continue
    let other = sim.flags[team]
    if other.carrier < 0 and not other.captured and
        distSq(x, y, other.x, other.y) <
          FoodSpawnSeparation * FoodSpawnSeparation:
      return false
  for player in sim.players:
    if player.alive and
        max(abs(x - player.x), abs(y - player.y)) <=
          ContactAttackRange + FoodPickupRange:
      return false
  true

proc randomForagePosition*(sim: var SimServer, slot: Team): tuple[x, y: int] =
  ## Draws a deterministic random field position for one food slot. The slots
  ## are implementation identities only: every patch is neutral and either
  ## colony may collect it. A complete scan fallback makes placement total on
  ## hand-authored maps even if the bounded random draws are unlucky.
  let
    xLo = FoodSpawnMargin
    xHi = MapWidth - 1 - FoodSpawnMargin
    yLo = FoodSpawnMargin
    yHi = MapHeight - 1 - FoodSpawnMargin
  for _ in 0 ..< FoodSpawnAttempts:
    let
      x = xLo + sim.rng.rand(max(0, xHi - xLo))
      y = yLo + sim.rng.rand(max(0, yHi - yLo))
    if sim.foragePositionClear(x, y, slot):
      return (x, y)
  # Team ordinal rotates the deterministic scan start so multiple fallback
  # slots do not all ask for the same first cell.
  let span = max(1, (xHi - xLo + 1) * (yHi - yLo + 1))
  let start = ord(slot) * 104729 mod span
  for offset in 0 ..< span:
    let
      flat = (start + offset) mod span
      x = xLo + flat mod (xHi - xLo + 1)
      y = yLo + flat div (xHi - xLo + 1)
    if sim.foragePositionClear(x, y, slot):
      return (x, y)
  # Every shipped map has ample validated field floor. Preserve a total return
  # for malformed test maps without inventing an out-of-bounds position.
  sim.nearestWalkable(sim.gameMap.center.x, sim.gameMap.center.y)

proc resetFlag*(sim: var SimServer, team: Team) =
  ## Returns one CTF flag home, or respawns one neutral Emerg-ant food patch
  ## at a fresh field position.
  # A flag leaving an enemy's back mid-game (death, disconnect — any reason
  # other than capture) is a FlagReturn analysis event; the pedestal resets
  # at game boundaries are not (phase guard).
  if sim.collectEvents and sim.phase == Playing and sim.flags[team].carrier >= 0:
    sim.emitEvent(
      FlagReturn,
      source = sim.flags[team].carrier,
      x = float(sim.flags[team].x),
      y = float(sim.flags[team].y)
    )
  if sim.config.isEmergAnt():
    let food = sim.randomForagePosition(team)
    sim.flags[team] = FlagState(x: food.x, y: food.y, carrier: -1)
  else:
    let home = sim.gameMap.flagHome(team)
    sim.flags[team] = FlagState(x: home.x, y: home.y, carrier: -1)

proc resetFlags*(sim: var SimServer) =
  ## Resets every active objective. Inactive slots
  ## hold an explicit no-carrier state so nothing can misread the array's
  ## zero value (carrier 0 would mean "player 0 carries it").
  for team in Team:
    if team in sim.teams():
      sim.resetFlag(team)
    else:
      sim.flags[team] = FlagState(x: 0, y: 0, carrier: -1)
