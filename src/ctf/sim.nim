## The deterministic gameplay core: movement/collision, combat, grenades,
## shouts, pickups, fog-of-war, endgame, and the per-tick step loop. Types,
## consts, map, art, config, state services and roster live in the sibling
## modules this file imports and re-exports (see
## docs/plans/2026-08-01-sim-split.md).
import
  std/[algorithm, json, math, os, random, strutils],
  bitworld/pixelfonts, bitworld/profile, bitworld/spriteprotocol,
  bitworld/server,
  pixie

import sim_types, rig_art, arena, map_art, sim_config, sim_state, roster
export sim_types, rig_art, arena, map_art, sim_config, sim_state, roster

proc grenadeSpawnPoints*(gameMap: CtfMap): array[4, tuple[x, y: int]] =
  ## The four grenade spawn points. Sides maps keep the classic corners;
  ## corner maps move them to the edge midpoints (the corners are endzones
  ## there); plus maps tuck them at the inner corners of the center
  ## intersection, clear of the four endzone arm mouths.
  let inset = ArenaBorder + GrenadeSpawnInset
  case gameMap.layout
  of layoutSides:
    [(inset, inset),
      (inset, gameMap.height - inset),
      (gameMap.width - inset, inset),
      (gameMap.width - inset, gameMap.height - inset)]
  of layoutCorners:
    if gameMap.symmetry == symQuadMirror:
      ## Quad-mirror's group is the reflections, so the set must be a Klein
      ## orbit. The rot90 edge-MIDPOINT seed degenerates there (its mirrorX
      ## image is itself, half a pixel off on an even width), so the seed
      ## slides to a third of the top edge: the orbit is four distinct
      ## points along the top and bottom edges, clear of the corner
      ## endzones, and exactly fair by construction.
      quadMirrorOrbit(
        (gameMap.width div 3, inset), gameMap.width, gameMap.height)
    else:
      rot90Orbit((gameMap.width div 2, inset), gameMap.width)
  of layoutPlus:
    let arm = gameMap.plusArmHalf()
    if gameMap.symmetry == symQuadMirror:
      ## The same four inner corners of the center intersection as rot90,
      ## built as the reflections of the bottom-right one — the group that
      ## actually completes this map.
      quadMirrorOrbit(
        (gameMap.center.x + arm - inset, gameMap.center.y + arm - inset),
        gameMap.width, gameMap.height)
    else:
      rot90Orbit(
        (gameMap.center.x + arm - inset, gameMap.center.y + arm - inset),
        gameMap.width
      )

proc teamOrbitPoints(gameMap: CtfMap, red: MapPoint): seq[tuple[x, y: int]] =
  ## Carries RED's chosen point to every active team by the map's own
  ## symmetry (`teamImagePoint`), so no team's pickup sits in terrain the
  ## others' don't get.
  for team in gameMap.teams():
    let point = gameMap.teamImagePoint(red, team)
    result.add((point.x, point.y))

proc explicitOrOrbit(
  gameMap: CtfMap, explicit: seq[MapPoint], red: MapPoint
): seq[tuple[x, y: int]] =
  ## symNone maps carry EXPLICIT per-team points (no orbit exists); every other
  ## symmetry derives each team's point from RED's via teamImagePoint. The
  ## loader has already validated the explicit set is present + well-formed for
  ## symNone, so here we trust it.
  if gameMap.symmetry == symNone:
    for p in explicit: result.add((p.x, p.y))
  else:
    result = gameMap.teamOrbitPoints(red)

proc shieldSpawnPoints*(gameMap: CtfMap): seq[tuple[x, y: int]] =
  ## One shield point per team, deep in that team's endzone. RED's spot is
  ## the only one chosen; every other team's is its image under the map's own
  ## symmetry (`teamImagePoint`), so no team's shield sits in terrain the
  ## others' don't get. Under symNone the points are authored explicitly.
  let
    inset = ArenaBorder + GrenadeSpawnInset
    red =
      if gameMap.endzone != ezColumn:
        ## A compact endzone has no back column to hide a pickup in: park it
        ## below the pedestal, inside the zone (protected floor, so always
        ## walkable and always connected) and clear of the pedestal art.
        let anchor = gameMap.teamAnchor(Red)
        MapPoint(x: anchor.x, y: anchor.y + 2 * gameMap.endzoneRadius div 3)
      else:
        case gameMap.layout
        of layoutSides:
          ## The classic back column, bottom half; the cans hold the top.
          MapPoint(x: inset, y: 3 * gameMap.height div 4)
        of layoutCorners:
          ## Red's own x edge at anchor height. Blue's copy is the quarter
          ## turn of that — the TOP edge — not the right edge a mirror picks.
          MapPoint(x: inset, y: gameMap.teamAnchor(Red).y)
        of layoutPlus:
          ## The lower half of Red's arm mouth. Anchoring each team's copy to
          ## the integer `center` instead lands it a pixel off the orbit,
          ## since the rot90 axis is at (side - 1)/2.
          MapPoint(x: inset, y: gameMap.center.y + gameMap.plusArmHalf() div 2)
  gameMap.explicitOrOrbit(gameMap.teamPickups.shields, red)

proc plasmaArcSpawnPoints*(gameMap: CtfMap): seq[tuple[x, y: int]] =
  ## One spray can point per team, built exactly like the shields: RED's spot
  ## carried to every other team by the map's own symmetry. Red's can is the
  ## opposite half of its endzone from Red's shield, so the two sets never
  ## collide.
  let
    inset = ArenaBorder + PlasmaArcSpawnInset
    red =
      if gameMap.endzone != ezColumn:
        ## The compact-endzone counterpart of the shield spot: same zone,
        ## other side of the pedestal (cans high, shields low).
        let anchor = gameMap.teamAnchor(Red)
        MapPoint(x: anchor.x, y: anchor.y - 2 * gameMap.endzoneRadius div 3)
      else:
        case gameMap.layout
        of layoutSides:
          MapPoint(x: inset, y: gameMap.height div 4)
        of layoutCorners:
          ## Red's shield spot reflected across the diagonal — its own y edge
          ## at anchor width — so the two orbits never share an edge spot.
          MapPoint(x: gameMap.teamAnchor(Red).x, y: inset)
        of layoutPlus:
          MapPoint(x: inset, y: gameMap.center.y - gameMap.plusArmHalf() div 2)
  gameMap.explicitOrOrbit(gameMap.teamPickups.cans, red)

proc barrierSpawnPoints*(gameMap: CtfMap, perTeam: int): seq[tuple[x, y: int]] =
  ## `perTeam` cardboard barrier pickup points per team (config-gated; empty
  ## by default). RED's spots are staged on the line from its anchor toward
  ## map center — the walk out of the base every attacker and defender makes —
  ## and every other team's are its images under the map's own symmetry
  ## (`teamImagePoint` via teamOrbitPoints), so no team's pickup sits in
  ## terrain the others' don't get. One spot lands at the midpoint; two
  ## split the line in thirds.
  if gameMap.symmetry == symNone:
    ## Explicit, team-major (perTeam per team). The LOADER only checked the
    ## count is a multiple of the team count and that each point is walkable —
    ## it does NOT know the config's `perTeam`. So verify HERE, where perTeam is
    ## known, that the spec carries EXACTLY perTeam * activeTeams points; a
    ## mismatch would otherwise silently give teams the wrong barrier count.
    let expected = perTeam * gameMap.layout.teamCount()
    if gameMap.teamPickups.barriers.len != expected:
      raise newException(CtfError,
        "symNone barrier pickups: config asks perTeam=" & $perTeam & " (" &
        $expected & " total for " & $gameMap.layout.teamCount() & " teams) but " &
        "the spec authored " & $gameMap.teamPickups.barriers.len & " points.")
    for p in gameMap.teamPickups.barriers: result.add((p.x, p.y))
    return
  let
    anchor = gameMap.teamAnchor(Red)
    center = gameMap.center
  for k in 0 ..< perTeam:
    let red = MapPoint(
      x: anchor.x + (center.x - anchor.x) * (k + 1) div (perTeam + 1),
      y: anchor.y + (center.y - anchor.y) * (k + 1) div (perTeam + 1)
    )
    result.add(gameMap.teamOrbitPoints(red))

template placeWalkablePickups(
  sim: var SimServer,
  spawnsField: untyped,
  targets: seq[tuple[x, y: int]]
) =
  ## Shared placement core for the nudged pickup families (med kits, shields,
  ## spray cans): sizes the spawn seq to the targets, nudges each target to
  ## the nearest walkable floor, and refills every spawn. (Grenade spawns
  ## keep their own placement — they are never nudged.)
  let targetsOnce = targets   # evaluate the expression once, not per use
  sim.spawnsField.setLen(targetsOnce.len)
  for i in 0 ..< sim.spawnsField.len:
    let spot = sim.nearestWalkable(targetsOnce[i].x, targetsOnce[i].y)
    sim.spawnsField[i] = PickupSpawn(
      x: spot.x, y: spot.y, present: true, respawnAt: 0
    )

proc resetGrenades*(sim: var SimServer) =
  ## Refills every corner pickup and clears carried and airborne grenades.
  let points = sim.gameMap.grenadeSpawnPoints()
  for i in 0 ..< sim.grenadeSpawns.len:
    sim.grenadeSpawns[i] = PickupSpawn(
      x: points[i].x, y: points[i].y, present: true, respawnAt: 0
    )
  sim.airborneGrenades = @[]
  for i in 0 ..< sim.players.len:
    sim.players[i].hasGrenade = false
    sim.players[i].throwCharge = 0

proc resetMedKits*(sim: var SimServer) =
  ## Places both med kits on the map's active spawn points (generated maps
  ## draw the pair per map; hand-authored maps carry the classic center-line
  ## thirds), nudged to the nearest walkable floor, and refills them.
  var targets: seq[tuple[x, y: int]]
  if sim.gameMap.medKitSpawns.len >= 2:
    for point in sim.gameMap.medKitSpawns:
      targets.add((point.x, point.y))
  else:
    targets = @[
      (MapWidth div 2, MapHeight div 3),
      (MapWidth div 2, 2 * MapHeight div 3),
    ]
  sim.placeWalkablePickups(medKitSpawns, targets)

proc resetShields*(sim: var SimServer) =
  ## Places one shield deep in each team's endzone, in the same back column
  ## as the corner grenade pickups but in the BOTTOM half (three quarters of
  ## the map height down) — the spray cans hold the matching top-half spots —
  ## nudged to the nearest walkable floor, and refills both.
  sim.placeWalkablePickups(shieldSpawns, sim.gameMap.shieldSpawnPoints())
  for i in 0 ..< sim.players.len:
    sim.players[i].hasShield = false
    sim.players[i].shieldHp = 0

proc resetPlasmaArcs*(sim: var SimServer) =
  ## Refills every team's spray can pickup and clears carried cans.
  sim.placeWalkablePickups(plasmaArcSpawns, sim.gameMap.plasmaArcSpawnPoints())
  sim.plasmaArcFlashes = @[]
  for i in 0 ..< sim.players.len:
    sim.players[i].hasPlasmaArc = false
    sim.players[i].arcTicksLeft = 0
    sim.players[i].arcAimBrads = -1
    sim.players[i].arcHitMask = 0

proc resetBarriers*(sim: var SimServer) =
  ## Places the config-gated barrier pickups (none by default), clears every
  ## standing barrier off the field, and empties every cog's hands of
  ## cardboard.
  sim.placeWalkablePickups(
    barrierSpawns,
    sim.gameMap.barrierSpawnPoints(sim.config.barrierPickups)
  )
  sim.placedBarriers = @[]
  for i in 0 ..< sim.players.len:
    sim.players[i].hasBarrier = false

proc queenIndex*(sim: SimServer, team: Team): int =
  ## The queen is the colony's first joined policy seat. This is derived from
  ## stable join order, so it requires no per-player wire field and survives
  ## replay joins/disconnect bookkeeping.
  result = -1
  if sim.config.isEmergAnt() and sim.queenFeedAt[team] > 0:
    for i, player in sim.players:
      if player.team == team and player.joinOrder == sim.queenSlot[team]:
        return i
    return -1
  var firstOrder = high(int)
  for i, player in sim.players:
    if player.team == team and player.joinOrder < firstOrder:
      firstOrder = player.joinOrder
      result = i

proc isQueen*(sim: SimServer, playerIndex: int): bool =
  playerIndex >= 0 and playerIndex < sim.players.len and
    sim.queenIndex(sim.players[playerIndex].team) == playerIndex

proc teamActiveAnts*(sim: SimServer, team: Team): int =
  for player in sim.players:
    if player.team == team and player.alive:
      inc result

proc startGame*(sim: var SimServer) =
  sim.logGameEvent("game started: players=" & $sim.players.len)
  sim.recentShots = @[]
  sim.hitFlashes = @[]
  sim.bubbleImpacts = @[]
  sim.splatters = @[]
  sim.paintStains = @[]        ## each match starts on a clean arena.
  sim.diamondStains = @[]
  sim.damagePops = @[]
  sim.pheromones = @[]
  sim.recentShouts = @[]
  sim.arrangeHomePositions()
  for team in sim.teams():
    let foundingQueen = sim.queenIndex(team)
    sim.queenSlot[team] =
      if foundingQueen >= 0: sim.players[foundingQueen].joinOrder else: -1
    sim.colonyFood[team] =
      if sim.config.isEmergAnt(): QueenStartingFood else: 0
    sim.queenFeedAt[team] =
      if sim.config.isEmergAnt(): sim.tickCount + QueenGraceTicks else: 0
  for i in 0 ..< sim.players.len:
    sim.players[i].lastShoutTick = -1
    var teamRank = 0
    for other in sim.players:
      if other.team == sim.players[i].team and
          other.joinOrder < sim.players[i].joinOrder:
        inc teamRank
    sim.players[i].alive =
      not sim.config.isEmergAnt() or teamRank < InitialAntsPerColony
    sim.players[i].lives =
      if sim.config.isEmergAnt(): 0
      else: sim.config.livesFor(sim.players[i].team)
    sim.players[i].hp =
      sim.config.maxHpFor(sim.players[i].team, sim.players[i].perks)
    sim.players[i].respawnTimer = 0
    sim.players[i].fireCooldown = 0
    sim.players[i].fireWindup = 0
    sim.players[i].windupBrads = -1
    sim.players[i].aimBrads = sim.gameMap.spawnAimBrads(sim.players[i].team)
    sim.players[i].flipH = sim.gameMap.spawnFlipH(sim.players[i].team)
    sim.players[i].carryingFlag = false
    sim.players[i].hasShield = false
    sim.players[i].shieldHp = 0
    sim.players[i].kills = 0
    sim.players[i].deaths = 0
    sim.players[i].captures = 0
    sim.players[i].shotsFired = 0
    sim.players[i].shotsHit = 0
    sim.players[i].multiKills2 = 0
    sim.players[i].multiKills3 = 0
    sim.players[i].teamKills = 0
    sim.players[i].arcKillsThisFire = 0
    if sim.config.isEmergAnt():
      # CrownSkin is reserved for the derived queen in ant mode; the distinct
      # sprite/label makes the colony's single point of failure observable.
      sim.players[i].skin = if sim.isQueen(i): CrownSkin else: DefaultSkin
    sim.recordGameTeamAssigned(i)
  sim.resetFlags()
  sim.resetGrenades()
  sim.resetShields()
  sim.resetPlasmaArcs()
  sim.resetBarriers()
  sim.emitPhaseChange(Playing)
  sim.phase = Playing
  sim.gameStartTick = sim.tickCount
  sim.timeLimitReached = false
  sim.barrageStartTick = -1
  sim.barrageAccum = 0
  sim.isDraw = false
  sim.lastLobbyPlayersLogged = -1
  sim.lastLobbyNeededLogged = -1
  sim.lastLobbySecondsLogged = -1

proc signOf(value: int): int {.inline.} =
  ## Returns the sign of one integer.
  if value < 0:
    return -1
  if value > 0:
    return 1
  0

proc slideScanRadius(sim: SimServer, carry, velocity: int): int =
  ## Returns the perpendicular scan radius for blocked movement.
  let
    pending = abs(carry) div sim.config.motionScale
    speed = (
      abs(velocity) + sim.config.motionScale - 1
    ) div sim.config.motionScale
  clamp(max(1, max(pending, speed)), 1, MovementSlideMaxScan)

proc playersOverlapAt(sim: SimServer, movingIndex, x, y: int): bool =
  ## True when a player footprint centered at (x, y) would overlap another
  ## live player's footprint.
  for i in 0 ..< sim.players.len:
    if i == movingIndex or not sim.players[i].alive:
      continue
    if max(abs(x - sim.players[i].x), abs(y - sim.players[i].y)) <=
        PlayerSolidSpan:
      return true
  false

proc blockingPlayerAt(
  sim: SimServer,
  movingIndex, fromX, fromY, toX, toY: int
): int =
  ## Returns the index of a live player whose body blocks this step, or -1.
  ## A step is blocked when it lands overlapping another body without
  ## increasing the separation — moving apart is always allowed, so bodies
  ## that start overlapped (a respawn onto an occupied home) can escape.
  for i in 0 ..< sim.players.len:
    if i == movingIndex or not sim.players[i].alive:
      continue
    let toDist =
      max(abs(toX - sim.players[i].x), abs(toY - sim.players[i].y))
    if toDist > PlayerSolidSpan:
      continue
    let fromDist =
      max(abs(fromX - sim.players[i].x), abs(fromY - sim.players[i].y))
    if toDist <= fromDist:
      return i
  -1

proc canSlideHorizontal(
  sim: SimServer,
  movingIndex, x, y, step, offset: int
): bool =
  ## Returns true when a horizontal step can slide by one offset.
  if offset == 0:
    return false
  let slideStep = signOf(offset)
  for i in 1 .. abs(offset):
    if not sim.canOccupy(x, y + slideStep * i) or
        sim.playersOverlapAt(movingIndex, x, y + slideStep * i):
      return false
  sim.canOccupy(x + step, y + offset) and
    not sim.playersOverlapAt(movingIndex, x + step, y + offset)

proc canSlideVertical(
  sim: SimServer,
  movingIndex, x, y, step, offset: int
): bool =
  ## Returns true when a vertical step can slide by one offset.
  if offset == 0:
    return false
  let slideStep = signOf(offset)
  for i in 1 .. abs(offset):
    if not sim.canOccupy(x + slideStep * i, y) or
        sim.playersOverlapAt(movingIndex, x + slideStep * i, y):
      return false
  sim.canOccupy(x + offset, y + step) and
    not sim.playersOverlapAt(movingIndex, x + offset, y + step)

proc trySlideOffset(
  sim: var SimServer,
  movingIndex, step, offset: int,
  horizontal: bool
): bool =
  ## Tries one candidate slide offset for a blocked movement step.
  template player: untyped = sim.players[movingIndex]
  if horizontal:
    if not sim.canSlideHorizontal(movingIndex, player.x, player.y, step, offset):
      return false
    player.x += step
    player.y += offset
  else:
    if not sim.canSlideVertical(movingIndex, player.x, player.y, step, offset):
      return false
    player.x += offset
    player.y += step
  true

proc trySlideMove(
  sim: var SimServer,
  movingIndex, step, radius, preferredSlide: int,
  horizontal: bool
): bool =
  ## Tries nearby slide offsets for one blocked movement step.
  if radius <= 0:
    return false
  let preferred = signOf(preferredSlide)
  for distance in 1 .. radius:
    if preferred != 0:
      if sim.trySlideOffset(
        movingIndex,
        step,
        preferred * distance,
        horizontal
      ):
        return true
      if sim.trySlideOffset(
        movingIndex,
        step,
        -preferred * distance,
        horizontal
      ):
        return true
    else:
      if sim.trySlideOffset(movingIndex, step, -distance, horizontal):
        return true
      if sim.trySlideOffset(movingIndex, step, distance, horizontal):
        return true
  false

proc bouncePlayers(sim: var SimServer, a, b: int, horizontal: bool) =
  ## Applies a slightly elastic equal-mass collision response along one axis
  ## between two touching players: the axis velocities average out (the
  ## shove) plus playerBouncePct percent of the closing speed rebounds (the
  ## bounce). At 100 this is a billiard-ball velocity swap, at 0 a dead-stop
  ## push.
  let
    pct = sim.config.playerBouncePct
    v1 = if horizontal: sim.players[a].velX else: sim.players[a].velY
    v2 = if horizontal: sim.players[b].velX else: sim.players[b].velY
    total = v1 + v2
    rebound = (v1 - v2) * pct div 100
  if horizontal:
    sim.players[a].velX = (total - rebound) div 2
    sim.players[b].velX = (total + rebound) div 2
  else:
    sim.players[a].velY = (total - rebound) div 2
    sim.players[b].velY = (total + rebound) div 2

proc applyMomentumAxis(
  sim: var SimServer,
  playerIndex, preferredSlide: int,
  horizontal: bool
) =
  ## Applies one fixed-point movement axis with collision sliding. Walls
  ## absorb blocked motion; another player's body blocks the same way but
  ## answers with a slightly elastic shove (bouncePlayers).
  template player: untyped = sim.players[playerIndex]
  let velocity = if horizontal: player.velX else: player.velY
  var carry =
    (if horizontal: player.carryX else: player.carryY) + velocity
  while abs(carry) >= sim.config.motionScale:
    let step = if carry < 0: -1 else: 1
    let
      nx = if horizontal: player.x + step else: player.x
      ny = if horizontal: player.y else: player.y + step
    var blocker = -1
    if sim.canOccupy(nx, ny):
      blocker = sim.blockingPlayerAt(playerIndex, player.x, player.y, nx, ny)
    if sim.canOccupy(nx, ny) and blocker < 0:
      if horizontal:
        player.x = nx
      else:
        player.y = ny
      carry -= step * sim.config.motionScale
    else:
      let radius = sim.slideScanRadius(carry, velocity)
      if sim.trySlideMove(
        playerIndex,
        step,
        radius,
        preferredSlide,
        horizontal
      ):
        carry -= step * sim.config.motionScale
      else:
        if blocker >= 0:
          sim.bouncePlayers(playerIndex, blocker, horizontal)
        carry = 0
        break
  if horizontal:
    player.carryX = carry
  else:
    player.carryY = carry


proc isWall*(sim: SimServer, mx, my: int): bool =
  if mx < 0 or my < 0 or mx >= MapWidth or my >= MapHeight:
    return true
  sim.wallMask[mapIndex(mx, my)]

proc isArtWall*(sim: SimServer, mx, my: int): bool =
  ## Static baked wall at this point, excluding the live diamonds.
  if mx < 0 or my < 0 or mx >= MapWidth or my >= MapHeight:
    return true
  for patch in sim.diamondPatches:
    if mx >= patch.x0 and mx < patch.x0 + patch.w and
        my >= patch.y0 and my < patch.y0 + patch.h:
      return patch.baseWall[(my - patch.y0) * patch.w + mx - patch.x0]
  sim.isWall(mx, my)

proc animatedDiamondAt*(sim: SimServer, x, y: int): int =
  ## Index of the live diamond covering (x, y), or -1.
  for i in 0 ..< AnimatedDiamonds.len:
    let spot = AnimatedDiamonds[i]
    if animatedDiamondCovers(
        spot, diamondSpinFrame(spot.cx, spot.cy, sim.tickCount), x, y):
      return i
  -1

proc diamondSpinAngle*(sim: SimServer, diamond: int): float =
  ## Cosmetic angle derived from the geometry/render frame source of truth.
  let frame = diamondSpinFrame(
    AnimatedDiamonds[diamond].cx, AnimatedDiamonds[diamond].cy, sim.tickCount)
  float(frame) / float(DiamondSpinFrames) * PI / 2.0

proc seatInWall*(sim: SimServer, x, y: int, ux, uy: float): (int, int) =
  ## Nudges a wall impact from the FIRST wall pixel a little deeper along the
  ## shot's heading, staying inside the wall. The blot is masked to wall pixels,
  ## so a mark centered exactly on the wall's leading edge loses the half that
  ## overhangs the floor and survives as a thin sliver; seating it into the face
  ## it struck keeps the splat whole. Never crosses back out, so paint on a thin
  ## pillar stays on that pillar.
  result = (x, y)
  for step in 1 .. StainSeatDepth:
    let
      nx = x + int(round(ux * float(step)))
      ny = y + int(round(uy * float(step)))
    if not sim.isWall(nx, ny):
      break
    result = (nx, ny)

proc addPaintStain*(sim: var SimServer, x, y: int, color: uint8,
                    onWall = false) =
  ## Records one DRIED terrain stain at an impact site, if it wins the
  ## StainChancePct roll. Cosmetic only — so this must NOT touch `sim.rng`
  ## (that stream drives gameplay, and drawing from it here would shift every
  ## later roll). Instead the roll and the blot variant come from a hash of the
  ## impact site + tick, the same idiom as shotImpactOffset/fuzzedAimBrads: a
  ## replay re-deriving this tick gets the identical stain, and a viewer that
  ## scrubs sees the paint that existed at that tick.
  if sim.paintStains.len >= StainMaxCount:
    return
  var h = 0x9E3779B9'u32 xor 0x85EBCA6B'u32
  h = (h xor uint32(x)) * 0xC2B2AE35'u32
  h = (h xor uint32(y)) * 0x27D4EB2F'u32
  h = (h xor uint32(sim.tickCount)) * 0x165667B1'u32
  h = h xor (h shr 15)
  if StainChancePct < 100 and int(h mod 100'u32) >= StainChancePct:
    return
  # Paint that hit a ROTATING diamond sticks to that stone, not to the map:
  # store it in the diamond's own frame so it turns with the spin. (A static
  # terrain stain here would also be invisible — the diamond sprite draws over
  # it — and would smear onto the floor the art bakes under the diamond.)
  let diamond = sim.animatedDiamondAt(x, y)
  if diamond >= 0:
    if sim.diamondStains.len >= StainMaxCount:
      return
    let
      spot = AnimatedDiamonds[diamond]
      a = sim.diamondSpinAngle(diamond)
      dx = float(x - spot.cx)
      dy = float(y - spot.cy)
    sim.diamondStains.add DiamondStain(
      diamond: uint8(diamond),
      # Screen offset -> the diamond's un-rotated frame, the same transform
      # rotatingDiamondPixels uses to carve its mask.
      lx: float32(dx * cos(a) + dy * sin(a)),
      ly: float32(-dx * sin(a) + dy * cos(a)),
      color: color,
      seed: h
    )
    return
  sim.paintStains.add PaintStain(
    x: x, y: y, color: color, onWall: onWall, seed: h
  )

proc lineOfSightClear*(sim: SimServer, ax, ay, bx, by: int): bool =
  ## Returns true when no wall blocks the segment between two map points.
  let
    dx = bx - ax
    dy = by - ay
    steps = max(abs(dx), abs(dy))
  if steps == 0:
    return true
  for s in 1 .. steps:
    let
      rx = ax + dx * s div steps
      ry = ay + dy * s div steps
    if sim.isWall(rx, ry):
      return false
  true

proc segDistSqWithin*(px, py, ax, ay, bx, by, maxDistSq: int): bool =
  ## True when the point is within sqrt(maxDistSq) of the segment. All-integer
  ## (int64 intermediates so wasm32 and native agree bit-for-bit): the closest
  ## point a + (t/len2)*d is compared without the division by scaling both
  ## sides by len2^2.
  let
    dx = int64(bx - ax)
    dy = int64(by - ay)
    len2 = dx * dx + dy * dy
    apx = int64(px - ax)
    apy = int64(py - ay)
  if len2 == 0:
    return apx * apx + apy * apy <= int64(maxDistSq)
  let t = clamp(apx * dx + apy * dy, 0'i64, len2)
  let
    ex = apx * len2 - t * dx
    ey = apy * len2 - t * dy
  ex * ex + ey * ey <= int64(maxDistSq) * len2 * len2

proc barrierIndexAt*(sim: SimServer, mx, my: int): int =
  ## Index of the standing barrier whose cardboard band covers this map pixel,
  ## or -1. A pixel is covered when it lies within BarrierHalfThick of one of
  ## the three half-hex sides.
  const bandSq = BarrierHalfThick * BarrierHalfThick
  for i in 0 ..< sim.placedBarriers.len:
    let b = sim.placedBarriers[i]
    if mx < b.minX or mx > b.maxX or my < b.minY or my > b.maxY:
      continue
    for side in 0 .. 2:
      if segDistSqWithin(mx, my, b.verts[side].x, b.verts[side].y,
          b.verts[side + 1].x, b.verts[side + 1].y, bandSq):
        return i
  -1

proc playerTouchesBarrier(sim: SimServer, playerIndex, barrierIndex: int): bool =
  ## True when the player's solid footprint reaches the barrier's cardboard
  ## band (the footprint box is treated as a disc of PlayerHalf — the same
  ## radius, deterministic, and a hair forgiving on the corners, which reads
  ## right for "drove into the cardboard").
  const reachSq = (PlayerHalf + BarrierHalfThick) * (PlayerHalf + BarrierHalfThick)
  let
    b = sim.placedBarriers[barrierIndex]
    px = sim.players[playerIndex].x + CollisionW div 2
    py = sim.players[playerIndex].y + CollisionH div 2
  if px < b.minX - PlayerHalf or px > b.maxX + PlayerHalf or
      py < b.minY - PlayerHalf or py > b.maxY + PlayerHalf:
    return false
  for side in 0 .. 2:
    if segDistSqWithin(px, py, b.verts[side].x, b.verts[side].y,
        b.verts[side + 1].x, b.verts[side + 1].y, reachSq):
      return true
  false

proc paintPathClear*(sim: SimServer, ax, ay, bx, by: int): bool =
  ## The check every PAINT path uses (gun corridor samples, spray cone): like
  ## lineOfSightClear, but also stopped by standing cardboard barriers.
  ## Vision (fog shadowcast and the render-side LOS) keeps the wall-only
  ## test — cardboard blocks paint, never sight. Zero extra cost when no
  ## barrier stands.
  if not sim.lineOfSightClear(ax, ay, bx, by):
    return false
  if sim.placedBarriers.len == 0:
    return true
  let
    dx = bx - ax
    dy = by - ay
    steps = max(abs(dx), abs(dy))
  for s in 1 .. steps:
    if sim.barrierIndexAt(ax + dx * s div steps, ay + dy * s div steps) >= 0:
      return false
  true

proc flattenBarrier(sim: var SimServer, index: int, color: uint8,
                    cause: string) =
  ## Removes one standing barrier with a crumple splatter at its center
  ## (cosmetic only) and a log line; `color` picks the splatter/log actor.
  let b = sim.placedBarriers[index]
  sim.splatters.add SplatterFx(
    x: b.x, y: b.y, tick: sim.tickCount, color: color, hit: false
  )
  sim.logGameEvent(playerColorText(color) & " " & cause)
  sim.placedBarriers.delete(index)

proc damageBarrier(sim: var SimServer, index, hitX, hitY: int, color: uint8) =
  ## Applies one paintball hit to a standing barrier: a splat on the
  ## cardboard, and after BarrierHp hits the barrier is gone.
  sim.splatters.add SplatterFx(
    x: hitX, y: hitY, tick: sim.tickCount, color: color, hit: false
  )
  dec sim.placedBarriers[index].hp
  if sim.placedBarriers[index].hp <= 0:
    sim.flattenBarrier(index, color, "shredded a cardboard barrier")

proc gameTicksElapsed*(sim: SimServer): int =
  ## Returns ticks elapsed since the current game left the lobby.
  if sim.gameStartTick < 0:
    return 0
  max(0, sim.tickCount - sim.gameStartTick)

proc effectiveMaxTicks*(sim: SimServer): int =
  ## Returns the game's scheduled tick limit (0 = no limit). GV41 removed
  ## the action-floor overtime, so this is exactly config.maxTicks; kept as
  ## a proc because the broadcast chrome reads the schedule through it.
  max(0, sim.config.maxTicks)

proc barrageFullDepth*(): int =
  ## The edge depth at which the four target bands cover the whole board:
  ## past half the shorter axis the two bands on that axis meet.
  min(MapWidth, MapHeight) div 2 + 1

proc barrageProgressPermille*(sim: SimServer): int =
  ## Returns how far the barrage has escalated, 0..1000: 0 at the latch,
  ## 1000 once barrageSaturateSec has elapsed — at the default settings
  ## (latch 30s before the end, saturate in 30s) the whole board is under
  ## maximum bombardment exactly when the clock reads 0:00. Pure integer
  ## math off deterministic state (latch tick + tick count), so native,
  ## wasm, and replays all agree.
  if sim.barrageStartTick < 0 or sim.config.barrageMaxPerSec <= 0:
    return 0
  let rampTicks = max(1, sim.config.barrageSaturateSec * TargetFps)
  min(1000, (sim.tickCount - sim.barrageStartTick) * 1000 div rampTicks)

proc barrageDepth*(sim: SimServer): int =
  ## Returns how deep inside every map edge the barrage currently targets,
  ## in px; 0 while the barrage is off or not yet latched. Starts at
  ## BarrageEdgeBandPx and deepens linearly to full board coverage.
  if sim.barrageStartTick < 0:
    return 0
  let progress = sim.barrageProgressPermille()
  BarrageEdgeBandPx +
    (barrageFullDepth() - BarrageEdgeBandPx) * progress div 1000

proc barrageRatePermille*(sim: SimServer): int =
  ## Returns the current launch rate in permille grenades/second: the
  ## configured start rate at the latch, ramping linearly to the max rate as
  ## the escalation completes.
  if sim.barrageStartTick < 0:
    return 0
  sim.config.barrageStartPerSec * 1000 +
    (sim.config.barrageMaxPerSec - sim.config.barrageStartPerSec) *
      sim.barrageProgressPermille()

proc killPlayer*(
  sim: var SimServer,
  targetIndex,
  killerIndex: int,
  killerSlot = -1,
  elimination = false,
  cause = ""
) =
  ## Applies a fatal hit: return any carried flag to its pedestal, decrement
  ## lives, start respawn. GV35: an `elimination` death (the team's heart was
  ## captured, so everyone folds with it) is a mechanical death only — no
  ## deaths-stat increment and no per-player "killed by" line, because nobody
  ## shot these players; the team lost. The endscreen's D column stays a
  ## record of combat deaths.
  if targetIndex < 0 or targetIndex >= sim.players.len:
    return
  if not sim.players[targetIndex].alive:
    return
  if not elimination:
    # An environmental death (cause text, no killer) logs its own line; a
    # combat death keeps the classic "killed by" attribution.
    if cause.len > 0:
      sim.logGameEvent(
        playerColorText(sim.players[targetIndex].color) & " " & cause)
    else:
      sim.logGameEvent(
        playerColorText(sim.players[targetIndex].color) &
          " killed by " & sim.playerText(killerIndex)
      )
  # A dying trigger pull never releases, and a carried grenade is lost.
  sim.players[targetIndex].fireWindup = 0
  sim.players[targetIndex].windupBrads = -1
  sim.players[targetIndex].hasGrenade = false
  sim.players[targetIndex].hasShield = false
  sim.players[targetIndex].shieldHp = 0
  sim.players[targetIndex].hasPlasmaArc = false
  sim.players[targetIndex].arcTicksLeft = 0
  sim.players[targetIndex].arcAimBrads = -1
  sim.players[targetIndex].throwCharge = 0
  sim.players[targetIndex].hasBarrier = false  # carried cardboard is lost too.
  sim.players[targetIndex].puddleTicks = 0
  for team in sim.teams():
    if sim.flags[team].carrier == targetIndex:
      sim.players[targetIndex].carryingFlag = false
      if sim.config.isEmergAnt():
        sim.flags[team].carrier = -1
        sim.flags[team].captured = true
        sim.flags[team].respawnAt = sim.tickCount + sim.config.foodRespawnTicks
        sim.logGameEvent("carried food was lost")
      else:
        sim.logGameEvent(teamText(team) & " heart returned home")
        sim.resetFlag(team)
  # Leave a cosmetic splatter at the death spot (never enters gameHash).
  sim.splatters.add SplatterFx(
    x: sim.players[targetIndex].x,
    y: sim.players[targetIndex].y,
    tick: sim.tickCount,
    color: sim.players[targetIndex].color,
    hit: false
  )
  # No permanent stain at the death spot either: the paint that killed this cog
  # landed ON the cog, and the fading splatter above is the record of it. Only
  # paint that MISSED and reached terrain leaves a mark on terrain.
  # A floating "KO" kill marker rises and fades from the death spot — the same
  # mechanism as the "-1" damage pops, so a kill reads at a glance in the
  # spectator/replay view (cosmetic only, never in gameHash).
  sim.damagePops.add DamageFx(
    x: sim.players[targetIndex].x + CollisionW div 2,
    y: sim.players[targetIndex].y + CollisionH div 2,
    tick: sim.tickCount,
    amount: 0,
    color: sim.players[targetIndex].color,
    kill: true
  )
  sim.players[targetIndex].alive = false
  sim.players[targetIndex].velX = 0
  sim.players[targetIndex].velY = 0
  sim.players[targetIndex].carryX = 0
  sim.players[targetIndex].carryY = 0
  # GV35: elimination deaths never touch the deaths stat — the counter (and
  # the killfeed/scrubber markers diffed from it) records combat only.
  if not elimination:
    sim.recordDeath(targetIndex)
  # Death is the victim-side record (source = victim, target = killer); the
  # weapon-attributed Kill is emitted by each weapon's own damage site, where
  # the weapon is known first-hand.
  sim.emitEvent(
    Death, source = targetIndex, target = killerIndex,
    x = float(sim.players[targetIndex].x + CollisionW div 2),
    y = float(sim.players[targetIndex].y + CollisionH div 2),
    targetSlot = killerSlot
  )
  if sim.players[targetIndex].lives > 0:
    dec sim.players[targetIndex].lives
  sim.players[targetIndex].respawnTimer =
    if sim.players[targetIndex].lives > 0:
      max(1, sim.config.respawnTicks)
    else:
      0

proc absorbDamage*(sim: var SimServer, targetIndex: int, amount: int): int {.discardable.} =
  ## Applies damage to a player: the shield layer soaks hits before base hp.
  ## Callers keep their own death checks on the base hp that remains. Returns
  ## how many hp the shield layer absorbed (`fromShield`) — first-hand `blocked`
  ## for the tier-2 Damage event; callers that don't need it can ignore it.
  let fromShield = min(sim.players[targetIndex].shieldHp, amount)
  sim.players[targetIndex].shieldHp -= fromShield
  sim.players[targetIndex].hp -= amount - fromShield
  if fromShield > 0 and sim.players[targetIndex].shieldHp == 0:
    # A broken shield is GONE: the carry icon, the " shield" label, and the
    # fire slowdown all end with the bubble, and an in-flight slowed cooldown
    # re-clamps so the next shot fires at the normal rate.
    sim.players[targetIndex].hasShield = false
    sim.players[targetIndex].fireCooldown = min(
      sim.players[targetIndex].fireCooldown, sim.config.fireCooldownTicks
    )
  fromShield

proc canFire*(sim: SimServer, shooterIndex: int): bool =
  ## Returns whether one player is able to fire a shot right now.
  if shooterIndex < 0 or shooterIndex >= sim.players.len:
    return false
  let shooter = sim.players[shooterIndex]
  shooter.alive and shooter.fireCooldown <= 0 and not shooter.hasPlasmaArc

proc canFireArc*(sim: SimServer, attackerIndex: int): bool =
  ## Returns whether one player can fire an immediate spray burst.
  if attackerIndex < 0 or attackerIndex >= sim.players.len:
    return false
  let attacker = sim.players[attackerIndex]
  attacker.alive and attacker.hasPlasmaArc and attacker.fireCooldown <= 0

proc selectArcVictims(
  sim: SimServer,
  attackerIndex: int
): seq[int] =
  ## Returns every living player whose BODY overlaps the attacker's forward
  ## spray cone. The cone's ORIGIN is the attacker's CURRENT position (it rides
  ## its owner across the active window), but its DIRECTION is the aim locked at
  ## the fire instant (`arcAimBrads`) — turning the cog mid-spray never sweeps
  ## the cone.
  ##
  ## The victim is a disc of PlasmaArcBodyRadius, not the bare point its
  ## 1px collision box would suggest, so the cone covers what the paint
  ## visibly covers. Spraying backwards still hits nobody: the can points
  ## forward, so a cog behind the attacker is out regardless of its body.
  if attackerIndex < 0 or attackerIndex >= sim.players.len:
    return @[]
  let
    attacker = sim.players[attackerIndex]
    ax = attacker.x + CollisionW div 2
    ay = attacker.y + CollisionH div 2
    (ux, uy) = aimVector(attacker.arcAimBrads)
    reach = float(PlasmaArcReach)
    # The cone's half-width grows linearly with forward distance, hitting
    # PlasmaArcMaxWidth / 2 exactly at the reach cap.
    halfWidthSlope = float(PlasmaArcMaxWidth) / (2.0 * reach)
  for i in 0 ..< sim.players.len:
    if i == attackerIndex or not sim.players[i].alive:
      continue
    let
      vx = float(sim.players[i].x + CollisionW div 2 - ax)
      vy = float(sim.players[i].y + CollisionH div 2 - ay)
      forward = vx * ux + vy * uy
      perpendicular = abs(vx * uy - vy * ux)
    if forward <= 0 or forward > reach + float(PlasmaArcBodyRadius):
      continue
    if perpendicular > forward * halfWidthSlope + float(PlasmaArcBodyRadius):
      continue
    if not sim.paintPathClear(
      ax,
      ay,
      sim.players[i].x + CollisionW div 2,
      sim.players[i].y + CollisionH div 2
    ):
      continue
    result.add(i)

proc startArcFire*(sim: var SimServer, attackerIndex: int) =
  ## Ignites one player's plasma cone: it stays on for PlasmaArcActiveTicks
  ## and the weapon then needs PlasmaArcResetTicks to recharge before the
  ## next firing. Damage is dealt by resolveActiveArcCones each active tick.
  if not sim.canFireArc(attackerIndex):
    return
  sim.players[attackerIndex].fireCooldown =
    PlasmaArcActiveTicks + PlasmaArcResetTicks
  sim.players[attackerIndex].arcTicksLeft = PlasmaArcActiveTicks
  # Lock the aim NOW: the cone keeps this direction for its whole active
  # window, so turning the cog mid-spray no longer sweeps it around. One
  # fire, one direction.
  sim.players[attackerIndex].arcAimBrads = sim.players[attackerIndex].aimBrads
  sim.players[attackerIndex].arcHitMask = 0
  sim.players[attackerIndex].arcKillsThisFire = 0
  sim.logGameEvent(
    playerColorText(sim.players[attackerIndex].color) & " sprayed paint"
  )

proc resolveActiveArcCones*(sim: var SimServer) =
  ## Advances every live spray cone one tick: all cones are resolved
  ## against the same snapshot (no processing-order advantage), each victim
  ## is damaged at most once per activation, and every live cone leaves a
  ## cosmetic flash at its owner's current position and aim. A touch removes
  ## PlasmaArcDamage hit points — lethal to a bare cog, survivable once by a
  ## shield carrier. A dead owner's cone shuts off.
  var arcFires: seq[tuple[attacker: int, victims: seq[int]]] = @[]
  for attackerIndex in 0 ..< sim.players.len:
    if sim.players[attackerIndex].arcTicksLeft <= 0:
      continue
    if not sim.players[attackerIndex].alive:
      sim.players[attackerIndex].arcTicksLeft = 0
      continue
    arcFires.add((attackerIndex, sim.selectArcVictims(attackerIndex)))
  for arcFire in arcFires:
    let attacker = sim.players[arcFire.attacker]
    var damages: seq[EventDamage]
    sim.plasmaArcFlashes.add PlasmaArcFx(
      x: attacker.x + CollisionW div 2,
      y: attacker.y + CollisionH div 2,
      aimBrads: attacker.arcAimBrads,   ## the locked fire direction, not live aim
      tick: sim.tickCount,
      color: teamColor(attacker.team),
      attacker: arcFire.attacker
    )
    # A can sprayed at the terrain coats it. March the cone's center ray to the
    # first wall inside reach and dry a stain there — so spraying down a
    # corridor leaves the corridor painted, not just the cogs in it. One stain
    # per tick of the cone (its site moves with the owner).
    block sprayStain:
      let
        ax = attacker.x + CollisionW div 2
        ay = attacker.y + CollisionH div 2
        (ux, uy) = aimVector(attacker.arcAimBrads)
      for step in 1 .. PlasmaArcReach:
        let
          rx = ax + int(round(ux * float(step)))
          ry = ay + int(round(uy * float(step)))
        if sim.isWall(rx, ry):
          let (sxw, syw) = sim.seatInWall(rx, ry, ux, uy)
          sim.addPaintStain(sxw, syw, teamColor(attacker.team), onWall = true)
          break sprayStain
    for victimIndex in arcFire.victims:
      if victimIndex < 0 or victimIndex >= sim.players.len:
        continue
      if not sim.players[victimIndex].alive:
        continue
      if victimIndex < 32:
        let bit = 1'u32 shl victimIndex
        if (sim.players[arcFire.attacker].arcHitMask and bit) != 0:
          continue
        sim.players[arcFire.attacker].arcHitMask =
          sim.players[arcFire.attacker].arcHitMask or bit
      # A bubble that eats the burst keeps the body clean, exactly as with a
      # paintball (see the gun's damage site).
      let bubbleUp = sim.players[victimIndex].hasShield and
        sim.players[victimIndex].shieldHp > 0
      let blocked = sim.absorbDamage(victimIndex, PlasmaArcDamage)
      if bubbleUp:
        # Blink the bubble toward the sprayer, as the gun's damage site does —
        # otherwise a fully-absorbed burst shows no feedback anywhere.
        sim.bubbleImpacts.add BubbleImpactFx(
          playerIndex: victimIndex,
          tick: sim.tickCount,
          angleBrads: bradsOfVector(
            sim.players[arcFire.attacker].x - sim.players[victimIndex].x,
            sim.players[arcFire.attacker].y - sim.players[victimIndex].y
          )
        )
      else:
        # A can of paint sprayed in the face paints: stamp the visor splat,
        # like the gun and the grenade.
        sim.players[victimIndex].paintHitTick = sim.tickCount
      let
        vx = float(sim.players[victimIndex].x + CollisionW div 2)
        vy = float(sim.players[victimIndex].y + CollisionH div 2)
      sim.emitEvent(
        Damage, source = arcFire.attacker, target = victimIndex,
        weapon = "spray", amount = PlasmaArcDamage,
        hp = max(0, sim.players[victimIndex].hp),
        blocked = blocked, x = vx, y = vy
      )
      if sim.collectEvents:
        damages.add sim.eventDamage(
          victimIndex,
          PlasmaArcDamage,
          max(0, sim.players[victimIndex].hp),
          blocked
        )
      # Floating damage number for the HP loss (cosmetic, not in gameHash).
      sim.damagePops.add DamageFx(
        x: sim.players[victimIndex].x + CollisionW div 2,
        y: sim.players[victimIndex].y + CollisionH div 2,
        tick: sim.tickCount,
        amount: PlasmaArcDamage, color: sim.players[victimIndex].color
      )
      if sim.players[victimIndex].hp <= 0:
        sim.killPlayer(victimIndex, arcFire.attacker)
        if victimIndex != arcFire.attacker:
          sim.recordKill(arcFire.attacker)
          sim.recordTeamKill(arcFire.attacker, victimIndex)
          sim.emitEvent(
            Kill, source = arcFire.attacker, target = victimIndex,
            weapon = "spray", amount = PlasmaArcDamage, x = vx, y = vy
          )
          # Multi-kill accounting per ACTIVATION (not per tick): the second
          # kill of one firing mints a double, the third upgrades it to a
          # triple; a fourth+ stays inside the already-counted triple.
          inc sim.players[arcFire.attacker].arcKillsThisFire
          if sim.players[arcFire.attacker].arcKillsThisFire == 2:
            inc sim.players[arcFire.attacker].multiKills2
          elif sim.players[arcFire.attacker].arcKillsThisFire == 3:
            dec sim.players[arcFire.attacker].multiKills2
            inc sim.players[arcFire.attacker].multiKills3
    if sim.collectEvents:
      sim.emitEvent(
        SprayUse,
        source = arcFire.attacker,
        weapon = "spray",
        x = float(attacker.x + CollisionW div 2),
        y = float(attacker.y + CollisionH div 2),
        actionId = sim.eventActionId(
          arcFire.attacker,
          SprayAction,
          sim.tickCount - (PlasmaArcActiveTicks - attacker.arcTicksLeft)
        ),
        headingBrads = attacker.arcAimBrads,
        damages = damages
      )
    if sim.players[arcFire.attacker].arcTicksLeft > 0:
      dec sim.players[arcFire.attacker].arcTicksLeft
      # The cone just shut off: clear the locked aim so an idle owner carries
      # no stale direction (matches how the gun clears windupBrads on release).
      if sim.players[arcFire.attacker].arcTicksLeft == 0:
        sim.players[arcFire.attacker].arcAimBrads = -1

proc tryFireArc*(sim: var SimServer, attackerIndex: int) =
  ## Fires one spray burst immediately for direct callers and tests: ignites
  ## the cone and resolves its first tick (other live cones also advance).
  if not sim.canFireArc(attackerIndex):
    return
  sim.startArcFire(attackerIndex)
  sim.resolveActiveArcCones()

proc aimJitterSigma(sim: SimServer, perks: PerkSet): float =
  ## The per-shot Gaussian aim-noise sigma, in radians (GV34): calibrated
  ## against the LIVE config.gunRange so that a fully visible body at max
  ## range is hit exactly 80% of the time — see AimJitterCentralZ for the
  ## derivation. PlayerHalf + BulletHalfWidth is the corridor's continuous
  ## acceptance half-window for a centered silhouette. A scope-perked shooter
  ## deviates less: sigma shrinks by perkMods.scopeAim (the scale applies
  ## only when the perk is present, so a perk-free shot's draw is untouched).
  let window = (float(PlayerHalf) + BulletHalfWidth) / float(sim.config.gunRange)
  result = arcsin(min(1.0, window)) / AimJitterCentralZ
  if PerkScope in perks:
    result = result * float(1000 - sim.config.perkMods.scopeAim) / 1000.0

proc jitterDirection(
  sim: var SimServer, headingBrads: int, perks: PerkSet
): tuple[x, y: float] =
  ## The actual unit direction of one released shot: the locked aim rotated
  ## by a Gaussian draw on the deterministic sim RNG (like the trench duck,
  ## it is part of the hashed game, so replays re-roll identically). The
  ## same fuzzed direction drives target selection AND the tracer/stain, so
  ## where the paint lands is where the viewer sees it fly.
  let
    (bx, by) = aimVector(headingBrads)
    jitter = gauss(sim.rng, 0.0, sim.aimJitterSigma(perks))
    cj = cos(jitter)
    sj = sin(jitter)
  # aimVector is (cos a, -sin a) (screen y down), so adding jitter to the
  # angle expands to this rotation of the base vector.
  (bx * cj + by * sj, by * cj - bx * sj)

proc selectFireTarget(
  sim: var SimServer, shooterIndex: int, ux, uy: float
): int =
  ## Returns the player the shot lands on: the bullet travels down the
  ## given unit direction (the locked aim plus the released shot's jitter,
  ## GV34) toward the FIRST body it crosses (friendly fire
  ## on), stopping at walls — or -1 for a miss. A trench occupant crossed
  ## by the ray ducks under TrenchMissPct of the shots fired from outside
  ## their trench (config-gated trenches): the bullet flies straight over them and carries
  ## on down the ray to the next exposed body, exactly as if the occupant
  ## were not there. The duck is rolled per occupant on the deterministic
  ## sim RNG at shot release.
  ##
  ## A target's body is sampled across its silhouette (perpendicular to the
  ## ray, ±PlayerHalf): a sample connects only when the bullet corridor
  ## covers it AND the shooter has line of sight TO THAT SAMPLE. Cover is
  ## therefore partial, not binary — a corner-hugger can only be hit on the
  ## sliver of body it actually shows, and a fully exposed body presents the
  ## same effective width as the old center-only corridor check.
  result = -1
  let
    shooter = sim.players[shooterIndex]
    sx = shooter.x + CollisionW div 2
    sy = shooter.y + CollisionH div 2
    maxRange = float(sim.config.gunRange)
    shooterTrench = sim.playerTrench(shooterIndex)
  # Every body the bullet corridor crosses, at its distance along the ray.
  var crossed: seq[tuple[t: float, index: int]] = @[]
  for i in 0 ..< sim.players.len:
    if i == shooterIndex or not sim.players[i].alive:
      continue
    let
      tx = float(sim.players[i].x + CollisionW div 2)
      ty = float(sim.players[i].y + CollisionH div 2)
    for off in countup(-PlayerHalf, PlayerHalf, ExposureSampleStep):
      let
        px = tx - float(off) * uy      # silhouette sample: the body span
        py = ty + float(off) * ux      # perpendicular to the shot ray
        vx = px - float(sx)
        vy = py - float(sy)
        t = vx * ux + vy * uy          # distance along the ray
      if t <= 0 or t > maxRange:
        continue
      if abs(vx * uy - vy * ux) > BulletHalfWidth:
        continue
      if not sim.paintPathClear(sx, sy, int(round(px)), int(round(py))):
        continue
      crossed.add((t, i))
      break
  # Walk the crossed bodies in ray order (index breaks exact ties, so the
  # walk is deterministic); the first body that does not duck is the hit.
  crossed.sort()
  # A handicapped shooter's aim goes wide on a fraction of the shots that would
  # otherwise connect. Rolled ONCE per shot, only when there is a body to hit
  # AND the team carries a handicap — so an unhandicapped game draws no extra
  # RNG and re-simulates byte-for-byte. On a miss the whole shot flies wide
  # (it does not fall through to a body further down the ray).
  let missPermille = sim.config.missPermilleFor(shooter.team)
  if missPermille > 0 and crossed.len > 0 and sim.rng.rand(999) < missPermille:
    return -1
  for candidate in crossed:
    let targetTrench = sim.playerTrench(candidate.index)
    if targetTrench >= 0 and targetTrench != shooterTrench and
        sim.rng.rand(99) < TrenchMissPct:
      continue
    return candidate.index

type PendingGunShot = object
  shooterIndex: int
  targetIndex: int
  headingBrads: int          ## the INTENDED locked aim (events, animation).
  dirX, dirY: float          ## the fuzzed direction the shot actually flew.
  actionId: int64

proc selectGunShot(sim: var SimServer, shooterIndex: int): PendingGunShot =
  ## Selects a target and snapshots the trigger metadata before any
  ## simultaneous shot can kill and reset another shooter. (`var` because
  ## the shot rolls its aim jitter, then target selection rolls the trench
  ## duck, both on the sim RNG — one fixed draw order per released shot.)
  let
    shooter = sim.players[shooterIndex]
    headingBrads =
      if shooter.windupBrads >= 0: shooter.windupBrads
      else: shooter.aimBrads
    triggerTick =
      if shooter.windupBrads >= 0:
        sim.tickCount - sim.config.fireWindupTicks
      else:
        sim.tickCount
    (ux, uy) = sim.jitterDirection(headingBrads, shooter.perks)
  PendingGunShot(
    shooterIndex: shooterIndex,
    targetIndex: sim.selectFireTarget(shooterIndex, ux, uy),
    headingBrads: headingBrads,
    dirX: ux,
    dirY: uy,
    actionId: sim.eventActionId(shooterIndex, GunAction, triggerTick)
  )

proc applyFire(sim: var SimServer, shot: PendingGunShot) =
  ## Applies one selected shot: cooldown, tracer, and the kill. The target
  ## may already have died to another shot this tick; the shot still lands
  ## (tracer and all) but only an alive target yields a kill.
  let
    shooterIndex = shot.shooterIndex
    targetIndex = shot.targetIndex
    shooter = sim.players[shooterIndex]
    (ux, uy) = (shot.dirX, shot.dirY)  # the fuzzed direction, not the aim.
    sx = shooter.x + CollisionW div 2
    sy = shooter.y + CollisionH div 2
  # GV26: heart carriers fire at CarrierFireSlowdown (same 3x as shields);
  # Trench occupants fire at TrenchFireSlowdown (config-gated). Every slowdown
  # composes by MAX, never the product.
  var cooldownScale = 1
  if shooter.hasShield or shooter.carryingFlag:
    cooldownScale = max(ShieldFireSlowdown, CarrierFireSlowdown)
  if sim.playerTrench(shooterIndex) >= 0:
    cooldownScale = max(cooldownScale, TrenchFireSlowdown)
  sim.players[shooterIndex].fireCooldown =
    sim.config.fireCooldownTicks * cooldownScale
  sim.players[shooterIndex].windupBrads = -1
  # Accuracy bookkeeping (analysis-only, excluded from gameHash): every call
  # here is one released shot; a shot that locked onto a live enemy on the ray
  # (targetIndex >= 0) is on-target, so it counts as a hit even in the rare
  # tick where the victim already died to a simultaneous shot.
  inc sim.players[shooterIndex].shotsFired
  sim.emitEvent(
    Shot,
    source = shooterIndex,
    weapon = "gun",
    x = float(sx),
    y = float(sy),
    actionId = shot.actionId,
    headingBrads = shot.headingBrads
  )
  # Record a cosmetic tracer for the shot (never enters gameHash). It ends at
  # the victim, so a bullet visibly never travels past its first hit.
  var
    ex = sx
    ey = sy
  if targetIndex >= 0:
    inc sim.players[shooterIndex].shotsHit
    ex = sim.players[targetIndex].x + CollisionW div 2
    ey = sim.players[targetIndex].y + CollisionH div 2
    sim.emitEvent(
      Hit, source = shooterIndex, target = targetIndex, weapon = "gun",
      x = float(ex), y = float(ey)
    )
  else:
    # March along the unit aim to the last wall-free pixel or max range
    # (checking each sampled pixel keeps this O(range) at 1050px).
    let maxRange = sim.config.gunRange
    var
      lastClear = 0
      wallX = 0
      wallY = 0
      struckWall = false
      struckBarrier = -1
    for step in 1 .. maxRange:
      let
        rx = sx + int(round(ux * float(step)))
        ry = sy + int(round(uy * float(step)))
      # Cardboard before stone: a standing barrier soaks the paintball (one
      # of its BarrierHp hits) where a wall would merely wear the stain.
      if sim.placedBarriers.len > 0:
        struckBarrier = sim.barrierIndexAt(rx, ry)
        if struckBarrier >= 0:
          wallX = rx
          wallY = ry
          break
      if sim.isWall(rx, ry):
        struckWall = true
        wallX = rx
        wallY = ry
        break
      lastClear = step
    ex = sx + int(round(ux * float(lastClear)))
    ey = sy + int(round(uy * float(lastClear)))
    if struckBarrier >= 0:
      # The tracer visibly ends ON the cardboard, and the hit splat lands
      # there; the paint never reaches the terrain behind it.
      ex = wallX
      ey = wallY
      sim.damageBarrier(struckBarrier, wallX, wallY, shooter.color)
    # Paint that MISSES every cog carries on until it hits geometry, and dries
    # there for the rest of the match. The mark goes on the WALL PIXEL it
    # struck — not the last clear pixel in front of it, which would leave the
    # paint hanging on the floor beside the wall it visibly hit. A shot that
    # simply ran out of range hit nothing and marks nothing.
    if struckWall:
      let (stainX, stainY) = sim.seatInWall(wallX, wallY, ux, uy)
      sim.addPaintStain(stainX, stainY, shooter.color, onWall = true)
  sim.recentShots.add ShotFx(
    x0: sx,
    y0: sy,
    x1: ex,
    y1: ey,
    firedTick: sim.tickCount,
    color: shooter.color,
    hit: targetIndex >= 0
  )
  var impactReported = false
  if targetIndex >= 0 and sim.players[targetIndex].alive:
    # A carrier whose shield layer is still up at impact absorbs the hit
    # VISUALS on the bubble: it blinks and dents toward the shooter instead of
    # showing the inner struck-target ring and body paint spark. The "-1" pop
    # still reads the hp loss. (Cosmetic only — the damage itself is
    # unchanged.)
    let bubbleUp = sim.players[targetIndex].hasShield and
      sim.players[targetIndex].shieldHp > 0
    # A lucky shot (luck perk) deals perkMods.luckDamage instead of 1. Rolled once
    # per LANDED hit, only when the shooter carries the perk, so a perk-free
    # game draws no extra RNG and re-simulates byte-for-byte.
    var damage = 1
    if PerkLuck in shooter.perks and
        sim.rng.rand(999) < sim.config.perkMods.luckChance:
      damage = sim.config.perkMods.luckDamage
    let blocked = sim.absorbDamage(targetIndex, damage)
    # Paintball paint marks the body only when the shield bubble ISN'T eating it
    # (a bubble dent draws no body paint). Stamp so the EYES-PiP visor splat
    # fires for THIS paint hit — and only for a PAINT hit (gun/grenade). The
    # spray cone stamps it at its own damage site.
    if not bubbleUp:
      sim.players[targetIndex].paintHitTick = sim.tickCount
    sim.emitEvent(
      Damage, source = shooterIndex, target = targetIndex, weapon = "gun",
      amount = damage, hp = max(0, sim.players[targetIndex].hp),
      blocked = blocked,
      x = float(sim.players[targetIndex].x + CollisionW div 2),
      y = float(sim.players[targetIndex].y + CollisionH div 2)
    )
    if sim.collectEvents:
      sim.emitEvent(
        ShotImpact,
        source = shooterIndex,
        target = targetIndex,
        weapon = "gun",
        x = float(ex),
        y = float(ey),
        actionId = shot.actionId,
        headingBrads = shot.headingBrads,
        distance = hypot(float(ex - sx), float(ey - sy)),
        damages = @[
          sim.eventDamage(
            targetIndex,
            damage,
            max(0, sim.players[targetIndex].hp),
            blocked
          )
        ]
      )
    impactReported = true
    if bubbleUp:
      sim.bubbleImpacts.add BubbleImpactFx(
        playerIndex: targetIndex,
        tick: sim.tickCount,
        angleBrads: bradsOfVector(sx - ex, sy - ey)
      )
    else:
      # A spectator-view flash rings the struck target the moment the bullet
      # connects, so hits read at a glance (cosmetic only, never in gameHash).
      sim.hitFlashes.add HitFlashFx(
        playerIndex: targetIndex,
        tick: sim.tickCount
      )
    # A floating "-1" rises and fades from the victim so a lost health bar
    # reads at a glance (cosmetic only, never in gameHash).
    sim.damagePops.add DamageFx(
      x: sim.players[targetIndex].x + CollisionW div 2,
      y: sim.players[targetIndex].y + CollisionH div 2,
      tick: sim.tickCount,
      amount: damage,
      color: sim.players[targetIndex].color
    )
    if sim.players[targetIndex].hp <= 0:
      sim.killPlayer(targetIndex, shooterIndex)
      sim.recordKill(shooterIndex)
      sim.recordTeamKill(shooterIndex, targetIndex)
      sim.emitEvent(
        Kill, source = shooterIndex, target = targetIndex, weapon = "gun",
        amount = damage,
        x = float(sim.players[targetIndex].x + CollisionW div 2),
        y = float(sim.players[targetIndex].y + CollisionH div 2)
      )
    else:
      if not bubbleUp:
        # A non-fatal hit leaves a small, short-lived paint spark in the
        # shooter's color on the target (cosmetic only, never in gameHash).
        sim.splatters.add SplatterFx(
          x: sim.players[targetIndex].x,
          y: sim.players[targetIndex].y,
          tick: sim.tickCount,
          color: shooter.color,
          hit: true
        )
        # NO terrain stain here: a paintball that connects spends its paint ON
        # THE COG (the splat above). Only shots that MISS reach terrain and
        # mark it — that is the whole fiction, and staining hit sites too made
        # the arena read as painted wherever cogs merely stood.
      sim.logGameEvent(
        playerColorText(sim.players[targetIndex].color) &
          " hit by " & sim.playerText(shooterIndex) &
          " (" & $(sim.players[targetIndex].hp +
            sim.players[targetIndex].shieldHp) & " hp left)"
      )
  if sim.collectEvents and not impactReported:
    sim.emitEvent(
      ShotImpact,
      source = shooterIndex,
      target = targetIndex,
      weapon = "gun",
      x = float(ex),
      y = float(ey),
      actionId = shot.actionId,
      headingBrads = shot.headingBrads,
      distance = hypot(float(ex - sx), float(ey - sy))
    )

proc tryFire*(sim: var SimServer, shooterIndex: int) =
  ## Fires one shot immediately (the single-shooter path).
  if not sim.canFire(shooterIndex):
    return
  sim.applyFire(sim.selectGunShot(shooterIndex))

proc startFireWindup*(sim: var SimServer, shooterIndex: int) =
  ## Starts a shot: locks the current aim angle and arms the windup.
  ## The shot itself releases fireWindupTicks later (see step).
  if not sim.canFire(shooterIndex):
    return
  if sim.players[shooterIndex].fireWindup > 0:
    return
  let actionId = sim.eventActionId(shooterIndex, GunAction)
  sim.players[shooterIndex].fireWindup = sim.config.fireWindupTicks
  sim.players[shooterIndex].windupBrads = sim.players[shooterIndex].aimBrads
  sim.emitEvent(
    GunTrigger,
    source = shooterIndex,
    weapon = "gun",
    x = float(sim.players[shooterIndex].x + CollisionW div 2),
    y = float(sim.players[shooterIndex].y + CollisionH div 2),
    actionId = actionId,
    headingBrads = sim.players[shooterIndex].aimBrads
  )


proc grenadePosition*(grenade: AirborneGrenade, tick: int): tuple[x, y: int] =
  ## The grenade's map position while airborne (linear flight over walls).
  let t = clamp(tick - grenade.launchTick, 0, grenade.flightTicks)
  (grenade.sx + (grenade.tx - grenade.sx) * t div grenade.flightTicks,
    grenade.sy + (grenade.ty - grenade.sy) * t div grenade.flightTicks)

proc throwTarget*(player: Player, maxRange: int): tuple[x, y: int] =
  ## Where a charging player's throw would currently land, along their aim at
  ## the charge-picked distance. `maxRange` is the seat's resolved full-charge
  ## distance (config.grenadeRangeFor — the grenade perk stretches it). The
  ## render charge-ring caller (global.nim) resolves it the same way
  ## throwGrenade below does, and throwGrenade duplicates this strength
  ## formula inline — keep the two in lockstep so the ring never disagrees
  ## with where the grenade actually goes.
  let
    charge = clamp(player.throwCharge, 0, GrenadeChargeTicks)
    strength = GrenadeMinRange +
      (maxRange - GrenadeMinRange) * charge div GrenadeChargeTicks
    (ux, uy) = aimVector(player.aimBrads)
    sx = player.x + CollisionW div 2
    sy = player.y + CollisionH div 2
  (clamp(sx + int(round(ux * float(strength))),
      ArenaBorder + 2, MapWidth - ArenaBorder - 2),
    clamp(sy + int(round(uy * float(strength))),
      ArenaBorder + 2, MapHeight - ArenaBorder - 2))

proc throwGrenade(sim: var SimServer, playerIndex: int) =
  ## Releases the charged throw along the thrower's current aim. The charge
  ## picks the distance (GrenadeMinRange..GrenadeMaxRange); the grenade
  ## flies over every obstacle and explodes where it lands. Throwing is
  ## deliberately silent: no sound FX is recorded here.
  let
    player = sim.players[playerIndex]
    charge = clamp(player.throwCharge, 0, GrenadeChargeTicks)
    maxRange = sim.config.grenadeRangeFor(GrenadeMaxRange, player.perks)
    strength = GrenadeMinRange +
      (maxRange - GrenadeMinRange) * charge div GrenadeChargeTicks
    (ux, uy) = aimVector(player.aimBrads)
    sx = player.x + CollisionW div 2
    sy = player.y + CollisionH div 2
    tx = clamp(
      sx + int(round(ux * float(strength))),
      ArenaBorder + 2, MapWidth - ArenaBorder - 2
    )
    ty = clamp(
      sy + int(round(uy * float(strength))),
      ArenaBorder + 2, MapHeight - ArenaBorder - 2
    )
    # Fixed fuse: the burst comes exactly GrenadeFlightMultiple shot-windups
    # after release, near or far. The visible arc just moves faster on long
    # throws; the threat window is constant and readable.
    flight = max(1, GrenadeFlightMultiple * sim.config.fireWindupTicks)
    throwDistance = hypot(float(tx - sx), float(ty - sy))
  sim.airborneGrenades.add AirborneGrenade(
    sx: sx,
    sy: sy,
    tx: tx,
    ty: ty,
    launchTick: sim.tickCount,
    flightTicks: flight,
    thrower: playerIndex,
    throwerSlot: player.joinOrder,
    throwerAccount: sim.rewardAccountIndexForSlot(player.joinOrder)
  )
  sim.emitEvent(
    GrenadeThrow,
    source = playerIndex,
    weapon = "grenade",
    x = float(sx),
    y = float(sy),
    actionId = sim.eventActionId(playerIndex, GrenadeAction),
    headingBrads = player.aimBrads,
    distance = throwDistance,
    item = "grenade"
  )
  sim.players[playerIndex].hasGrenade = false
  sim.players[playerIndex].throwCharge = 0
  sim.logGameEvent(playerColorText(player.color) & " threw a grenade")

proc placeBarrier(sim: var SimServer, playerIndex: int) =
  ## Unfolds the carried cardboard into a standing half-hex centered on the
  ## placer, flat side across their aim: vertices at aim -90/-30/+30/+90
  ## degrees, BarrierRadius out, snapped to map pixels (every later coverage
  ## test is integer-only). The apothem (~21px) clears the placer's own
  ## 6px-half footprint, so placing never crushes the fresh barrier — walking
  ## forward into it afterwards does.
  const vertAngles = [-PI / 2.0, -PI / 6.0, PI / 6.0, PI / 2.0]
  let
    player = sim.players[playerIndex]
    cx = player.x + CollisionW div 2
    cy = player.y + CollisionH div 2
    (ux, uy) = aimVector(player.aimBrads)
  var barrier = PlacedBarrier(
    x: cx,
    y: cy,
    facingBrads: player.aimBrads,
    hp: BarrierHp,
    team: player.team,
    placedTick: sim.tickCount
  )
  for k in 0 .. 3:
    let
      c = cos(vertAngles[k])
      s = sin(vertAngles[k])
    barrier.verts[k] = (
      cx + int(round(float(BarrierRadius) * (ux * c - uy * s))),
      cy + int(round(float(BarrierRadius) * (ux * s + uy * c)))
    )
  barrier.minX = barrier.verts[0].x
  barrier.maxX = barrier.verts[0].x
  barrier.minY = barrier.verts[0].y
  barrier.maxY = barrier.verts[0].y
  for k in 1 .. 3:
    barrier.minX = min(barrier.minX, barrier.verts[k].x)
    barrier.maxX = max(barrier.maxX, barrier.verts[k].x)
    barrier.minY = min(barrier.minY, barrier.verts[k].y)
    barrier.maxY = max(barrier.maxY, barrier.verts[k].y)
  barrier.minX -= BarrierHalfThick + 1
  barrier.minY -= BarrierHalfThick + 1
  barrier.maxX += BarrierHalfThick + 1
  barrier.maxY += BarrierHalfThick + 1
  # The pool is bounded (it sizes the render id block): past the cap the
  # OLDEST standing barrier folds so the new one can stand.
  if sim.placedBarriers.len >= MaxBarriersPlaced:
    sim.placedBarriers.delete(0)
  sim.placedBarriers.add(barrier)
  sim.players[playerIndex].hasBarrier = false
  sim.logGameEvent(
    playerColorText(player.color) & " placed a cardboard barrier")

proc applyBarrierInput(
  sim: var SimServer,
  playerIndex: int,
  input, prev: InputState
) =
  ## Press C to unfold a carried barrier where you stand — instant, no
  ## charge. C is the grenade button too, but a cog never holds both
  ## (pickups are mutually exclusive), so the press is unambiguous.
  if not sim.players[playerIndex].alive or
      not sim.players[playerIndex].hasBarrier:
    return
  if input.c and not prev.c:
    sim.placeBarrier(playerIndex)

proc applyGrenadeInput(
  sim: var SimServer,
  playerIndex: int,
  input, prev: InputState
) =
  ## Hold C to charge a throw, release to let it fly.
  if not sim.players[playerIndex].alive or
      not sim.players[playerIndex].hasGrenade:
    sim.players[playerIndex].throwCharge = 0
    return
  if input.c:
    sim.players[playerIndex].throwCharge = min(
      sim.players[playerIndex].throwCharge + 1, GrenadeChargeTicks
    )
  elif prev.c and sim.players[playerIndex].throwCharge > 0:
    sim.throwGrenade(playerIndex)
  else:
    sim.players[playerIndex].throwCharge = 0

proc explodeGrenade(sim: var SimServer, grenade: AirborneGrenade) =
  ## Applies one landing: a cosmetic blast flash (which views also use for
  ## the audible landing's sound ring) plus blast damage to EVERYONE inside
  ## the radius — teammates and the thrower included. A trench changes the
  ## damage, not the radius: GrenadeTrenchDamage for a victim sharing the
  ## landing trench, GrenadeTrenchSplashDamage for a victim in any other
  ## trench, GrenadeDamage for anyone in the open.
  # Color the splat by the thrower's TEAM (not their individual slot color), so
  # a landing reads as that team's paint-bomb — and the sprite id stays within
  # the two team-color slots, never colliding with the tracer pool.
  let
    legacyThrowerIndex = sim.legacyGrenadeThrowerIndex(grenade)
    throwerSlot = sim.grenadeThrowerSlot(grenade)
    throwerIndex = sim.playerIndexForSlot(throwerSlot)
    # An environment shell (grenade barrage, throwerSlot -1) has no owning
    # team: its splat cycles the ACTIVE team colors by launch tick, staying
    # inside the same team-keyed blast sprite pool a player lob uses.
    # (teamForSlot(-1) would index Team(-1) — never call it for a shell.)
    throwerColor =
      if throwerSlot < 0:
        teamColor(Team(grenade.launchTick mod sim.gameMap.teamCount()))
      else:
        teamColor(sim.teamForSlot(throwerSlot))
    landingTrench = trenchIndexAt(grenade.tx, grenade.ty)
  sim.recentBlasts.add BlastFx(
    x: grenade.tx, y: grenade.ty, tick: sim.tickCount, color: throwerColor,
    trenchLanding: landingTrench >= 0
  )
  # A paint bomb repaints the ground it lands on permanently: a cluster of
  # dried stains across the blast footprint, so a contested chokepoint that
  # eats grenades ends the match visibly coated. Offsets are fixed (and each
  # stain re-hashes its own site) so a replay rebuilds the identical cluster.
  # A trench-trapped blast keeps its stains inside the pit: offsets that
  # would land outside the landing trench's own square are simply skipped.
  const stainRing = [(0, 0), (-26, -14), (24, -20), (30, 12),
                     (-18, 24), (6, 32), (-32, 4), (14, -32)]
  for (ox, oy) in stainRing:
    let
      bx = grenade.tx + ox
      by = grenade.ty + oy
    if bx < 0 or by < 0 or bx >= MapWidth or by >= MapHeight:
      continue
    if landingTrench >= 0 and not inShape(bx, by, ArenaTrenches[landingTrench]):
      continue
    sim.addPaintStain(bx, by, throwerColor)
  sim.logGameEvent("grenade landed")
  let radiusSq = GrenadeBlastRadius * GrenadeBlastRadius
  var
    blastKills = 0
    damages: seq[EventDamage]
  for i in 0 ..< sim.players.len:
    if not sim.players[i].alive:
      continue
    let
      px = sim.players[i].x + CollisionW div 2
      py = sim.players[i].y + CollisionH div 2
      # GV30: the blast tests the SOLID BODY BOX (±PlayerHalf), not the bare
      # position point — a cog whose footprint touches the circle is caught,
      # the same rule the gun's bullet corridor already uses (BulletHalfWidth
      # sampled across ±PlayerHalf). Circle-vs-box is the distance from the
      # burst to the NEAREST point of the box, so on-axis reach becomes
      # GrenadeBlastRadius + PlayerHalf.
      nearX = max(0, abs(px - grenade.tx) - PlayerHalf)
      nearY = max(0, abs(py - grenade.ty) - PlayerHalf)
    if nearX * nearX + nearY * nearY > radiusSq:
      continue
    # A trench traps or shields a blast: a victim caught in the SAME trench
    # the grenade landed in takes amplified damage (nowhere to duck), a
    # victim in any OTHER trench takes reduced splash, and a victim outside
    # every trench takes the ordinary open-field amount.
    let
      victimTrench = trenchIndexAt(px, py)
      dmg =
        if victimTrench < 0: GrenadeDamage
        elif victimTrench == landingTrench: GrenadeTrenchDamage
        else: GrenadeTrenchSplashDamage
      # Read the bubble BEFORE absorbDamage drains shieldHp: a bubble that eats
      # the blast keeps the body clean, exactly as with a paintball (see the
      # gun's damage site).
      bubbleUp = sim.players[i].hasShield and sim.players[i].shieldHp > 0
      blocked = sim.absorbDamage(i, dmg)
    if bubbleUp:
      # The bubble itself blinks and dents toward the burst, so an absorbed
      # blast reads as absorbed instead of leaving no feedback at all.
      sim.bubbleImpacts.add BubbleImpactFx(
        playerIndex: i,
        tick: sim.tickCount,
        angleBrads: bradsOfVector(grenade.tx - px, grenade.ty - py)
      )
    else:
      # A paint-bomb blast marks everyone caught in it — stamp so the EYES-PiP
      # visor splat fires for this paint hit (gun/grenade; spray stamps its own).
      sim.players[i].paintHitTick = sim.tickCount
    sim.emitEvent(
      Damage, source = throwerIndex, target = i, weapon = "grenade",
      amount = dmg, hp = max(0, sim.players[i].hp),
      blocked = blocked,
      x = float(px), y = float(py), sourceSlot = throwerSlot
    )
    if sim.collectEvents:
      damages.add sim.eventDamage(
        i,
        dmg,
        max(0, sim.players[i].hp),
        blocked
      )
    # Floating damage number for the blast's HP loss (cosmetic, not in gameHash).
    sim.damagePops.add DamageFx(
      x: px, y: py, tick: sim.tickCount,
      amount: dmg, color: sim.players[i].color
    )
    if sim.players[i].hp <= 0:
      # An environment shell logs its own death line instead of the combat
      # "killed by" attribution (there is nobody to credit).
      sim.killPlayer(
        i, throwerIndex, throwerSlot,
        cause = (if throwerSlot < 0: "shelled by the grenade barrage" else: "")
      )
      if throwerSlot >= 0 and throwerSlot != sim.eventSlot(i):
        if grenade.throwerAccount >= 0 and
            grenade.throwerAccount < sim.rewardAccounts.len:
          inc sim.rewardAccounts[grenade.throwerAccount].kills
        if legacyThrowerIndex >= 0 and legacyThrowerIndex != i:
          # Preserve the exact GV24 hash even if compaction made this legacy
          # live index point at a different player. Results and events above
          # use the immutable thrower identity.
          inc sim.players[legacyThrowerIndex].kills
        if throwerIndex >= 0 and throwerIndex != i:
          sim.recordTeamKill(throwerIndex, i)
        sim.emitEvent(
          Kill, source = throwerIndex, target = i, weapon = "grenade",
          amount = dmg, x = float(px), y = float(py),
          sourceSlot = throwerSlot
        )
        if throwerIndex >= 0 and throwerIndex != i:
          inc blastKills
  if sim.collectEvents:
    sim.emitEvent(
      GrenadeImpact,
      source = throwerIndex,
      weapon = "grenade",
      x = float(grenade.tx),
      y = float(grenade.ty),
      actionId = sim.eventActionIdForSlot(
        throwerSlot,
        GrenadeAction,
        grenade.launchTick
      ),
      headingBrads = bradsOfVector(
        grenade.tx - grenade.sx,
        grenade.ty - grenade.sy
      ),
      distance = hypot(
        float(grenade.tx - grenade.sx),
        float(grenade.ty - grenade.sy)
      ),
      item = "grenade",
      damages = damages,
      sourceSlot = throwerSlot
    )
  # Multi-kill accounting per BLAST: one landing that kills 2 mints a double,
  # 3+ a triple (a self-kill in the blast never counts toward either).
  if throwerIndex >= 0:
    if blastKills >= 3:
      inc sim.players[throwerIndex].multiKills3
    elif blastKills == 2:
      inc sim.players[throwerIndex].multiKills2

proc updateGrenades(sim: var SimServer) =
  ## Refills corner pickups whose timer elapsed and lands due grenades.
  for spawn in sim.grenadeSpawns.mitems:
    if not spawn.present and sim.tickCount >= spawn.respawnAt:
      spawn.present = true
  var
    landing: seq[AirborneGrenade] = @[]
    kept: seq[AirborneGrenade] = @[]
  for grenade in sim.airborneGrenades:
    if sim.tickCount - grenade.launchTick >= grenade.flightTicks:
      landing.add grenade
    else:
      kept.add grenade
  sim.airborneGrenades = kept
  for grenade in landing:
    sim.explodeGrenade(grenade)

template pickupByTouch(
  sim: var SimServer,
  playerIndex: int,
  spawnsField: untyped,
  pickupRange, respawnTicks: int,
  taken: untyped
) =
  ## Shared touch-pickup skeleton for the four pickup families: scans present
  ## spawns within pickupRange of the player's center, and on the first hit
  ## marks it taken, arms its respawn timer, runs `taken` (with `spawn`, `px`,
  ## `py` injected — grant + events + log, in each family's original order),
  ## and stops. Callers keep their own eligibility gates.
  let
    px {.inject.} = sim.players[playerIndex].x + CollisionW div 2
    py {.inject.} = sim.players[playerIndex].y + CollisionH div 2
    rangeSq = pickupRange * pickupRange
  for spawn {.inject.} in sim.spawnsField.mitems:
    if spawn.present and distSq(px, py, spawn.x, spawn.y) <= rangeSq:
      spawn.present = false
      spawn.respawnAt = sim.tickCount + respawnTicks
      taken
      return

template refillElapsedPickups(sim: var SimServer, spawnsField: untyped) =
  ## Refills spawns whose respawn timer elapsed.
  for spawn in sim.spawnsField.mitems:
    if not spawn.present and sim.tickCount >= spawn.respawnAt:
      spawn.present = true

proc tryPickupGrenades*(sim: var SimServer, playerIndex: int) =
  ## Lets a living player pick up a corner grenade by touch (one carried
  ## grenade max; either team may take either side's pickups). A cog carrying
  ## a cardboard barrier walks over the pickup untouched — grenade and
  ## barrier share button C, so a cog holds one or the other, never both.
  if not sim.players[playerIndex].alive or
      sim.players[playerIndex].hasGrenade or
      sim.players[playerIndex].hasBarrier:
    return
  sim.pickupByTouch(playerIndex, grenadeSpawns, GrenadePickupRange,
      GrenadeRespawnTicks):
    sim.players[playerIndex].hasGrenade = true
    sim.emitPickup(playerIndex, "grenade", spawn.x, spawn.y)
    sim.logGameEvent(
      playerColorText(sim.players[playerIndex].color) &
        " picked up a grenade"
    )

proc updateMedKits*(sim: var SimServer) =
  ## Refills center med kits whose respawn timer elapsed.
  sim.refillElapsedPickups(medKitSpawns)

proc updatePlasmaArcs*(sim: var SimServer) =
  ## Refills side-center spray can pickups whose respawn timer elapsed.
  sim.refillElapsedPickups(plasmaArcSpawns)

proc tryPickupMedKits*(sim: var SimServer, playerIndex: int) =
  ## Lets a hurt living player pick up a center med kit by touch, restoring
  ## hit points back to full. A healthy player walks over it untouched, so a
  ## kit is never wasted; a taken kit refills after MedKitRespawnTicks.
  if not sim.players[playerIndex].alive:
    return
  let maxHp = sim.config.maxHpFor(
    sim.players[playerIndex].team, sim.players[playerIndex].perks)
  if sim.players[playerIndex].hp >= maxHp:
    return
  sim.pickupByTouch(playerIndex, medKitSpawns, MedKitPickupRange,
      MedKitRespawnTicks):
    let healed = maxHp - sim.players[playerIndex].hp
    sim.players[playerIndex].hp = maxHp
    sim.emitPickup(playerIndex, "med_kit", spawn.x, spawn.y)
    sim.emitEvent(
      Heal, source = playerIndex, amount = healed,
      hp = sim.players[playerIndex].hp, x = float(px), y = float(py)
    )
    sim.logGameEvent(
      playerColorText(sim.players[playerIndex].color) &
        " picked up a med kit"
    )

proc updateShields*(sim: var SimServer) =
  ## Refills endzone shields whose respawn timer elapsed.
  sim.refillElapsedPickups(shieldSpawns)

proc tryPickupShields*(sim: var SimServer, playerIndex: int) =
  ## Lets a living player pick up an endzone shield by touch (either team may
  ## take either endzone's shield). A pickup grants the shield and refills the
  ## ShieldLayerHp-strong shield layer that damage depletes before base hp —
  ## it never heals base damage (that is the med kits' job), so a worn carrier
  ## may take another shield to restore the layer, while a carrier whose layer
  ## is intact leaves the spawn untouched for a teammate. Carrying a shield
  ## slows fire ShieldFireSlowdown times; a taken shield refills after
  ## ShieldRespawnTicks.
  if not sim.players[playerIndex].alive:
    return
  if sim.players[playerIndex].shieldHp >= ShieldLayerHp:
    return
  sim.pickupByTouch(playerIndex, shieldSpawns, ShieldPickupRange,
      ShieldRespawnTicks):
    sim.players[playerIndex].hasShield = true
    sim.players[playerIndex].shieldHp = ShieldLayerHp
    sim.emitPickup(playerIndex, "shield", spawn.x, spawn.y)
    sim.logGameEvent(
      playerColorText(sim.players[playerIndex].color) &
        " picked up a shield"
    )

proc tryPickupPlasmaArcs*(sim: var SimServer, playerIndex: int) =
  ## Lets a living player pick up one side-center spray can by touch.
  if not sim.players[playerIndex].alive or sim.players[playerIndex].hasPlasmaArc:
    return
  sim.pickupByTouch(playerIndex, plasmaArcSpawns, PlasmaArcPickupRange,
      PlasmaArcRespawnTicks):
    sim.players[playerIndex].hasPlasmaArc = true
    sim.players[playerIndex].fireWindup = 0
    sim.players[playerIndex].windupBrads = -1
    sim.emitPickup(playerIndex, "spray_can", spawn.x, spawn.y)
    sim.logGameEvent(
      playerColorText(sim.players[playerIndex].color) &
        " picked up a spray can"
    )

proc tryPickupBarriers*(sim: var SimServer, playerIndex: int) =
  ## Lets a living player pick up one folded cardboard barrier by touch. The
  ## grenade shares button C, so carrying either blocks picking up the other
  ## (the grenade side of the gate lives in tryPickupGrenades).
  if not sim.players[playerIndex].alive or
      sim.players[playerIndex].hasBarrier or
      sim.players[playerIndex].hasGrenade:
    return
  sim.pickupByTouch(playerIndex, barrierSpawns, BarrierPickupRange,
      BarrierRespawnTicks):
    sim.players[playerIndex].hasBarrier = true
    sim.emitPickup(playerIndex, "barrier", spawn.x, spawn.y)
    sim.logGameEvent(
      playerColorText(sim.players[playerIndex].color) &
        " picked up a cardboard barrier"
    )

proc updateBarriers*(sim: var SimServer) =
  ## Refills barrier pickups whose respawn timer elapsed, then flattens any
  ## standing barrier a cog drove into this tick — cardboard stops paint,
  ## not a rolling bot. Runs after movement, so the crush lands the same
  ## tick as the contact.
  sim.refillElapsedPickups(barrierSpawns)
  if sim.placedBarriers.len == 0:
    return
  var index = 0
  while index < sim.placedBarriers.len:
    var crusher = -1
    for playerIndex in 0 ..< sim.players.len:
      if sim.players[playerIndex].alive and
          sim.playerTouchesBarrier(playerIndex, index):
        crusher = playerIndex
        break
    if crusher >= 0:
      sim.flattenBarrier(
        index, sim.players[crusher].color, "flattened a cardboard barrier")
    else:
      inc index

proc sanitizeShout*(text: string): string =
  ## Reduces raw chat text to a legal shout: printable ASCII only, at most
  ## ShoutMaxChars characters, no leading or trailing spaces.
  for c in text:
    if c >= ' ' and c <= '~':
      result.add(c)
    if result.len == ShoutMaxChars:
      break
  result = result.strip()

proc applyShout*(sim: var SimServer, playerIndex: int, text: string): bool {.discardable.} =
  ## Applies one player chat message as a shout: a short message audible to
  ## anyone within ShoutRange of the shouter. Living players only, at most
  ## one shout per second, and one live bubble per player (a new shout
  ## replaces the old one). Returns whether the shout was applied.
  if sim.phase != Playing:
    return false
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  if not sim.players[playerIndex].alive:
    return false
  let shoutText = sanitizeShout(text)
  if shoutText.len == 0:
    return false
  let last = sim.players[playerIndex].lastShoutTick
  if last >= 0 and sim.tickCount - last < ShoutCooldownTicks:
    return false
  sim.players[playerIndex].lastShoutTick = sim.tickCount
  let address = sim.players[playerIndex].address
  var kept: seq[Shout] = @[]
  for shout in sim.recentShouts:
    if shout.address != address:
      kept.add shout
  let shout = Shout(
    address: address,
    team: sim.players[playerIndex].team,
    text: shoutText,
    tick: sim.tickCount,
    x: sim.players[playerIndex].x + CollisionW div 2,
    y: sim.players[playerIndex].y + CollisionH div 2
  )
  kept.add shout
  sim.recentShouts = kept
  sim.emitEvent(
    ShoutEvent,
    source = playerIndex,
    x = float(shout.x),
    y = float(shout.y),
    content = shoutText
  )
  true

proc shoutAudibleTo*(sim: SimServer, viewerIndex: int, shout: Shout): bool =
  ## Whether one viewer can hear a shout: within ShoutRange of where it was
  ## made. Shouts carry through walls and fog like gunfire, but dead viewers
  ## observe nothing.
  if viewerIndex < 0 or viewerIndex >= sim.players.len:
    return false
  if not sim.players[viewerIndex].alive:
    return false
  let
    vx = sim.players[viewerIndex].x + CollisionW div 2
    vy = sim.players[viewerIndex].y + CollisionH div 2
  distSq(vx, vy, shout.x, shout.y) <= ShoutRange * ShoutRange

proc resolveSimultaneousFire*(sim: var SimServer, shooters: openArray[int]) =
  ## Resolves every shot released this tick at once: all targets are chosen
  ## against the same snapshot before any kill is applied, so a mutual duel
  ## kills both shooters and neither team gains an input-processing-order
  ## advantage.
  var shots: seq[PendingGunShot] = @[]
  for shooterIndex in shooters:
    if sim.canFire(shooterIndex):
      shots.add(sim.selectGunShot(shooterIndex))
  for shot in shots:
    sim.applyFire(shot)

proc resolveContactAttacks*(sim: var SimServer, attackers: openArray[int]) =
  ## Resolves every fresh mandible attack from the same post-movement
  ## snapshot. Each attacker bites the nearest enemy body in contact; all hp
  ## losses are applied before any death, so ants can kill one another on the
  ## same tick. A target mobbed by several ants takes every bite, with the
  ## first closest/index-stable attacker receiving the single kill credit.
  type PendingBite = tuple[attacker, target, distanceSq: int]
  var pending: seq[PendingBite] = @[]
  let rangeSq = AntBiteRange * AntBiteRange
  for attacker in attackers:
    if attacker < 0 or attacker >= sim.players.len or
        not sim.players[attacker].alive or
        sim.players[attacker].fireCooldown > 0:
      continue
    let
      ax = sim.players[attacker].x + CollisionW div 2
      ay = sim.players[attacker].y + CollisionH div 2
    var
      target = -1
      closest = high(int)
    for victim in 0 ..< sim.players.len:
      if victim == attacker or not sim.players[victim].alive or
          sim.players[victim].team == sim.players[attacker].team:
        continue
      let d = distSq(
        ax, ay,
        sim.players[victim].x + CollisionW div 2,
        sim.players[victim].y + CollisionH div 2)
      if d <= rangeSq and d < closest:
        target = victim
        closest = d
    if target >= 0:
      pending.add((attacker, target, closest))
      sim.players[attacker].fireCooldown = sim.config.biteCooldownTicks

  var
    totalDamage = newSeq[int](sim.players.len)
    creditedAttacker = newSeq[int](sim.players.len)
  for i in 0 ..< creditedAttacker.len:
    creditedAttacker[i] = -1
  for bite in pending:
    totalDamage[bite.target] += sim.config.biteDamage
    if creditedAttacker[bite.target] < 0:
      creditedAttacker[bite.target] = bite.attacker

  for target in 0 ..< sim.players.len:
    if totalDamage[target] <= 0 or not sim.players[target].alive:
      continue
    let
      attacker = creditedAttacker[target]
      damage = totalDamage[target]
      blocked = sim.absorbDamage(target, damage)
      px = sim.players[target].x + CollisionW div 2
      py = sim.players[target].y + CollisionH div 2
    sim.emitEvent(
      Damage, source = attacker, target = target, weapon = "mandible",
      amount = damage, hp = max(0, sim.players[target].hp), blocked = blocked,
      x = float(px), y = float(py))
    sim.damagePops.add DamageFx(
      x: px, y: py, tick: sim.tickCount, amount: damage,
      color: sim.players[target].color)
    if sim.players[target].hp <= 0:
      sim.killPlayer(target, attacker)
      sim.recordKill(attacker)
      sim.emitEvent(
        Kill, source = attacker, target = target, weapon = "mandible",
        amount = damage, x = float(px), y = float(py))
    else:
      sim.hitFlashes.add HitFlashFx(playerIndex: target, tick: sim.tickCount)
      sim.logGameEvent(
        playerColorText(sim.players[target].color) & " bitten by " &
          sim.playerText(attacker) & " (" & $sim.players[target].hp &
          " hp left)")

proc tryPickupFlags*(sim: var SimServer, playerIndex: int) =
  ## Lets a living player steal ANY enemy team's flag off its pedestal by
  ## touch. A player's own flag cannot be interacted with by their own team.
  ## Ties (two pedestals in touch range at once — impossible on real maps)
  ## resolve in enum order, deterministically.
  ##
  ## GV42: `FlagPickupRange` covers the DRAWN heart, so standing on the
  ## pedestal is the whole interaction — there is no pinpoint to find and no
  ## grab button. See the constant for the art-derived derivation.
  if not sim.players[playerIndex].alive or sim.players[playerIndex].carryingFlag:
    return
  let
    px = sim.players[playerIndex].x + CollisionW div 2
    py = sim.players[playerIndex].y + CollisionH div 2
    rangeSq = FlagPickupRange * FlagPickupRange
  for flagTeam in sim.teams():
    if not sim.config.isEmergAnt() and flagTeam == sim.players[playerIndex].team:
      continue
    if sim.flags[flagTeam].carrier >= 0 or sim.flags[flagTeam].captured:
      continue
    if distSq(px, py, sim.flags[flagTeam].x, sim.flags[flagTeam].y) <= rangeSq:
      sim.flags[flagTeam].carrier = playerIndex
      sim.players[playerIndex].carryingFlag = true
      sim.emitEvent(
        FlagSteal, source = playerIndex,
        x = float(sim.flags[flagTeam].x), y = float(sim.flags[flagTeam].y)
      )
      sim.logGameEvent(
        if sim.config.isEmergAnt():
          teamText(sim.players[playerIndex].team) & " harvested neutral food"
        else:
          teamText(sim.players[playerIndex].team) & " stole the " &
            teamText(flagTeam) & " heart"
      )
      return

proc updateFlags(sim: var SimServer) =
  ## Keeps each carried flag glued to its carrier; a carrier that stops
  ## carrying for any reason other than capture sends the flag straight back
  ## to its own pedestal.
  for team in sim.teams():
    let carrier = sim.flags[team].carrier
    if carrier < 0:
      continue
    if carrier < sim.players.len and sim.players[carrier].alive:
      sim.flags[team].x = sim.players[carrier].x + CollisionW div 2
      sim.flags[team].y = sim.players[carrier].y + CollisionH div 2
    else:
      # Carrier vanished; the flag goes straight back home.
      if sim.config.isEmergAnt():
        sim.flags[team].carrier = -1
        sim.flags[team].captured = true
        sim.flags[team].respawnAt = sim.tickCount + sim.config.foodRespawnTicks
        sim.logGameEvent("carried food was lost")
      else:
        sim.logGameEvent(teamText(team) & " heart returned home")
        sim.resetFlag(team)

proc updateFoodPatches*(sim: var SimServer) =
  ## Regrows each emptied neutral food patch on its own deterministic timer.
  if not sim.config.isEmergAnt() or sim.phase != Playing:
    return
  for patch in sim.teams():
    if sim.flags[patch].captured and sim.flags[patch].respawnAt > 0 and
        sim.tickCount >= sim.flags[patch].respawnAt:
      sim.resetFlag(patch)
      sim.logGameEvent("a neutral food patch regrew")

proc teamForageScore*(sim: SimServer, team: Team): int =
  ## Returns food delivered by one colony in Emerg-ant mode. Captures remain
  ## the wire/result statistic, so existing tournament tooling gets the score
  ## without a parallel accounting field.
  for player in sim.players:
    if player.team == team:
      result += player.captures

proc updatePheromones*(sim: var SimServer, inputs: openArray[InputState]) =
  ## Deposits one explicitly selected trail mark per ant each second. Opposing marks
  ## laid together inside the erase radius cancel simultaneously; surviving
  ## new marks erase older enemy trail. This avoids player-index advantage.
  if not sim.config.isEmergAnt() or sim.phase != Playing:
    return
  let elapsed = sim.tickCount - sim.gameStartTick
  if sim.config.pheromoneWashTick > 0 and
      elapsed == sim.config.pheromoneWashTick:
    sim.pheromones = @[]
    sim.logGameEvent("rain washed away every pheromone trail")
    return
  var live: seq[PheromoneMark] = @[]
  for mark in sim.pheromones:
    if sim.tickCount - mark.tick < PheromoneLifetimeTicks:
      live.add(mark)
  sim.pheromones = live
  if sim.tickCount mod PheromoneStepTicks != 0:
    return

  var candidates: seq[PheromoneMark] = @[]
  for i, player in sim.players:
    if not player.alive or i >= inputs.len or
        (not inputs[i].b and not inputs[i].c):
      continue
    candidates.add PheromoneMark(
      x: player.x + CollisionW div 2,
      y: player.y + CollisionH div 2,
      team: player.team,
      tick: sim.tickCount,
      food: inputs[i].c
    )
  let eraseSq = PheromoneEraseRadius * PheromoneEraseRadius
  var canceled = newSeq[bool](candidates.len)
  for i in 0 ..< candidates.len:
    for j in i + 1 ..< candidates.len:
      if candidates[i].team != candidates[j].team and
          distSq(candidates[i].x, candidates[i].y,
            candidates[j].x, candidates[j].y) <= eraseSq:
        canceled[i] = true
        canceled[j] = true

  var kept: seq[PheromoneMark] = @[]
  for old in sim.pheromones:
    var erased = false
    for i, fresh in candidates:
      if canceled[i] or old.team == fresh.team:
        continue
      if distSq(old.x, old.y, fresh.x, fresh.y) <= eraseSq:
        erased = true
        break
    if not erased:
      kept.add(old)
  for i, fresh in candidates:
    if not canceled[i]:
      kept.add(fresh)
  if kept.len > MaxPheromoneMarks:
    kept = kept[kept.len - MaxPheromoneMarks .. ^1]
  sim.pheromones = kept

proc applyInput*(
  sim: var SimServer,
  playerIndex: int,
  input: InputState
) {.measure.} =
  ## Applies one player's movement input. Firing is resolved separately and
  ## simultaneously for all players (resolveSimultaneousFire).
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  template player: untyped = sim.players[playerIndex]
  if not player.alive:
    return

  var
    inputX = 0
    inputY = 0
  if input.left:
    inputX -= 1
  if input.right:
    inputX += 1
  if input.up:
    inputY -= 1
  if input.down:
    inputY += 1

  # Ants face where they move: B/C belong to their pheromone channels rather
  # than turret rotation. CTF keeps decoupled aim unchanged.
  if sim.config.isEmergAnt() and (inputX != 0 or inputY != 0):
    player.aimBrads = bradsOfVector(inputX, inputY)
  # Aim rotation is decoupled from locomotion: holding B turns the aim
  # counter-clockwise, holding Select clockwise; holding both cancels out,
  # and the d-pad never changes the aim.
  if not sim.config.isEmergAnt() and input.b != input.select:
    let turn =
      if input.b: sim.config.aimTurnRate else: -sim.config.aimTurnRate
    player.aimBrads =
      ((player.aimBrads + turn) mod AimBradsTurn + AimBradsTurn) mod AimBradsTurn
  # The sprite flip follows the aim: flipped while aiming left-ish.
  player.flipH =
    player.aimBrads > AimBradsTurn div 4 and
    player.aimBrads < AimBradsTurn * 3 div 4

  let
    speedScale =
      if player.carryingFlag: sim.config.carrierSpeedPct else: 100
    maxSpeed =
      sim.config.maxSpeedFor(player.team, player.perks) * speedScale div 100
    accel = sim.config.accel * speedScale div 100
    # CLIMBING OUT of a trench is slow; dropping in and moving around it
    # are not. While the center is inside a pit, each axis whose motion
    # points AWAY from the pit's center — up that wall — is capped at 1/5
    # speed and accel, and outward momentum is shed to the cap. Motion
    # into, across, and around the pit runs at full speed.
    trench = sim.playerTrench(playerIndex)
    slowSpeed = maxSpeed div TrenchSpeedDivisor
    slowAccel = max(1, accel div TrenchSpeedDivisor)
  var
    posBoundX = maxSpeed
    negBoundX = -maxSpeed
    posBoundY = maxSpeed
    negBoundY = -maxSpeed
  if trench >= 0:
    let
      pit = shapeAsRect(ArenaTrenches[trench])
      relX = (player.x + CollisionW div 2) - (pit.x + pit.w div 2)
      relY = (player.y + CollisionH div 2) - (pit.y + pit.h div 2)
    if relX > 0: posBoundX = slowSpeed
    elif relX < 0: negBoundX = -slowSpeed
    if relY > 0: posBoundY = slowSpeed
    elif relY < 0: negBoundY = -slowSpeed
    player.velX = clamp(player.velX, negBoundX, posBoundX)
    player.velY = clamp(player.velY, negBoundY, posBoundY)

  if inputX != 0:
    let accelX =
      if trench >= 0 and
          ((inputX > 0 and posBoundX == slowSpeed) or
           (inputX < 0 and negBoundX == -slowSpeed)):
        slowAccel
      else:
        accel
    player.velX = clamp(
      player.velX + inputX * accelX,
      negBoundX,
      posBoundX
    )
  else:
    player.velX =
      (player.velX * sim.config.frictionNum) div sim.config.frictionDen
    if abs(player.velX) < sim.config.stopThreshold:
      player.velX = 0

  if inputY != 0:
    let accelY =
      if trench >= 0 and
          ((inputY > 0 and posBoundY == slowSpeed) or
           (inputY < 0 and negBoundY == -slowSpeed)):
        slowAccel
      else:
        accel
    player.velY = clamp(
      player.velY + inputY * accelY,
      negBoundY,
      posBoundY
    )
  else:
    player.velY =
      (player.velY * sim.config.frictionNum) div sim.config.frictionDen
    if abs(player.velY) < sim.config.stopThreshold:
      player.velY = 0

  let
    preferredSlideY =
      if inputY != 0:
        inputY
      else:
        signOf(player.velY)
    preferredSlideX =
      if inputX != 0:
        inputX
      else:
        signOf(player.velX)
  sim.applyMomentumAxis(playerIndex, preferredSlideY, true)
  sim.applyMomentumAxis(playerIndex, preferredSlideX, false)

proc fovCellIndex*(cx, cy: int): int {.inline.} =
  ## Returns the flat index of one fog-of-war grid cell.
  cy * FovGridW + cx

proc fovCellAt*(x, y: int): tuple[cx, cy: int] {.inline.} =
  ## Returns the fog-of-war grid cell containing one map point.
  (clamp(x div FovCellSize, 0, FovGridW - 1),
   clamp(y div FovCellSize, 0, FovGridH - 1))

proc fovCellCenter*(cx, cy: int): tuple[x, y: int] {.inline.} =
  ## Returns the map-pixel center of one fog-of-war grid cell.
  (cx * FovCellSize + FovCellSize div 2, cy * FovCellSize + FovCellSize div 2)

proc buildFovBlocked*(wallMask: seq[bool]): seq[bool] =
  ## Downsamples the pixel wall mask into the fog-of-war occlusion grid: a
  ## cell is opaque when at least half of its pixels are wall.
  result = newSeq[bool](FovCellCount)
  for cy in 0 ..< FovGridH:
    for cx in 0 ..< FovGridW:
      var
        walls = 0
        pixels = 0
      for py in cy * FovCellSize ..< min((cy + 1) * FovCellSize, MapHeight):
        for px in cx * FovCellSize ..< min((cx + 1) * FovCellSize, MapWidth):
          inc pixels
          if wallMask[mapIndex(px, py)]:
            inc walls
      result[fovCellIndex(cx, cy)] = walls * 2 >= pixels

proc castFovOctant(
  blocked: openArray[bool],
  visible: var seq[bool],
  originCx, originCy, row: int,
  startSlope, endSlope: float,
  xx, xy, yx, yy: int
) =
  ## Recursive shadowcasting over one octant of the fog-of-war grid
  ## (Bergstrom-style). Row distance is unbounded; scanning stops at the grid
  ## edge, so THIS pass is limited only by walls — the caller's cone/range
  ## filter applies the visionRange cutoff (GV34) afterwards.
  if startSlope < endSlope:
    return
  var
    start = startSlope
    rowBlocked = false
    newStart = 0.0
  let maxDist = FovGridW + FovGridH
  for dist in row .. maxDist:
    if rowBlocked:
      break
    var anyInside = false
    for dx in -dist .. 0:
      let
        dy = -dist
        lSlope = (float(dx) - 0.5) / (float(dy) + 0.5)
        rSlope = (float(dx) + 0.5) / (float(dy) - 0.5)
      if start < rSlope:
        continue
      if endSlope > lSlope:
        break
      let
        cx = originCx + dx * xx + dy * xy
        cy = originCy + dx * yx + dy * yy
      if cx < 0 or cy < 0 or cx >= FovGridW or cy >= FovGridH:
        continue
      anyInside = true
      let index = fovCellIndex(cx, cy)
      visible[index] = true
      if rowBlocked:
        if blocked[index]:
          newStart = rSlope
        else:
          rowBlocked = false
          start = newStart
      elif blocked[index]:
        rowBlocked = true
        castFovOctant(
          blocked,
          visible,
          originCx,
          originCy,
          dist + 1,
          start,
          lSlope,
          xx, xy, yx, yy
        )
        newStart = rSlope
    if not anyInside and dist > row:
      break

proc visionRange*(sim: SimServer): int =
  ## How far the vision CONE reaches, in px (GV34): 1.5x the live
  ## config.gunRange (1575 at the stock 1050), so sight always outranges
  ## paint by half again — you can see fights you cannot yet join — and both
  ## scale together under a config override. The close-quarters bubble
  ## (visionBubble) is never shrunk by this cap.
  sim.config.gunRange * 3 div 2

proc computeFovShadowcast*(
  sim: SimServer,
  originCx, originCy: int,
  visible: var seq[bool]
) {.measure.} =
  ## The aim-independent half of fog-of-war: recursive shadowcasting from
  ## the viewer's cell (walls block, unbounded by range). Cacheable per
  ## cell — this is the expensive pass.
  if visible.len != FovCellCount:
    visible.setLen(FovCellCount)
  zeroMem(addr visible[0], visible.len * sizeof(bool))
  visible[fovCellIndex(originCx, originCy)] = true
  const Octants = [
    (1, 0, 0, 1), (0, 1, 1, 0), (0, -1, 1, 0), (-1, 0, 0, 1),
    (-1, 0, 0, -1), (0, -1, -1, 0), (0, 1, -1, 0), (1, 0, 0, -1)
  ]
  for (xx, xy, yx, yy) in Octants:
    castFovOctant(
      sim.fovBlocked,
      visible,
      originCx,
      originCy,
      1,
      1.0,
      0.0,
      xx, xy, yx, yy
    )

proc applyFovCone*(
  sim: SimServer,
  originCx, originCy, aimBrads: int,
  shadowcast: seq[bool],
  visible: var seq[bool]
) {.measure.} =
  ## The aim-dependent half of fog-of-war: intersects a cached shadowcast
  ## with the forward vision cone (half-angle visionConeDeg around the aim
  ## angle, reaching visionRange px — 1.5x the gun range, GV34) plus the
  ## omnidirectional vision bubble (visionBubble px, exempt from the range
  ## cap).
  if visible.len != FovCellCount:
    visible.setLen(FovCellCount)
  copyMem(addr visible[0], unsafeAddr shadowcast[0],
    FovCellCount * sizeof(bool))
  let
    (ox, oy) = fovCellCenter(originCx, originCy)
    (ax, ay) = aimVector(aimBrads)
    coneCos = cos(float(sim.config.visionConeDeg) * PI / 180.0)
    bubbleSq = float(sim.config.visionBubble * sim.config.visionBubble)
    rangeSq = float(sim.visionRange() * sim.visionRange())
  for cy in 0 ..< FovGridH:
    for cx in 0 ..< FovGridW:
      let index = fovCellIndex(cx, cy)
      if not visible[index]:
        continue
      let
        (px, py) = fovCellCenter(cx, cy)
        vx = float(px - ox)
        vy = float(py - oy)
        d2 = vx * vx + vy * vy
      if d2 <= bubbleSq:
        continue
      if d2 > rangeSq:
        visible[index] = false
        continue
      let dot = vx * ax + vy * ay
      if dot < coneCos * sqrt(d2):
        visible[index] = false

proc computeFovVisible*(
  sim: SimServer,
  originCx, originCy, aimBrads: int,
  visible: var seq[bool]
) {.measure.} =
  ## Computes one viewer's full fog-of-war cell visibility in one shot:
  ## shadowcast, then cone/range filter. Uncached path, kept for tools and
  ## probes; the server loop goes through refreshPlayerFov's two-level
  ## cache instead.
  var shadowcast = newSeq[bool](FovCellCount)
  sim.computeFovShadowcast(originCx, originCy, shadowcast)
  sim.applyFovCone(originCx, originCy, aimBrads, shadowcast, visible)

proc ensureFovCacheSlots(sim: var SimServer) =
  ## Keeps player-indexed fog-of-war cache storage aligned with players.
  while sim.fovCaches.len < sim.players.len:
    sim.fovCaches.add PlayerFov(
      valid: false,
      visible: newSeq[bool](FovCellCount)
    )
  if sim.fovCaches.len > sim.players.len:
    sim.fovCaches.setLen(sim.players.len)

proc refreshPlayerFov*(sim: var SimServer, playerIndex: int): bool {.measure.} =
  ## Refreshes one player's cached fog-of-war grid and returns true when it
  ## was recomputed (the viewer moved to a new cell or turned).
  sim.ensureFovCacheSlots()
  let
    player = sim.players[playerIndex]
    (cx, cy) = fovCellAt(
      player.x + CollisionW div 2,
      player.y + CollisionH div 2
    )
  template cache: untyped = sim.fovCaches[playerIndex]
  if cache.valid and
      cache.originCx == cx and
      cache.originCy == cy and
      cache.aimBrads == player.aimBrads:
    return false
  # Two-level refresh: the shadowcast only depends on the viewer's cell, so
  # a viewer who merely turned (bots rotate aim nearly every tick) reuses it
  # and pays only the cone filter.
  if not (cache.cellValid and cache.cellCx == cx and cache.cellCy == cy):
    sim.computeFovShadowcast(cx, cy, cache.cellVisible)
    cache.cellValid = true
    cache.cellCx = cx
    cache.cellCy = cy
  sim.applyFovCone(cx, cy, player.aimBrads, cache.cellVisible, cache.visible)
  cache.valid = true
  cache.originCx = cx
  cache.originCy = cy
  cache.aimBrads = player.aimBrads
  true

proc playerFov*(sim: SimServer, playerIndex: int): lent PlayerFov =
  ## Returns one player's cached fog-of-war grid (refreshPlayerFov first).
  sim.fovCaches[playerIndex]

proc fovVisibleAt*(sim: SimServer, playerIndex, x, y: int): bool =
  ## Returns whether one map point is inside a viewer's vision. Dead viewers
  ## have no eyes: everything is fogged until they respawn. Call
  ## refreshPlayerFov first.
  if not sim.players[playerIndex].alive:
    return false
  if playerIndex >= sim.fovCaches.len or not sim.fovCaches[playerIndex].valid:
    return true
  let (cx, cy) = fovCellAt(x, y)
  sim.fovCaches[playerIndex].visible[fovCellIndex(cx, cy)]

proc playerVisibleTo*(sim: SimServer, viewerIndex, targetIndex: int): bool =
  ## Returns whether one player is observable by a viewer: only yourself is
  ## always visible; everyone else — teammates included — only inside your
  ## vision. There is no team radio.
  if viewerIndex == targetIndex:
    return true
  sim.fovVisibleAt(
    viewerIndex,
    sim.players[targetIndex].x + CollisionW div 2,
    sim.players[targetIndex].y + CollisionH div 2
  )

proc flagVisibleTo*(sim: SimServer, viewerIndex: int, team: Team): bool =
  ## CTF hearts are permanent public landmarks. Every living ant smells every
  ## available planted food patch regardless of distance; policies use its
  ## global bearing as odor while exact contact and pheromone detail stay local.
  ## Carried food remains visible exactly when its carrier is visible.
  let carrier = sim.flags[team].carrier
  if carrier < 0:
    if sim.config.isEmergAnt():
      if sim.flags[team].captured or viewerIndex < 0 or
          viewerIndex >= sim.players.len or not sim.players[viewerIndex].alive:
        return false
      return true
    return true
  sim.playerVisibleTo(viewerIndex, carrier)

proc pheromoneVisibleTo*(
  sim: SimServer, viewerIndex: int, mark: PheromoneMark
): bool =
  ## Pheromone is smelled locally without line-of-sight, but dead ants have no
  ## observation stream. The broadcast uses viewerIndex < 0 and sees all.
  if viewerIndex < 0:
    return true
  if viewerIndex >= sim.players.len or not sim.players[viewerIndex].alive:
    return false
  let viewer = sim.players[viewerIndex]
  distSq(
    viewer.x + CollisionW div 2,
    viewer.y + CollisionH div 2,
    mark.x,
    mark.y) <= sim.config.antSenseRadius * sim.config.antSenseRadius

proc finishGame*(sim: var SimServer, winner: Team, isDraw = false, timeLimitReached = false) =
  ## Moves to game over and awards all winning players.
  if sim.phase == GameOver:
    return
  if isDraw:
    sim.logGameEvent("draw")
  else:
    sim.logGameEvent(teamText(winner) & " win")
  sim.emitPhaseChange(GameOver)
  sim.phase = GameOver
  sim.winner = winner
  sim.isDraw = isDraw
  sim.gameOverTimer = sim.config.gameOverTicks
  sim.timeLimitReached = timeLimitReached
  if isDraw:
    if timeLimitReached:
      # A time-limit draw is a lose-lose: every player on both teams takes
      # TimeoutReward so running out the clock is never better than losing.
      # A mutual-wipe draw stays 0/0 — both sides at least fought to the end.
      var penalizedAccounts = newSeq[bool](sim.rewardAccounts.len)
      for i in 0 ..< sim.players.len:
        let accountIndex = sim.rewardAccountForPlayer(i)
        if penalizedAccounts.len < sim.rewardAccounts.len:
          penalizedAccounts.setLen(sim.rewardAccounts.len)
        if accountIndex >= 0 and accountIndex < penalizedAccounts.len:
          penalizedAccounts[accountIndex] = true
        sim.addReward(i, TimeoutReward)
      for i in 0 ..< sim.rewardAccounts.len:
        if i < penalizedAccounts.len and penalizedAccounts[i]:
          continue
        if not sim.rewardAccounts[i].hasTeam:
          continue
        sim.rewardAccounts[i].reward += TimeoutReward
    return
  # classic: zero-sum by construction — the winning team scores +1 per losing
  # team, each losing team -1. Classic 2-team play is +1/-1; a 4-team ffa win
  # pays the winner +3 and each loser -1.
  # pot: every team antes one point, so the pot is the team count and the
  # winning team takes all of it; the losing teams split the forfeit evenly
  # (integer division, so a 4-team pot of 4 costs each of the three losers 1).
  # 2 teams pay +2/-2, 4 teams pay +4/-1/-1/-1.
  let loserTeams = sim.gameMap.teamCount() - 1
  let winReward =
    if sim.config.scoring == PotScoring:
      sim.gameMap.teamCount()
    else:
      WinReward * loserTeams
  let lossReward =
    if sim.config.scoring == PotScoring:
      -(sim.gameMap.teamCount() div loserTeams)
    else:
      LossReward
  var awardedAccounts = newSeq[bool](sim.rewardAccounts.len)
  for i in 0 ..< sim.players.len:
    let accountIndex = sim.rewardAccountForPlayer(i)
    if awardedAccounts.len < sim.rewardAccounts.len:
      awardedAccounts.setLen(sim.rewardAccounts.len)
    if accountIndex >= 0 and accountIndex < awardedAccounts.len:
      awardedAccounts[accountIndex] = true
    if sim.players[i].team == winner:
      sim.addReward(i, winReward)
      sim.recordGameWin(i)
    else:
      sim.addReward(i, lossReward)
  for i in 0 ..< sim.rewardAccounts.len:
    if i < awardedAccounts.len and awardedAccounts[i]:
      continue
    if not sim.rewardAccounts[i].hasTeam:
      continue
    if sim.rewardAccounts[i].team == winner:
      sim.rewardAccounts[i].reward += winReward
      sim.rewardAccounts[i].won = true
      inc sim.rewardAccounts[i].wins[sim.rewardAccounts[i].team]
    else:
      sim.rewardAccounts[i].reward += lossReward

proc maxTicksReached(sim: SimServer): bool =
  ## Whether the scheduled draw ceiling ends the game this tick. A game
  ## with the grenade barrage configured has NO draw ceiling: past the
  ## deadline the clock reads 0:00 and the full-intensity bombardment
  ## grinds on until at most one team stands (GV41) — a draw then needs
  ## the last players of two teams to die on the same tick.
  sim.config.barrageMaxPerSec <= 0 and
    sim.config.maxTicks > 0 and sim.phase == Playing and
    sim.gameTicksElapsed() >= sim.effectiveMaxTicks()

proc teamLivesRemaining*(sim: SimServer, team: Team): int =
  ## Returns total lives remaining (alive players count their current life).
  ## Kept for the broadcast scorebug + momentum series (upstream dropped it as
  ## unused; the replay chrome still reads it).
  for p in sim.players:
    if p.team != team:
      continue
    result += p.lives
    if p.alive:
      inc result

proc flagCarryProgress*(sim: SimServer, flagTeam: Team): int =
  ## Returns how far one team's STOLEN flag has been advanced from its
  ## pedestal toward its carrier's home; 0 while it sits home. (0.7.0
  ## relabels the flag a "heart" in art/copy, but the carry-to-home
  ## mechanic is unchanged.) Sides maps keep the classic x-displacement
  ## measure; corner and plus layouts use straight-line displacement.
  let flag = sim.flags[flagTeam]
  if flag.carrier < 0:
    return 0
  let
    carrierTeam = sim.players[flag.carrier].team
    home = sim.gameMap.flagHome(flagTeam)
  let progress =
    case sim.gameMap.layout
    of layoutSides:
      if carrierTeam == Red:
        home.x - flag.x
      else:
        flag.x - home.x
    of layoutCorners, layoutPlus:
      let
        anchor = sim.gameMap.teamAnchor(carrierTeam)
        d0 = sqrt(float(distSq(home.x, home.y, anchor.x, anchor.y)))
        d = sqrt(float(distSq(flag.x, flag.y, anchor.x, anchor.y)))
      int(d0 - d)
  max(0, progress)

proc teamFlagProgress*(sim: SimServer, team: Team): int =
  ## Returns how far this team has advanced a stolen enemy flag toward its
  ## own home; 0 when no enemy flag is on one of its players' backs.
  for flagTeam in sim.teams():
    if flagTeam == team:
      continue
    let flag = sim.flags[flagTeam]
    if flag.carrier < 0 or sim.players[flag.carrier].team != team:
      continue
    result = max(result, sim.flagCarryProgress(flagTeam))

proc teamHasLivePlayers(sim: SimServer, team: Team): bool =
  ## Returns true when a team still has a player who can act this round.
  for p in sim.players:
    if p.team == team and (p.alive or p.lives > 0):
      return true
  false

proc shouldAbortFiniteMatch*(sim: SimServer): bool =
  ## Returns true when a finite match cannot continue after roster loss.
  if sim.config.maxGames <= 0:
    return false
  if sim.phase == Lobby:
    return sim.startWaitTimer > 0 and sim.players.len < sim.config.minPlayers
  sim.phase == Playing and sim.players.len == 0

proc lobbyJoinTimedOut*(sim: SimServer): bool =
  ## Returns true when a finite match waited out its lobby-join budget with
  ## the roster still short of minPlayers. Joins are strictly slot-sequential
  ## (`nextPlayerSlot`), so at timeout the stuck seat is exactly
  ## `sim.nextPlayerSlot()` — the caller declares that seat's failure to the
  ## platform (player_failure.json) so the no-show is charged to the policy
  ## that never joined instead of poisoning the episode unattributed.
  sim.config.maxGames > 0 and
    sim.config.lobbyJoinTimeoutTicks > 0 and
    sim.phase == Lobby and
    sim.players.len < sim.config.minPlayers and
    sim.lobbyWaitTimer >= sim.config.lobbyJoinTimeoutTicks

proc eliminateTeam(sim: var SimServer, team: Team, killerIndex: int) =
  ## GV32: removes a team from play after its heart is captured — every
  ## player dies with no respawn. A heart an eliminated player was carrying
  ## goes home via the normal killPlayer flag return; the eliminated team's
  ## own heart is retired by the capture site, not here. GV35: these are
  ## `elimination` deaths — the team lost, nobody was killed — so the
  ## deaths stat stays untouched and the endscreen stats stay combat-only.
  sim.logGameEvent(teamText(team) & " eliminated")
  for i in 0 ..< sim.players.len:
    if sim.players[i].team != team:
      continue
    sim.players[i].lives = 0
    sim.players[i].respawnTimer = 0
    if sim.players[i].alive:
      sim.killPlayer(i, killerIndex, elimination = true)

proc hatchBrood(sim: var SimServer, team: Team): bool =
  ## Activates one connected reserve policy at the queen's nest. Seats that
  ## have never hatched are preferred, then dead workers may be reborn; the
  ## queen herself is never a brood candidate.
  let queen = sim.queenIndex(team)
  var candidate = -1
  for pass in 0 .. 1:
    for i, player in sim.players:
      if i == queen or player.team != team or player.alive:
        continue
      if pass == 0 and player.deaths > 0:
        continue
      if candidate < 0 or player.joinOrder < sim.players[candidate].joinOrder:
        candidate = i
    if candidate >= 0:
      break
  if candidate < 0:
    return false
  let spawn = sim.randomEndzonePosition(team)
  sim.placePlayer(candidate, spawn.x, spawn.y)
  sim.players[candidate].alive = true
  sim.players[candidate].lives = 0
  sim.players[candidate].respawnTimer = 0
  sim.players[candidate].hp =
    sim.config.maxHpFor(team, sim.players[candidate].perks)
  sim.players[candidate].aimBrads = sim.gameMap.spawnAimBrads(team)
  sim.players[candidate].flipH = sim.gameMap.spawnFlipH(team)
  sim.emitEvent(
    Respawn, source = candidate,
    x = float(sim.players[candidate].x + CollisionW div 2),
    y = float(sim.players[candidate].y + CollisionH div 2))
  sim.logGameEvent(
    teamText(team) & " queen hatched " & sim.playerText(candidate))
  true

proc updateColonyLifecycle*(sim: var SimServer) =
  ## Feeds queens, collapses queenless colonies, then spends only SURPLUS food
  ## on brood. A delivery on the exact hunger tick can save the queen because
  ## delivery resolution precedes this procedure.
  if not sim.config.isEmergAnt() or sim.phase != Playing:
    return
  for team in sim.teams():
    let queen = sim.queenIndex(team)
    if queen < 0:
      sim.logGameEvent(teamText(team) & " queen disconnected; colony collapsed")
      sim.eliminateTeam(team, -1)
      continue
    if sim.players[queen].alive:
      while sim.tickCount >= sim.queenFeedAt[team]:
        if sim.colonyFood[team] < QueenUpkeepFoodCost:
          sim.logGameEvent(teamText(team) & " queen starved; colony collapsed")
          sim.killPlayer(queen, -1, cause = "starved")
          break
        sim.colonyFood[team] -= QueenUpkeepFoodCost
        sim.queenFeedAt[team] += QueenUpkeepTicks
        sim.logGameEvent(
          teamText(team) & " queen fed; " & $sim.colonyFood[team] &
            " food remains")
    if not sim.players[queen].alive:
      sim.logGameEvent(teamText(team) & " queen lost; colony collapsed")
      sim.eliminateTeam(team, -1)
      continue
    while sim.colonyFood[team] >= QueenFoodReserve + BroodFoodCost:
      if not sim.hatchBrood(team):
        break
      sim.colonyFood[team] -= BroodFoodCost

proc updatePuddles*(sim: var SimServer) =
  ## One tick of the paint-puddle hazard: every full second (PuddleRollTicks
  ## ticks) a cog's center spends CONTINUOUSLY inside a puddle rolls a
  ## puddleDamagePct chance of 1 damage — through the shield layer first,
  ## like every weapon. Dipping out (or dying) restarts the second. The RNG
  ## draws ONLY on a completed second of occupancy, so the puddle-free path
  ## stays byte-identical across builds (changing the DEFAULT pct still
  ## bumps GV — spec-pinned puddle replays echo no pct key; see GV43).
  if ArenaPuddles.len == 0 or sim.phase != Playing:
    return
  for i in 0 ..< sim.players.len:
    if not sim.players[i].alive:
      sim.players[i].puddleTicks = 0
      continue
    if sim.playerPuddle(i) < 0:
      sim.players[i].puddleTicks = 0
      continue
    inc sim.players[i].puddleTicks
    if sim.players[i].puddleTicks < PuddleRollTicks:
      continue
    sim.players[i].puddleTicks = 0
    if sim.rng.rand(99) >= sim.config.puddleDamagePct:
      continue
    let
      px = sim.players[i].x + CollisionW div 2
      py = sim.players[i].y + CollisionH div 2
      bubbleUp = sim.players[i].hasShield and sim.players[i].shieldHp > 0
      blocked = sim.absorbDamage(i, 1)
    # Puddle paint marks the body the same way weapon paint does — unless
    # the shield bubble ate the hit (a bubble dent draws no body paint).
    if not bubbleUp:
      sim.players[i].paintHitTick = sim.tickCount
    sim.emitEvent(
      Damage, source = -1, target = i, weapon = "puddle",
      amount = 1, hp = max(0, sim.players[i].hp),
      blocked = blocked,
      x = float(px), y = float(py)
    )
    # A floating "-1" rises from the victim so the hazard's bite reads at a
    # glance (cosmetic only, never in gameHash).
    sim.damagePops.add DamageFx(
      x: px, y: py,
      tick: sim.tickCount,
      amount: 1,
      color: sim.players[i].color
    )
    if sim.players[i].hp <= 0:
      sim.killPlayer(i, -1, cause = "dissolved in a paint puddle")

proc launchBarrageShell(sim: var SimServer) =
  ## Launches one environment grenade: the landing point is drawn from the
  ## deterministic sim RNG inside the current target band (within
  ## barrageDepth of some map edge), and the shell arcs in from the nearest
  ## point of that edge with the same fixed fuse a player lob has. Thrower
  ## -1 marks it environmental: no kill credit, no rewards, no multi-kills.
  let
    depth = max(1, sim.barrageDepth())
    side = sim.rng.rand(3)
    inset = sim.rng.rand(depth - 1)
  var tx, ty, sx, sy: int
  case side
  of 0:                                  # north edge, raining downward.
    tx = sim.rng.rand(MapWidth - 1)
    ty = inset
    sx = tx
    sy = 0
  of 1:                                  # south edge.
    tx = sim.rng.rand(MapWidth - 1)
    ty = MapHeight - 1 - inset
    sx = tx
    sy = MapHeight - 1
  of 2:                                  # west edge.
    ty = sim.rng.rand(MapHeight - 1)
    tx = inset
    sx = 0
    sy = ty
  else:                                  # east edge.
    ty = sim.rng.rand(MapHeight - 1)
    tx = MapWidth - 1 - inset
    sx = MapWidth - 1
    sy = ty
  tx = clamp(tx, ArenaBorder + 2, MapWidth - ArenaBorder - 2)
  ty = clamp(ty, ArenaBorder + 2, MapHeight - ArenaBorder - 2)
  sim.airborneGrenades.add AirborneGrenade(
    sx: sx,
    sy: sy,
    tx: tx,
    ty: ty,
    launchTick: sim.tickCount,
    flightTicks: max(1, GrenadeFlightMultiple * sim.config.fireWindupTicks),
    thrower: -1,
    throwerSlot: -1,
    throwerAccount: -1
  )

proc updateBarrage*(sim: var SimServer) =
  ## One tick of the grenade-barrage endgame: latch when the game clock
  ## drops to barrageStartSec remaining, then rain environment grenades —
  ## barrageStartPerSec along the map edges at first, ramping linearly to
  ## barrageMaxPerSec across the whole board as the escalation completes
  ## (barrageProgressPermille). The shells land through the ordinary
  ## grenade pipeline, so blast kills bank action-floor overtime; the
  ## latched barrage only ever escalates through the extension, so a timed
  ## game ends on a wipe or capture instead of a timeout draw.
  if sim.config.barrageMaxPerSec <= 0 or sim.config.maxTicks <= 0:
    return
  if sim.phase != Playing:
    return
  if sim.barrageStartTick < 0:
    let remaining = sim.effectiveMaxTicks() - sim.gameTicksElapsed()
    if remaining <= sim.config.barrageStartSec * TargetFps:
      sim.barrageStartTick = sim.tickCount
      sim.barrageAccum = 0
      sim.logGameEvent("grenade barrage incoming")
    return
  # Fractional launch pacing: the rate is permille grenades/second, one
  # grenade costs TargetFps*1000 accumulator units, so any integer rate
  # spreads its launches evenly with zero drift.
  const UnitsPerGrenade = TargetFps * 1000
  sim.barrageAccum += sim.barrageRatePermille()
  while sim.barrageAccum >= UnitsPerGrenade:
    sim.barrageAccum -= UnitsPerGrenade
    # The drawn-orb pool holds MaxPlayers in-flight grenades; at the config
    # ceiling (BarrageAbsMaxPerSec x the ~10-tick fuse) the barrage stays
    # well inside it, so this cap is a belt-and-suspenders skip, and the
    # accumulator still drains so a capped stretch never banks a burst.
    if sim.airborneGrenades.len < MaxPlayers:
      sim.launchBarrageShell()

proc checkEmergAntWinCondition(sim: var SimServer) =
  ## Neutral-patch foraging: every carried food returned home scores one, then
  ## its emptied patch regrows after the configured delay. All deliveries on this tick
  ## resolve before the goal check, so simultaneous finishes draw rather than
  ## inheriting enum/player processing order.
  for foodTeam in sim.teams():
    let carrierIndex = sim.flags[foodTeam].carrier
    if carrierIndex < 0 or carrierIndex >= sim.players.len or
        not sim.players[carrierIndex].alive:
      continue
    let
      carrier = sim.players[carrierIndex]
      zone = sim.captureZone(carrier.team)
      cx = carrier.x + CollisionW div 2
      cy = carrier.y + CollisionH div 2
    if not zone.inCaptureZone(cx, cy):
      continue
    sim.recordCapture(carrierIndex)
    sim.colonyFood[carrier.team] += 1
    sim.emitEvent(Capture, source = carrierIndex, x = float(cx), y = float(cy))
    sim.logGameEvent(
      teamText(carrier.team) & " delivered neutral food (" &
        $sim.teamForageScore(carrier.team) & "/" &
        $sim.config.forageGoal & ")"
    )
    sim.players[carrierIndex].carryingFlag = false
    sim.flags[foodTeam].carrier = -1
    sim.flags[foodTeam].captured = true
    sim.flags[foodTeam].respawnAt = sim.tickCount + sim.config.foodRespawnTicks

  sim.updateColonyLifecycle()

  var
    leaders: seq[Team] = @[]
    best = -1
  for team in sim.teams():
    let score = sim.teamForageScore(team)
    if score > best:
      best = score
      leaders = @[team]
    elif score == best:
      leaders.add(team)
  if best >= sim.config.forageGoal:
    if leaders.len == 1:
      sim.finishGame(leaders[0])
    else:
      sim.finishGame(Red, isDraw = true)
    return

  # Combat can still end the race when only one colony has ants left.
  var
    aliveCount = 0
    lastAlive = Red
  for team in sim.teams():
    if sim.teamHasLivePlayers(team):
      inc aliveCount
      lastAlive = team
  if aliveCount == 1:
    sim.finishGame(lastAlive)
  elif aliveCount == 0:
    sim.finishGame(Red, isDraw = true)

proc checkWinCondition*(sim: var SimServer) {.measure.} =
  ## Resolves capture and wipe win conditions.
  if sim.phase != Playing or sim.players.len == 0:
    return
  if sim.config.isEmergAnt():
    sim.checkEmergAntWinCondition()
    return
  # Capture: a living carrier bringing an enemy flag into their own home
  # capture zone (deliberately no own-flag-must-be-home precondition).
  # GV32: a capture ELIMINATES the captured team instead of ending the game
  # outright — the heart leaves play where it was captured and every player
  # on the captured team dies for good. The game then ends below when at
  # most one team still stands, so a 4-team winner either captures every
  # rival heart or outlives the field; classic 2-team play still ends on
  # the first capture (eliminating the only rival leaves one team).
  for flagTeam in sim.teams():
    let carrierIndex = sim.flags[flagTeam].carrier
    if carrierIndex < 0 or carrierIndex >= sim.players.len or
        not sim.players[carrierIndex].alive:
      continue
    let
      carrier = sim.players[carrierIndex]
      zone = sim.captureZone(carrier.team)
      cx = carrier.x + CollisionW div 2
      cy = carrier.y + CollisionH div 2
    if zone.inCaptureZone(cx, cy):
      sim.recordCapture(carrierIndex)
      sim.emitEvent(
        Capture, source = carrierIndex,
        x = float(cx), y = float(cy)
      )
      sim.logGameEvent(
        teamText(carrier.team) & " captured the " & teamText(flagTeam) & " heart"
      )
      sim.flags[flagTeam].captured = true
      sim.flags[flagTeam].carrier = -1
      sim.players[carrierIndex].carryingFlag = false
      sim.eliminateTeam(flagTeam, carrierIndex)
  # GV33: a completely killed team's heart leaves play with it. A wiped
  # team can never recover its heart, so it retires the moment the team is
  # gone — even off the back of an enemy carrier, who drops it (recovering
  # full speed and fire rate) rather than lugging an objective that can no
  # longer score. Capture-eliminated teams take the branch above; hearts
  # the wiped team itself was carrying already went home via killPlayer.
  for team in sim.teams():
    if sim.flags[team].captured or sim.teamHasLivePlayers(team):
      continue
    let carrier = sim.flags[team].carrier
    if carrier >= 0:
      sim.players[carrier].carryingFlag = false
      sim.flags[team].carrier = -1
    sim.flags[team].captured = true
    sim.logGameEvent(teamText(team) & " heart retired")
  # Wipe: the game ends when at most one team still has live players — the
  # survivor wins, and a mutual wipe is a draw. A 4-team game continues
  # while two or more teams stand; a wiped team just stays out. Classic
  # 2-team behavior is the two-team case of the same rule.
  var
    aliveCount = 0
    lastAlive = Red
  for team in sim.teams():
    if sim.teamHasLivePlayers(team):
      inc aliveCount
      lastAlive = team
  if aliveCount == 1:
    sim.finishGame(lastAlive)
  elif aliveCount == 0:
    sim.finishGame(Red, isDraw = true)

proc checkMaxTicks(sim: var SimServer) =
  ## A game that hits the time limit before a capture or a wipe is a
  ## scoreless draw for both sides: no tiebreak, no rewards.
  if not sim.maxTicksReached():
    return
  if sim.config.isEmergAnt():
    var
      best = -1
      leader = Red
      tied = false
    for team in sim.teams():
      let score = sim.teamForageScore(team)
      if score > best:
        best = score
        leader = team
        tied = false
      elif score == best:
        tied = true
    if not tied:
      sim.finishGame(leader, timeLimitReached = true)
    else:
      sim.finishGame(Red, isDraw = true, timeLimitReached = true)
    return
  sim.finishGame(Red, isDraw = true, timeLimitReached = true)

proc decodeGridFont(image: Image, cellW, cellH, cols: int,
    spacing = 1): PixelFont =
  ## Decodes a fixed-cell monospace ASCII sheet (ascii.png: cellW x cellH cells
  ## laid out `cols` per row, starting at ASCII 32) into a PixelFont. Unlike
  ## decodePixelFont there is no yellow marker row: each glyph is the cell's
  ## white ink, trimmed to its own ink width so the font stays proportional.
  ## Used only for shout bubbles, which want a chunkier, taller face than the
  ## 6px tiny5 HUD font so the text reads at full desktop size.
  result.height = cellH
  result.spacing = spacing
  proc ink(x, y: int): bool =
    if x < 0 or y < 0 or x >= image.width or y >= image.height:
      return false
    let p = image[x, y]
    p.a > 20'u8 and p.r >= 120'u8 and p.g >= 120'u8 and p.b >= 120'u8
  for code in FirstPrintableAscii .. LastPrintableAscii:
    let
      idx = code - FirstPrintableAscii
      cx = (idx mod cols) * cellW
      cy = (idx div cols) * cellH
    var minX = cellW
    var maxX = -1
    for gx in 0 ..< cellW:
      for gy in 0 ..< cellH:
        if ink(cx + gx, cy + gy):
          minX = min(minX, gx)
          maxX = max(maxX, gx)
          break
    # A blank cell (e.g. the space) gets a fixed narrow advance.
    let width = if maxX < 0: max(1, cellW div 2) else: maxX - minX + 1
    let start = if maxX < 0: 0 else: minX
    var glyph = PixelGlyph(ch: char(code), width: width, height: cellH)
    glyph.pixels = newSeq[bool](width * cellH)
    if maxX >= 0:
      for gy in 0 ..< cellH:
        for gx in 0 ..< width:
          glyph.pixels[gy * width + gx] = ink(cx + start + gx, cy + gy)
    result.glyphs.add(glyph)

proc loadShoutFont(): PixelFont =
  ## Loads the chunky 7x9 grid font used for shout bubbles.
  decodeGridFont(readImage(gameDir() / "data" / "ascii.png"), 7, 9, 18)

## ---------------------------------------------------------------------------
## Spinning center diamonds — LIVE geometry (GV28).
## The art turns them, so the sim turns them too: what a player sees is what
## blocks their feet, their bullets, and their eyes. Only the sixteen frames of
## a quarter turn exist (a diamond is 4-fold symmetric), and only the pixels
## inside each diamond's circumscribed square can ever change, so a frame
## advance restamps ~8 small boxes — not the map.
## ---------------------------------------------------------------------------

proc initDiamondPatches(sim: var SimServer) =
  ## Snapshots the diamond-free collision masks around each spinning diamond.
  ## loadMapLayers already baked them WITHOUT the diamonds, so this captures
  ## the neighbours (a stub, the border) that must survive every restamp.
  sim.diamondPatches = @[]
  for spot in AnimatedDiamonds:
    let
      pad = spot.radius + 1
      x0 = max(0, spot.cx - pad)
      y0 = max(0, spot.cy - pad)
      x1 = min(MapWidth, spot.cx + pad + 1)
      y1 = min(MapHeight, spot.cy + pad + 1)
    var patch = DiamondPatch(
      x0: x0, y0: y0, w: x1 - x0, h: y1 - y0,
      frame: -1                       # nothing stamped yet.
    )
    patch.baseWall = newSeq[bool](patch.w * patch.h)
    for py in 0 ..< patch.h:
      for px in 0 ..< patch.w:
        let index = mapIndex(patch.x0 + px, patch.y0 + py)
        patch.baseWall[py * patch.w + px] = sim.wallMask[index]
    sim.diamondPatches.add patch
  ## Pair up overlapping windows. Without this a restamp of one diamond would
  ## write `base or its own stone` over a pixel its neighbour also occupies,
  ## erasing the neighbour's stone until the neighbour happened to restamp —
  ## and applyDiamondGeometry skips a diamond whose frame has not advanced, so
  ## "the neighbour restamps too" is not guaranteed.
  for i in 0 ..< sim.diamondPatches.len:
    for j in 0 ..< sim.diamondPatches.len:
      let a = sim.diamondPatches[i]
      let b = sim.diamondPatches[j]
      if a.x0 < b.x0 + b.w and b.x0 < a.x0 + a.w and
          a.y0 < b.y0 + b.h and b.y0 < a.y0 + a.h:
        sim.diamondPatches[i].neighbours.add j

proc refreshFovCells(sim: var SimServer, x0, y0, x1, y1: int) =
  ## Rebuilds the fog occlusion cells covering one map box from the live wall
  ## mask, on the same rule as buildFovBlocked (opaque when at least half the
  ## cell is wall) and with the same window exemption — glass never occludes.
  ##
  ## The glass test reads the precomputed windowMask rather than calling
  ## isArenaWindowPixel: that proc scans all ~70 ArenaObstacles twice per
  ## pixel, and this runs over ~41k pixels every time the spin advances. Doing
  ## it live cost ~5.4 ms per frame advance — more than three whole ticks —
  ## for a fact that never changes after the bake.
  let
    gx0 = clamp(x0 div FovCellSize, 0, FovGridW - 1)
    gx1 = clamp((x1 - 1) div FovCellSize, 0, FovGridW - 1)
    gy0 = clamp(y0 div FovCellSize, 0, FovGridH - 1)
    gy1 = clamp((y1 - 1) div FovCellSize, 0, FovGridH - 1)
  for gy in gy0 .. gy1:
    for gx in gx0 .. gx1:
      var
        walls = 0
        pixels = 0
      for py in gy * FovCellSize ..< min((gy + 1) * FovCellSize, MapHeight):
        for px in gx * FovCellSize ..< min((gx + 1) * FovCellSize, MapWidth):
          let index = mapIndex(px, py)
          inc pixels
          if sim.wallMask[index] and not sim.windowMask[index]:
            inc walls
      sim.fovBlocked[fovCellIndex(gx, gy)] = walls * 2 >= pixels

proc stampDiamondPatch(sim: var SimServer, index, frame: int) =
  ## Writes one diamond's rotated footprint into the movement, bullet, and
  ## vision masks: base OR stone, never a differential against the previous
  ## frame, so a restamp can neither leak old stone nor erase a neighbour.
  ## The OR runs over every diamond sharing this window, each at ITS OWN
  ## current frame, so the write is idempotent and order-independent.
  sim.diamondPatches[index].frame = frame
  let
    x0 = sim.diamondPatches[index].x0
    y0 = sim.diamondPatches[index].y0
    w = sim.diamondPatches[index].w
    h = sim.diamondPatches[index].h
  ## This runs ~4k pixels per window per frame advance, so the lone-diamond
  ## case — every window on both authored arenas — gets a loop with the shape
  ## in locals and no allocation. Resolving it out of a seq instead costs
  ## roughly a quarter of a tick.
  template stampLoop(covers: untyped) =
    for py in 0 ..< h:
      for px in 0 ..< w:
        let
          x {.inject.} = x0 + px
          y {.inject.} = y0 + py
          mapAt = mapIndex(x, y)
        var stone = sim.diamondPatches[index].baseWall[py * w + px]
        if not stone:
          stone = covers
        sim.wallMask[mapAt] = stone
        sim.walkMask[mapAt] = not stone

  if sim.diamondPatches[index].neighbours.len == 1:
    let spot = AnimatedDiamonds[index]
    stampLoop(animatedDiamondCovers(spot, frame, x, y))
  else:
    var live: seq[tuple[spot: tuple[cx, cy, radius: int], frame: int]]
    for other in sim.diamondPatches[index].neighbours:
      live.add((AnimatedDiamonds[other], sim.diamondPatches[other].frame))
    stampLoop(block:
      var hit = false
      for d in live:
        if animatedDiamondCovers(d.spot, d.frame, x, y):
          hit = true
          break
      hit)
  sim.refreshFovCells(x0, y0, x0 + w, y0 + h)

proc applyDiamondGeometry*(sim: var SimServer, tick: int): bool
    {.discardable.} =
  ## Brings every spinning diamond's geometry to the frame `tick` shows.
  ## Returns true when any of them turned. The frame comes from
  ## diamondSpinFrame — the same call the renderer makes — so geometry and art
  ## are the same shape by construction, and a replay re-derives both.
  ##
  ## The bool is not decoration: it is the only signal that someone may now be
  ## standing inside stone. Production code should go through
  ## updateAnimatedDiamonds, which acts on it. The two callers that discard it
  ## (initSimServer, resetToLobby) may only do so because the roster is empty
  ## at that point — any new caller under a live roster owes a push-out.
  ##
  ## Every frame is published BEFORE anything is stamped: a window ORs the
  ## neighbours it overlaps at THEIR current frames, so stamping mid-update
  ## would write a shared pixel against a stale angle.
  ## No allocation on either pass: this runs every tick, and three ticks in
  ## four nothing has moved.
  for index in 0 ..< sim.diamondPatches.len:
    let frame = diamondSpinFrame(
      AnimatedDiamonds[index].cx, AnimatedDiamonds[index].cy, tick)
    if frame == sim.diamondPatches[index].frame:
      continue
    sim.diamondPatches[index].frame = frame
    sim.diamondPatches[index].dirty = true
    result = true
  if not result:
    return
  for index in 0 ..< sim.diamondPatches.len:
    if not sim.diamondPatches[index].dirty:
      continue
    sim.diamondPatches[index].dirty = false
    sim.stampDiamondPatch(index, sim.diamondPatches[index].frame)
  if result:
    ## Vision was computed against the old stone; every viewer re-casts.
    for i in 0 ..< sim.fovCaches.len:
      sim.fovCaches[i].valid = false

proc restampDiamondGeometry*(sim: var SimServer) =
  ## Rewrites every spinning diamond's footprint into the collision and
  ## vision masks at the frame the patches already hold. Exists for keyframe
  ## restores (deserializeReplaySim): the walk/wall/fov masks arrive from a
  ## donor sim whose stamps are at the DONOR tick's spin frame, while the
  ## restored diamondPatches carry the keyframe tick's frames — and
  ## applyDiamondGeometry skips a diamond whose frame "has not changed", so
  ## the donor's stale stone would otherwise survive any seek whose target
  ## sits inside the restored keyframe's spin frame — fewer than
  ## DiamondSpinTicksPerFrame ticks stepped after the restore, so no stepped
  ## tick advances the spin and nothing restamps. Each stamp writes base OR
  ## stone over the whole window, so this cleans any foreign footprint the
  ## donor left behind.
  ##
  ## fovCaches are deliberately NOT invalidated: on the keyframe path the
  ## restored caches were recorded against the very masks this restamp
  ## reproduces, so they are valid by construction. A future caller whose
  ## caches were built against OTHER masks must invalidate them itself.
  for index in 0 ..< sim.diamondPatches.len:
    if sim.diamondPatches[index].frame < 0:
      continue                          # nothing stamped yet.
    sim.stampDiamondPatch(index, sim.diamondPatches[index].frame)

proc nearestFreeBody(
  sim: SimServer, playerIndex, x, y: int
): tuple[x, y: int, found: bool] =
  ## The nearest cell where player `playerIndex` can stand without overlapping
  ## any OTHER live body, via the same deterministic expanding ring search as
  ## nearestWalkable. Unlike that one it reports failure instead of handing
  ## back the blocked point it was asked to escape.
  for r in 0 .. max(MapWidth, MapHeight):
    for dy in -r .. r:
      for dx in -r .. r:
        if r > 0 and abs(dx) != r and abs(dy) != r:
          continue
        let
          nx = x + dx
          ny = y + dy
        if not sim.canOccupy(nx, ny):
          continue
        var clear = true
        for j in 0 ..< sim.players.len:
          if j == playerIndex or not sim.players[j].alive:
            continue
          if max(abs(sim.players[j].x - nx), abs(sim.players[j].y - ny)) <=
              PlayerSolidSpan:
            clear = false
            break
        if clear:
          return (nx, ny, true)
  (x, y, false)

proc sweptByDiamond(sim: SimServer, px, py: int): bool =
  ## True when any pixel of the player box at (px, py) is inside a spinning
  ## diamond's CURRENT footprint — i.e. the stone moved onto them, rather than
  ## their being unable to stand for some unrelated reason.
  for spot in AnimatedDiamonds:
    let frame = diamondSpinFrame(spot.cx, spot.cy, sim.tickCount)
    for dy in -PlayerHalf .. PlayerHalf:
      for dx in -PlayerHalf .. PlayerHalf:
        if animatedDiamondCovers(spot, frame, px + dx, py + dy):
          return true
  false

proc pushPlayersOutOfDiamonds(sim: var SimServer) =
  ## A turning diamond can sweep over someone hugging its edge. Standing
  ## inside stone would make a player unshootable from one side and unable to
  ## walk out, so the sweep displaces them to the nearest free floor. The ring
  ## search is deterministic, so replays and clients agree.
  ##
  ## Players are displaced in index order and each lands clear of every other
  ## live body, so two players caught by the same sweep cannot be handed the
  ## same pixel — overlapping bodies are a state the rest of the game does not
  ## allow (tests/test_player_collision.nim).
  for i in 0 ..< sim.players.len:
    if not sim.players[i].alive:
      continue
    let
      px = sim.players[i].x
      py = sim.players[i].y
    if sim.canOccupy(px, py):
      continue
    if not sim.sweptByDiamond(px, py):
      continue
    let free = sim.nearestFreeBody(i, px, py)
    if free.found:
      sim.placePlayer(i, free.x, free.y)
    else:
      ## No standable floor anywhere on the map. Unreachable on every shipped
      ## map (measured: the whole sweep displaces by at most 2 px), but
      ## leaving someone embedded in stone is a silent, self-perpetuating
      ## trap — send them to their protected home pocket, and say so.
      sim.logGameEvent(
        "diamond sweep found no free floor for player " & $i & "; sent home")
      sim.resetPlayerToHome(i)

proc updateAnimatedDiamonds*(sim: var SimServer) =
  ## One tick of diamond rotation: geometry first, then anyone it engulfed.
  if sim.applyDiamondGeometry(sim.tickCount):
    sim.pushPlayersOutOfDiamonds()

proc initSimServer*(config: GameConfig): SimServer =
  result.config = config
  result.rng = initRand(config.seed)
  loadPalette(clientDataDir() / "pallete.png")
  result.asciiSprites = readTiny5Font()
  result.shoutFont = loadShoutFont()

  let sheet = loadSpriteSheet()
  result.crewSprites = loadCrewSprites()
  # Reuse the former task-icon cell as the flag sprite.
  result.flagSprite = spriteFromImage(
    sheet.subImage(SpriteSize * 4, 0, SpriteSize, SpriteSize)
  )

  result.gameMap = loadCtfMap(config)
  result.rooms = result.gameMap.rooms

  let (mapImage, walkImage, wallImage) = loadMapLayers(result.gameMap)
  result.mapPixels = newSeq[uint8](MapWidth * MapHeight)
  result.mapRgba = newSeq[uint8](MapWidth * MapHeight * 4)
  result.darkBgPixels = loadDarkBgPixels()
  for y in 0 ..< MapHeight:
    for x in 0 ..< MapWidth:
      let
        pixel = mapImage[x, y]
        index = mapIndex(x, y)
        offset = index * 4
      result.mapPixels[index] = nearestPaletteIndex(pixel)
      result.mapRgba[offset] = pixel.r
      result.mapRgba[offset + 1] = pixel.g
      result.mapRgba[offset + 2] = pixel.b
      result.mapRgba[offset + 3] = pixel.a

  result.walkMask = newSeq[bool](MapWidth * MapHeight)
  for y in 0 ..< MapHeight:
    for x in 0 ..< MapWidth:
      let pixel = walkImage[x, y]
      result.walkMask[mapIndex(x, y)] = pixel.a > 0

  result.wallMask = newSeq[bool](MapWidth * MapHeight)
  for y in 0 ..< MapHeight:
    for x in 0 ..< MapWidth:
      let pixel = wallImage[x, y]
      result.wallMask[mapIndex(x, y)] = pixel.a > 0

  ## The fog occlusion grid builds from the OPAQUE walls only: glass window
  ## pixels stay in wallMask (movement/bullets/spray cones) but drop out here, so
  ## shadowcasting sees straight through every window.
  ##
  ## Which pixels are glass is fixed by the bake and never moves, so it is
  ## resolved ONCE here into windowMask. refreshFovCells re-derives occlusion
  ## for the boxes a turning diamond touches and reads that mask instead of
  ## re-running the O(obstacles) predicate per pixel. (Glass is never part of
  ## a spinning diamond — windows are stub shapes out on column 1 — so a live
  ## diamond can add wall over a window pixel but can never create or destroy
  ## one.)
  result.windowMask = newSeq[bool](MapWidth * MapHeight)
  var opaqueMask = result.wallMask
  block:
    let
      cx = result.gameMap.center.x
      cy = result.gameMap.center.y
    ## Only a window shape's own footprint can hold glass, so the sweep runs
    ## over those few boxes instead of asking isArenaWindowPixel (a full
    ## obstacle scan) at every map pixel.
    for shape in ArenaObstacles:
      if not shape.window:
        continue
      let
        bounds = shapeBounds(shape)
        x0 = max(bounds.x0, 0)
        y0 = max(bounds.y0, 0)
        x1 = min(bounds.x1, MapWidth - 1)
        y1 = min(bounds.y1, MapHeight - 1)
      for y in y0 .. y1:
        for x in x0 .. x1:
          if inShape(x, y, shape) and isArenaWall(x, y, cx, cy):
            let index = mapIndex(x, y)
            result.windowMask[index] = true
            opaqueMask[index] = false
  result.fovBlocked = buildFovBlocked(opaqueMask)
  ## The bake left the spinning diamonds OUT of every collision layer; snapshot
  ## that diamond-free ground truth, then stamp tick 0's rotation over it. From
  ## here the masks track the art (updateAnimatedDiamonds, every step).
  result.initDiamondPatches()
  discard result.applyDiamondGeometry(0)   # no roster yet: nobody to push out.
  result.fovCaches = @[]
  result.players = @[]
  result.nextJoinOrder = 0
  result.gameStartTick = -1
  result.startWaitTimer = 0
  result.lobbyWaitTimer = 0
  result.barrageStartTick = -1
  result.barrageAccum = 0
  result.gameEventLoggingEnabled = true
  result.resetFlags()
  result.resetGrenades()
  result.resetMedKits()
  result.resetShields()
  result.resetPlasmaArcs()
  result.resetBarriers()
  result.pheromones = @[]
  result.lastLobbyPlayersLogged = -1
  result.lastLobbyNeededLogged = -1
  result.lastLobbySecondsLogged = -1

proc resetToLobby*(sim: var SimServer) =
  if sim.phase != Lobby:
    sim.emitPhaseChange(Lobby)
  sim.phase = Lobby
  sim.players = @[]
  sim.fovCaches = @[]
  ## Rewind the spin BEFORE anything snaps to walkable floor. The pickup
  ## resets below all nudge their spawns through nearestWalkable, which reads
  ## the live walk mask — if the diamonds were still stamped at the frame the
  ## last game ended on, a pickup could be nudged clear of stone that is about
  ## to move and land inside the stone the new game starts with. (Safe to run
  ## with the roster already emptied above: no one is left to be engulfed, so
  ## the displacement pass this returns true for has nothing to do.)
  sim.tickCount = 0
  discard sim.applyDiamondGeometry(0)
  sim.resetGrenades()
  sim.resetMedKits()
  sim.resetShields()
  sim.resetPlasmaArcs()
  sim.resetBarriers()
  sim.recentBlasts = @[]
  sim.plasmaArcFlashes = @[]
  sim.recentShouts = @[]
  sim.recentShots = @[]
  sim.hitFlashes = @[]
  sim.bubbleImpacts = @[]
  sim.splatters = @[]
  sim.paintStains = @[]
  sim.diamondStains = @[]
  sim.damagePops = @[]
  sim.pheromones = @[]
  sim.nextJoinOrder = 0
  sim.gameStartTick = -1
  sim.startWaitTimer = 0
  sim.lobbyWaitTimer = 0
  sim.timeLimitReached = false
  sim.barrageStartTick = -1
  sim.barrageAccum = 0
  sim.isDraw = false
  sim.needsReregister = true
  sim.resetFlags()
  sim.lastLobbyPlayersLogged = -1
  sim.lastLobbyNeededLogged = -1
  sim.lastLobbySecondsLogged = -1
  for account in sim.rewardAccounts.mitems:
    account.hasTeam = false
    account.won = false
    account.abandoned = false

proc stepLobby(sim: var SimServer) {.measure.} =
  ## Advances the lobby start countdown.
  if sim.players.len < sim.config.minPlayers:
    sim.startWaitTimer = 0
    if sim.config.maxGames > 0 and sim.config.lobbyJoinTimeoutTicks > 0:
      # Join-budget clock: only finite (league-shaped) matches, only while the
      # roster is actually short, and only on lobby ticks — bake/setup time
      # before the loop starts stepping never counts against the budget.
      inc sim.lobbyWaitTimer
    sim.logLobbyWaiting()
    return
  if sim.config.startWaitTicks <= 0:
    sim.startGame()
    return
  if sim.startWaitTimer <= 0:
    sim.startWaitTimer = sim.config.startWaitTicks
  dec sim.startWaitTimer
  if sim.startWaitTimer <= 0:
    sim.startGame()
  else:
    sim.logLobbyCountdown()

proc respawnPlayers(sim: var SimServer) =
  ## Ticks respawn timers and brings dead players back at a random spot in
  ## their endzone, so a fixed respawn point can't be camped.
  for i in 0 ..< sim.players.len:
    if sim.players[i].alive:
      continue
    if sim.players[i].lives <= 0:
      continue
    if sim.players[i].respawnTimer > 0:
      dec sim.players[i].respawnTimer
      if sim.players[i].respawnTimer <= 0:
        let spawn = sim.randomEndzonePosition(sim.players[i].team)
        sim.placePlayer(i, spawn.x, spawn.y)
        sim.players[i].alive = true
        sim.players[i].hp =
          sim.config.maxHpFor(sim.players[i].team, sim.players[i].perks)
        sim.players[i].aimBrads = sim.gameMap.spawnAimBrads(sim.players[i].team)
        sim.players[i].flipH = sim.gameMap.spawnFlipH(sim.players[i].team)
        sim.emitEvent(
          Respawn, source = i,
          x = float(sim.players[i].x + CollisionW div 2),
          y = float(sim.players[i].y + CollisionH div 2)
        )

template pruneAgedFx(sim: var SimServer, fxField, tickField: untyped,
    life: untyped) =
  ## Keeps the entries of one aged FX/state seq that are younger than `life`
  ## ticks (the entry is in scope as `fx` inside the `life` expression, for
  ## per-entry lifetimes). Same copy-filter shape every pruned seq used.
  var kept: typeof(sim.fxField) = @[]
  for fx {.inject.} in sim.fxField:
    if sim.tickCount - fx.tickField < life:
      kept.add fx
  sim.fxField = kept

proc step*(
  sim: var SimServer,
  inputs: openArray[InputState],
  prevInputs: openArray[InputState]
) {.measure.} =
  inc sim.tickCount

  # The center diamonds turn BEFORE anything moves or fires this tick, so
  # movement, bullets, and vision all resolve against the geometry the tick
  # renders — never against last tick's stone.
  sim.updateAnimatedDiamonds()

  # Roster-driven transitions belong inside the deterministic step: leaves
  # are recorded and re-applied, so replays re-derive these exactly. (They
  # used to run live-only in the server loop, which made every replay with a
  # mid-match disconnect-out diverge from its recorded hashes.)
  if sim.players.len == 0 and sim.phase == Playing and sim.config.maxGames > 0:
    sim.finishGame(Red, isDraw = true, timeLimitReached = true)
  elif sim.players.len == 0 and sim.phase != Lobby:
    sim.resetToLobby()

  if sim.phase == Lobby:
    sim.stepLobby()
    return

  if sim.phase == GameOver:
    dec sim.gameOverTimer
    if sim.gameOverTimer <= 0:
      sim.resetToLobby()
    return

  # Playing: move everyone first, then resolve every shot that releases this
  # tick at once against the post-movement snapshot (no processing-order
  # advantage). A fresh trigger pull arms a windup with the aim locked at the
  # pull; the bullet leaves fireWindupTicks later from the shooter's current
  # position, so a target that ducks back behind cover survives the shot.
  var
    firing: seq[int] = @[]
    arcFiring: seq[int] = @[]
    biting: seq[int] = @[]
  for playerIndex in 0 ..< sim.players.len:
    if sim.players[playerIndex].fireCooldown > 0:
      dec sim.players[playerIndex].fireCooldown
    if not sim.config.isEmergAnt() and sim.players[playerIndex].fireWindup > 0:
      dec sim.players[playerIndex].fireWindup
      if sim.players[playerIndex].fireWindup == 0:
        firing.add(playerIndex)
    let input =
      if playerIndex < inputs.len: inputs[playerIndex]
      else: InputState()
    let prev =
      if playerIndex < prevInputs.len: prevInputs[playerIndex]
      else: InputState()
    sim.applyInput(playerIndex, input)
    if sim.config.isEmergAnt():
      if input.attack and not prev.attack:
        biting.add(playerIndex)
    else:
      sim.applyGrenadeInput(playerIndex, input, prev)
      sim.applyBarrierInput(playerIndex, input, prev)
    if not sim.config.isEmergAnt() and input.attack and not prev.attack:
      if sim.players[playerIndex].hasPlasmaArc:
        if sim.canFireArc(playerIndex):
          arcFiring.add(playerIndex)
      else:
        if sim.config.fireWindupTicks <= 0:
          if sim.canFire(playerIndex) and sim.players[playerIndex].fireWindup == 0:
            sim.startFireWindup(playerIndex)
            firing.add(playerIndex)
        else:
          sim.startFireWindup(playerIndex)
  if sim.config.isEmergAnt():
    sim.resolveContactAttacks(biting)
  else:
    sim.resolveSimultaneousFire(firing)
    for playerIndex in arcFiring:
      sim.startArcFire(playerIndex)
    sim.resolveActiveArcCones()
    sim.updateGrenades()
    sim.updateMedKits()
    sim.updateShields()
    sim.updatePlasmaArcs()
    sim.updateBarriers()

  sim.updateFoodPatches()
  for playerIndex in 0 ..< sim.players.len:
    sim.tryPickupFlags(playerIndex)
    if not sim.config.isEmergAnt():
      sim.tryPickupGrenades(playerIndex)
      sim.tryPickupMedKits(playerIndex)
      sim.tryPickupShields(playerIndex)
      sim.tryPickupPlasmaArcs(playerIndex)
      sim.tryPickupBarriers(playerIndex)
  sim.updateFlags()
  sim.respawnPlayers()
  # Puddle damage resolves after movement and pickups, before the win check,
  # so a lethal roll feeds the same tick's wipe resolution.
  sim.updatePuddles()
  if not sim.config.isEmergAnt():
    sim.updateBarrage()
  sim.updatePheromones(inputs)

  sim.checkWinCondition()
  sim.checkMaxTicks()

  # Prune expired shot tracers and splatters (cosmetic only; excluded from
  # gameHash).
  sim.pruneAgedFx(recentShots, firedTick, ShotFxTicks)
  sim.pruneAgedFx(hitFlashes, tick, HitFlashTicks)
  sim.pruneAgedFx(bubbleImpacts, tick, BubbleImpactTicks)
  sim.pruneAgedFx(recentBlasts, tick, BlastFxTicks)
  sim.pruneAgedFx(plasmaArcFlashes, tick, PlasmaArcFxTicks)

  # Expire old shouts. Unlike the cosmetic effects above, shouts are
  # observable gameplay state (bots hear them), so expiry is part of the
  # deterministic sim and the hash.
  sim.pruneAgedFx(recentShouts, tick, ShoutTicks)
  sim.pruneAgedFx(splatters, tick,
    (if fx.hit: HitFxTicks else: SplatterFxTicks))
  sim.pruneAgedFx(damagePops, tick,
    (if fx.kill: KillFxTicks else: DamageFxTicks))
