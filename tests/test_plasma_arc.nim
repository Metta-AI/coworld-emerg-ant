import
  helpers,
  std/[math, unittest],
  ctf/sim

proc stepNone(sim: var SimServer, ticks: int) =
  let input = sim.none()
  for _ in 0 ..< ticks:
    sim.step(input, input)

# The left capture column (x < 210) is protected floor — never walled — so
# arc-fire tests anchor the attacker there for guaranteed line of sight.
# A template, not a `let`: MapHeight is a process `var`, and in a combined
# test binary an earlier module may leave a different (e.g. giant generated)
# map installed at this module's import time — the anchor must read the
# height AFTER the test's own game init installs the default arena.
const ClearX = 60
template ClearY(): int = MapHeight div 2

suite "spray cans":
  test "two spray cans spawn walkable in the top half of the side columns":
    let game = twoTeamGame()
    for i in 0 ..< game.plasmaArcSpawns.len:
      check game.plasmaArcSpawns[i].present
      check game.canOccupy(game.plasmaArcSpawns[i].x, game.plasmaArcSpawns[i].y)
      # Plasma arcs live in the TOP half (quarter height); the shields hold
      # the matching bottom-half spots.
      check abs(game.plasmaArcSpawns[i].y - MapHeight div 4) < 120
      check game.plasmaArcSpawns[i].y < MapHeight div 2
      if i == 0:
        check game.plasmaArcSpawns[i].x < MapWidth div 2
      else:
        check game.plasmaArcSpawns[i].x > MapWidth div 2

  test "pickup has a one-arc limit and respawns after 30 seconds":
    var game = twoTeamGame()
    let spawn = game.plasmaArcSpawns[0]
    game.players[0].placeAtCenter(spawn.x, spawn.y)
    game.tryPickupPlasmaArcs(0)
    check game.players[0].hasPlasmaArc
    check not game.plasmaArcSpawns[0].present
    game.players[1].placeAtCenter(game.plasmaArcSpawns[1].x, game.plasmaArcSpawns[1].y)
    game.tryPickupPlasmaArcs(1)
    check game.players[1].hasPlasmaArc
    game.players[0].placeAtCenter(spawn.x, spawn.y)
    game.tryPickupPlasmaArcs(0)
    check game.players[0].hasPlasmaArc
    game.players[0].placeAtCenter(400, 400)
    game.stepNone(PlasmaArcRespawnTicks)
    check game.plasmaArcSpawns[0].present

  test "a carried spray can is lost on death":
    var game = twoTeamGame()
    game.players[0].hasPlasmaArc = true
    game.killPlayer(0, 1)
    check not game.players[0].hasPlasmaArc

  test "a spray can carrier cannot fire the gun":
    var game = twoTeamGame()
    game.players[0].hasPlasmaArc = true
    game.players[1].placeAtCenter(game.players[0].x + 100, game.players[0].y)
    check not game.canFire(0)
    game.tryFire(0)
    check game.players[1].alive

  test "an arc kills a target in the forward cone and credits the attacker":
    var game = twoTeamGame()
    game.players[0].hasPlasmaArc = true
    game.players[0].aimBrads = 0
    game.players[0].placeAtCenter(ClearX, ClearY)
    let ax = game.players[0].x + CollisionW div 2
    let ay = game.players[0].y + CollisionH div 2
    game.players[1].placeAtCenter(ax + PlasmaArcReach - 2, ay)
    game.tryFireArc(0)
    check not game.players[1].alive
    check game.players[0].kills == 1
    check game.plasmaArcFlashes.len == 1

  test "an arc misses behind, outside the cone, and beyond reach":
    var game = twoTeamGame()
    game.players[0].hasPlasmaArc = true
    game.players[0].aimBrads = 0
    game.players[0].placeAtCenter(ClearX, ClearY)
    let
      ax = game.players[0].x + CollisionW div 2
      ay = game.players[0].y + CollisionH div 2
    game.players[1].placeAtCenter(ax - 20, ay)
    game.tryFireArc(0)
    check game.players[1].alive
    game.players[0].fireCooldown = 0
    # Forward 90px the cone's half-width is 22px, so a body centered 50px
    # off-axis is clear of it even counting the cog's own 17px radius.
    game.players[1].placeAtCenter(ax + 90, ay + 50)
    game.tryFireArc(0)
    check game.players[1].alive
    game.players[0].fireCooldown = 0
    game.players[1].placeAtCenter(
      ax + PlasmaArcReach + PlasmaArcBodyRadius + 10, ay)
    game.tryFireArc(0)
    check game.players[1].alive

  test "a cog whose BODY overlaps the cone is sprayed, not just its center":
    var game = twoTeamGame()
    game.players[0].hasPlasmaArc = true
    game.players[0].aimBrads = 0
    game.players[0].placeAtCenter(ClearX, ClearY)
    let
      ax = game.players[0].x + CollisionW div 2
      ay = game.players[0].y + CollisionH div 2
    # 40px forward the centerline cone is only 10px wide to each side, which is
    # narrower than the 34px cog it is painting: a body 20px off-axis is visibly
    # engulfed even though its center point is outside the centerline cone.
    game.players[1].placeAtCenter(ax + 40, ay + 20)
    game.tryFireArc(0)
    check not game.players[1].alive

  test "the cone reaches one body radius past its centerline reach":
    var game = twoTeamGame()
    game.players[0].hasPlasmaArc = true
    game.players[0].aimBrads = 0
    game.players[0].placeAtCenter(ClearX, ClearY)
    let
      ax = game.players[0].x + CollisionW div 2
      ay = game.players[0].y + CollisionH div 2
    check PlasmaArcBodyRadius == SoldierBodyPx div 2
    game.players[1].placeAtCenter(
      ax + PlasmaArcReach + PlasmaArcBodyRadius - 2, ay)
    game.tryFireArc(0)
    check not game.players[1].alive
    # ...and stops one body radius out: a cog fully clear of the cone tip is
    # still safe.
    game.players[0].fireCooldown = 0
    game.players[1].respawnTimer = 0
    game.players[1].alive = true
    game.players[1].hp = game.config.hitPoints
    game.players[1].placeAtCenter(
      ax + PlasmaArcReach + PlasmaArcBodyRadius + 4, ay)
    game.tryFireArc(0)
    check game.players[1].alive

  test "the cone spans 5 squares of reach at an unchanged 14-degree half-angle":
    var game = twoTeamGame()
    game.players[0].hasPlasmaArc = true
    game.players[0].aimBrads = 0
    game.players[0].placeAtCenter(ClearX, ClearY)
    let
      ax = game.players[0].x + CollisionW div 2
      ay = game.players[0].y + CollisionH div 2
    check PlasmaArcReach == 5 * PlasmaArcSquare
    # The reach grew to cover the drawn plume, and the width grew with it so
    # the half-angle did NOT: 2.5 squares across 5 squares of reach is the
    # same atan(1/4) the 2-across-4 cone had.
    check PlasmaArcMaxWidth * 4 == PlasmaArcReach * 2
    # The centerline half-width is a quarter of the range (32.5px at forward
    # 130), and a sprayed body counts out to its own radius past that: 49.5px.
    game.players[1].placeAtCenter(ax + 130, ay + 30)
    game.tryFireArc(0)
    check not game.players[1].alive
    game.players[0].fireCooldown = 0
    game.players[1].respawnTimer = 0
    game.players[1].alive = true
    game.players[1].hp = game.config.hitPoints
    game.players[1].placeAtCenter(ax + 130, ay + 56)
    game.tryFireArc(0)
    check game.players[1].alive
    # Near the muzzle the cone is proportionally narrow (7.5px at 30), so the
    # body radius is most of what a point-blank spray covers: 24.5px.
    game.players[0].fireCooldown = 0
    game.players[1].placeAtCenter(ax + 30, ay + 30)
    game.tryFireArc(0)
    check game.players[1].alive
    game.players[0].fireCooldown = 0
    game.players[1].placeAtCenter(ax + 30, ay + 20)
    game.tryFireArc(0)
    check not game.players[1].alive

  test "friendly fire: the cone kills a teammate":
    var game = twoTeamGame()
    game.players[0].hasPlasmaArc = true
    game.players[0].aimBrads = 0
    game.players[0].placeAtCenter(ClearX, ClearY)
    let
      ax = game.players[0].x + CollisionW div 2
      ay = game.players[0].y + CollisionH div 2
    game.players[1].placeAtCenter(ax + PlasmaArcReach - 2, ay)
    game.players[1].team = game.players[0].team
    game.tryFireArc(0)
    check not game.players[1].alive
    check game.players[0].kills == 1

  test "spinning after firing never sweeps the cone onto new targets":
    # The exploit this closes: fire, then spin, raking the cone across
    # everyone around you. One fire now paints ONE direction for the window.
    var game = twoTeamGame()
    game.players[0].hasPlasmaArc = true
    game.players[0].placeAtCenter(ClearX, ClearY)
    let
      ax = game.players[0].x + CollisionW div 2
      ay = game.players[0].y + CollisionH div 2
      northX = ax
      northY = ay - (PlasmaArcReach - 2)   # a victim due north, at spray reach.
    # 1. Self-check: aiming north and firing DOES catch the northern cog, so
    #    the spot is a legitimate in-range, unobstructed north target.
    game.players[1].placeAtCenter(northX, northY)
    game.players[0].aimBrads = 64            # north
    game.tryFireArc(0)
    check not game.players[1].alive
    # 2. Revive it, aim EAST, fire, then spin north through the whole active
    #    window. The locked cone stays east and never touches the north cog.
    game.players[1].alive = true
    game.players[1].respawnTimer = 0
    game.players[1].hp = game.config.hitPoints
    game.players[1].placeAtCenter(northX, northY)
    game.players[0].fireCooldown = 0
    game.players[0].aimBrads = 0             # fire east
    game.startArcFire(0)
    check game.players[0].arcAimBrads == 0   # aim locked at the fire instant.
    game.players[0].aimBrads = 64            # spin to face north mid-spray
    for _ in 0 ..< PlasmaArcActiveTicks:
      game.resolveActiveArcCones()
    check game.players[1].alive              # cone never swung onto the cog.
    check game.players[0].arcAimBrads == -1  # cleared when the window closed.

  test "the locked cone still hits its launch target after the cog turns away":
    # The flip side of the sweep fix: turning off your target must NOT spare
    # them — the shot was already committed east when you spun north.
    var game = twoTeamGame()
    game.players[0].hasPlasmaArc = true
    game.players[0].aimBrads = 0             # fire east
    game.players[0].placeAtCenter(ClearX, ClearY)
    let
      ax = game.players[0].x + CollisionW div 2
      ay = game.players[0].y + CollisionH div 2
    game.players[1].placeAtCenter(ax + PlasmaArcReach - 2, ay)
    game.startArcFire(0)
    game.players[0].aimBrads = 64            # spin away to face north
    game.resolveActiveArcCones()
    check not game.players[1].alive
    check game.players[0].kills == 1

  test "same-tick arc fires can kill each other":
    var game = twoTeamGame()
    game.players[0].hasPlasmaArc = true
    game.players[1].hasPlasmaArc = true
    game.players[0].aimBrads = 0
    game.players[1].aimBrads = 128
    game.players[0].placeAtCenter(ClearX, ClearY)
    let
      ax = game.players[0].x + CollisionW div 2
      ay = game.players[0].y + CollisionH div 2
    game.players[1].placeAtCenter(ax + PlasmaArcReach - 2, ay)
    game.startArcFire(0)
    game.startArcFire(1)
    game.resolveActiveArcCones()
    check not game.players[0].alive
    check not game.players[1].alive
    check game.players[0].kills == 1
    check game.players[1].kills == 1

  test "a shield carrier survives one spray touch, and only one per burst":
    var game = twoTeamGame()
    game.players[0].hasPlasmaArc = true
    game.players[0].aimBrads = 0
    game.players[0].placeAtCenter(ClearX, ClearY)
    let
      ax = game.players[0].x + CollisionW div 2
      ay = game.players[0].y + CollisionH div 2
    game.players[1].hasShield = true
    game.players[1].shieldHp = ShieldLayerHp
    game.players[1].placeAtCenter(ax + 60, ay)
    game.tryFireArc(0)
    check game.players[1].alive
    # The shield layer soaks the arc touch before base hp.
    check game.players[1].shieldHp == ShieldLayerHp - PlasmaArcDamage
    check game.players[1].hp == game.config.hitPoints
    check game.players[0].kills == 0
    # Staying inside the cone for the rest of the window adds no damage.
    for _ in 0 ..< PlasmaArcActiveTicks:
      game.resolveActiveArcCones()
    check game.players[1].shieldHp == ShieldLayerHp - PlasmaArcDamage
    # A second firing lands a second touch, which finishes the carrier.
    game.players[0].fireCooldown = 0
    game.tryFireArc(0)
    check not game.players[1].alive
    check game.players[0].kills == 1

  test "a spray touch absorbed by a bubble blinks the bubble and spares the body":
    var game = twoTeamGame()
    game.players[0].hasPlasmaArc = true
    game.players[0].aimBrads = 0
    game.players[0].placeAtCenter(ClearX, ClearY)
    let
      ax = game.players[0].x + CollisionW div 2
      ay = game.players[0].y + CollisionH div 2
    game.players[1].hasShield = true
    game.players[1].shieldHp = ShieldLayerHp
    game.players[1].paintHitTick = -1
    game.players[1].placeAtCenter(ax + 60, ay)
    game.tryFireArc(0)
    check game.players[1].shieldHp == ShieldLayerHp - PlasmaArcDamage
    check game.bubbleImpacts.len == 1
    check game.bubbleImpacts[0].playerIndex == 1
    # The dent points back at the sprayer, due west of the carrier.
    check game.bubbleImpacts[0].angleBrads == 128
    # A bubble that eats the burst keeps the body clean: no visor splat.
    check game.players[1].paintHitTick == -1

  test "the cone stays live for 5 ticks and catches late entrants":
    var game = twoTeamGame()
    game.players[0].hasPlasmaArc = true
    game.players[0].aimBrads = 0
    game.players[0].placeAtCenter(ClearX, ClearY)
    let
      ax = game.players[0].x + CollisionW div 2
      ay = game.players[0].y + CollisionH div 2
    game.players[1].placeAtCenter(ax - 40, ay)
    game.tryFireArc(0)
    check game.players[1].alive
    check game.players[0].arcTicksLeft == PlasmaArcActiveTicks - 1
    # Walking into the still-live cone two ticks later is fatal.
    game.resolveActiveArcCones()
    game.players[1].placeAtCenter(ax + 60, ay)
    game.resolveActiveArcCones()
    check not game.players[1].alive
    # Exhaust the window: the cone shuts off and stops touching anyone.
    game.resolveActiveArcCones()
    game.resolveActiveArcCones()
    check game.players[0].arcTicksLeft == 0
    game.players[1].respawnTimer = 0
    game.players[1].alive = true
    game.players[1].hp = game.config.hitPoints
    game.players[1].placeAtCenter(ax + 60, ay)
    game.resolveActiveArcCones()
    check game.players[1].alive

  test "firing takes 20 ticks to reset after the 5-tick window":
    var game = twoTeamGame()
    game.players[0].hasPlasmaArc = true
    game.players[0].placeAtCenter(ClearX, ClearY)
    game.tryFireArc(0)
    check game.players[0].fireCooldown ==
      PlasmaArcActiveTicks + PlasmaArcResetTicks
    check not game.canFireArc(0)

  test "spray can state is in the game hash":
    var game = twoTeamGame()
    let initial = game.gameHash()
    game.players[0].hasPlasmaArc = true
    check game.gameHash() != initial
    let carried = game.gameHash()
    game.players[0].hasPlasmaArc = false
    game.plasmaArcSpawns[0].present = not game.plasmaArcSpawns[0].present
    check game.gameHash() != carried
    let toggled = game.gameHash()
    game.players[0].arcTicksLeft = 3
    check game.gameHash() != toggled

import ctf/global
import std/tables
import bitworld/spriteprotocol

suite "one spray per firing (no divergent trail when the cog turns)":
  ## A burst emits one snapshot per active tick, each carrying the LOCKED fire
  ## aim (GV38), and every snapshot lingers a few ticks. Because the aim is
  ## fixed at the fire instant, swinging the cog mid-burst can never point a
  ## snapshot the old way — so a single firing never reads as two simultaneous
  ## sprays. (Snapshots still differ in POSITION when the owner moves, and
  ## plasmaArcRenderPose collapses those onto the newest pose so a moving
  ## sprayer's plume stays one coherent cone.)
  test "every snapshot of a burst keeps the locked fire aim when the cog turns":
    # Swing the aim mid-burst: neither the stored snapshots nor the render pose
    # follow the swing, because the direction was locked at fire.
    var game = twoTeamGame()
    game.players[0].hasPlasmaArc = true
    game.players[0].placeAtCenter(ClearX, ClearY)
    game.players[0].aimBrads = 0            # fire east
    game.players[0].fireCooldown = 0
    game.startArcFire(0)
    game.resolveActiveArcCones()            # snapshot 0
    game.players[0].aimBrads = 64           # swing 90 deg to north (screen up)
    game.resolveActiveArcCones()            # snapshot 1
    check game.plasmaArcFlashes.len == 2
    # Both snapshots carry the LOCKED east aim, not the north swing.
    check game.plasmaArcFlashes[0].aimBrads == 0
    check game.plasmaArcFlashes[1].aimBrads == 0
    # And both render along that same locked aim (the newest pose is still east).
    check game.plasmaArcRenderPose(0).aimBrads == 0
    check game.plasmaArcRenderPose(1).aimBrads == 0

  test "a burst that turns mid-window paints the locked aim, not the swing":
    var game = twoTeamGame()
    game.players[0].hasPlasmaArc = true
    game.players[0].placeAtCenter(ClearX, ClearY)
    game.players[0].aimBrads = 0            # fire east
    game.players[0].fireCooldown = 0
    game.startArcFire(0)
    game.resolveActiveArcCones()            # snapshot 0
    game.players[0].aimBrads = 64           # swing 90 deg to north (screen up)
    game.resolveActiveArcCones()            # snapshot 1
    check game.plasmaArcFlashes.len == 2

    var state = initGlobalViewerState()
    let messages = game.buildGlobalMessages(state)
    # Recover each puff's CENTER: an object's x/y is its sprite's top-left, and
    # the width rides in the sprite def emitted alongside it (a fresh viewer
    # state re-sends every def). The board packet is emitted at boardScale, so
    # the cog reference is scaled to match.
    var widthById = initTable[int, int]()
    for m in messages:
      if m.kind == spkSprite:
        widthById[m.sprite.id] = m.sprite.width
    let
      scale = boardRenderScaleFor(game.gameMap.width, game.gameMap.height)
      cx = float((game.players[0].x + CollisionW div 2) * scale)
      cy = float((game.players[0].y + CollisionH div 2) * scale)
      base = PlasmaArcFxObjectBase
      cap = base + MaxPlayers * PlasmaArcFxPulses
    var puffs = 0
    for m in messages:
      if m.kind == spkObject and m.objectDef.id >= base and m.objectDef.id < cap:
        let w = widthById.getOrDefault(m.objectDef.spriteId, 0)
        let
          pcx = float(m.objectDef.x) + float(w) / 2
          pcy = float(m.objectDef.y) + float(w) / 2
        inc puffs
        # Locked aim is EAST: every puff sits east of the cog (screen right =
        # +x), and none juts north where the swung aim now points.
        check pcx > cx
        check abs(pcy - cy) < float(PlasmaArcFxReach * scale) / 2
    check puffs > 0

suite "the damage cone covers the plume the game draws":
  ## The complaint this guards against: paint visibly engulfing a cog that
  ## takes no damage. A cog is PAINTED when the plume touches its body and
  ## DAMAGED when its center is inside the cone — both measured against the
  ## same 17px body radius, so the radius cancels and the comparison is the
  ## plume's outermost pixel against the bare cone.

  test "no painted pixel lands past the damage reach":
    var farthest = 0
    for stage in 0 ..< PlasmaArcFxStages:
      for pulse in 0 ..< PlasmaArcFxPulses:
        farthest = max(farthest, plasmaPulseForward(pulse, stage) +
          plasmaPulseDiameter(pulse, stage) div 2)
    check farthest <= PlasmaArcReach

  test "the plume is sized against the FX span, not the damage reach":
    # Otherwise growing the cone to cover the plume grows the plume too, and
    # the overhang can never be closed.
    check PlasmaArcFxReach == 4 * PlasmaArcSquare
    check PlasmaArcFxMaxWidth == 2 * PlasmaArcSquare
    check PlasmaArcReach > PlasmaArcFxReach

suite "spray cone fx wall clipping":
  test "cone pulse discs stop at the first wall along the aim ray":
    # Find a spot where the aim ray is clear to the first pulse disc but a
    # wall blocks the ray before the last one — the damage cone cannot cross
    # it (selectArcVictims is LOS-gated), so the animation must clip too.
    var game = twoTeamGame()
    let (ux, uy) = (1.0, 0.0)   # aim east (brads 0)
    var fx, fy = -1
    # Ask the renderer where the nearest and farthest puffs of a FRESH burst
    # (stage 0) actually sit, rather than restating the fan geometry here — the
    # puff count and the jet's growth curve are the renderer's business.
    let
      lastPulse = PlasmaArcFxPulses - 1
      nearD = float(plasmaPulseForward(0, 0))
      farD = float(plasmaPulseForward(lastPulse, 0))
    block search:
      for y in countup(40, MapHeight - 40, 8):
        for x in countup(40, MapWidth - 200, 8):
          if not game.canOccupy(x, y):
            continue
          let nx = x + int(ux * nearD)
          let ny = y + int(uy * nearD)
          let fxp = x + int(ux * farD)
          let fyp = y + int(uy * farD)
          if game.lineOfSightClear(x, y, nx, ny) and
              not game.lineOfSightClear(x, y, fxp, fyp):
            fx = x
            fy = y
            break search
    check fx >= 0
    game.players[0].placeAtCenter(fx, fy)
    game.players[0].aimBrads = 0
    game.players[0].hasPlasmaArc = true
    game.players[0].fireCooldown = 0
    game.tryFireArc(0)
    check game.plasmaArcFlashes.len == 1
    var state = initGlobalViewerState()
    let messages = game.buildGlobalMessages(state)
    # The first pulse (clear ray) draws; the last pulse (behind the wall)
    # must not.
    check messages.hasObject(PlasmaArcFxObjectBase + 0)
    check not messages.hasObject(PlasmaArcFxObjectBase + lastPulse)

  test "an unobstructed cone still draws every pulse disc":
    var game = twoTeamGame()
    game.players[0].placeAtCenter(ClearX, ClearY)
    game.players[0].aimBrads = 0
    game.players[0].hasPlasmaArc = true
    game.players[0].fireCooldown = 0
    game.tryFireArc(0)
    var state = initGlobalViewerState()
    let messages = game.buildGlobalMessages(state)
    for pulse in 0 ..< PlasmaArcFxPulses:
      check messages.hasObject(PlasmaArcFxObjectBase + pulse)
