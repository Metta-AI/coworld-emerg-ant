## Grenade-barrage endgame: config lifecycle, the clock latch, the
## escalation ramp (depth + rate), deterministic shell launches inside the
## target band, environmental kills without credit, the no-timeout-tie
## guarantee, hash gating, keyframe round-trip, and the stated marker.
## See docs/plans/2026-08-07-grenade-barrage-design.md.

import
  helpers,
  std/[json, unittest],
  bitworld/spriteprotocol,
  ctf/[global, labels, replays, sim]

proc barrageGame(
  maxPerSec: int,
  startPerSec = BarrageStartPerSec,
  startSec = BarrageStartSec,
  saturateSec = BarrageSaturateSec,
  maxTicks = 1000
): SimServer =
  ## A started Red-vs-Blue game with the grenade barrage configured.
  var config = defaultGameConfig()
  config.maxTicks = maxTicks
  config.barrageMaxPerSec = maxPerSec
  config.barrageStartPerSec = startPerSec
  config.barrageStartSec = startSec
  config.barrageSaturateSec = saturateSec
  result = initCtfForTest(config)
  discard result.addPlayer("red0")
  discard result.addPlayer("blue0")
  result.startGame()
  result.players[0].team = Red
  result.players[1].team = Blue

proc runClockTo(sim: var SimServer, remaining: int) =
  ## Advances the raw tick counter so `remaining` ticks stay on the clock.
  sim.tickCount = sim.gameStartTick + sim.config.maxTicks - remaining

proc stepIdle(sim: var SimServer, ticks: int) =
  ## Steps the sim with all-idle inputs.
  let noInput = sim.none()
  for _ in 1 .. ticks:
    sim.step(noInput, noInput)

proc nearEdge(x, y, depth: int): bool =
  ## Whether a landing point sits within `depth` of some map edge (with the
  ## same arena-border clamp the launcher applies).
  x < depth + ArenaBorder + 2 or x >= MapWidth - depth - ArenaBorder - 2 or
    y < depth + ArenaBorder + 2 or y >= MapHeight - depth - ArenaBorder - 2

suite "grenade barrage config":
  test "off by default, with the documented ramp defaults":
    let config = defaultGameConfig()
    check config.barrageMaxPerSec == 0
    check config.barrageStartPerSec == BarrageStartPerSec
    check config.barrageStartSec == BarrageStartSec
    check config.barrageSaturateSec == BarrageSaturateSec
    # The shipped schedule: a 5:00 default clock, latch at 4:30 elapsed,
    # fully saturated exactly at 5:00.
    check config.maxTicks == 5 * 60 * TargetFps
    check BarrageStartSec == 30
    check BarrageSaturateSec == 30

  test "JSON round-trip through update and the config echo":
    var config = defaultGameConfig()
    config.update(
      """{"barrageMaxPerSec": 18, "barrageStartPerSec": 6,
          "barrageStartSec": 25, "barrageSaturateSec": 45}""")
    check config.barrageMaxPerSec == 18
    check config.barrageStartPerSec == 6
    check config.barrageStartSec == 25
    check config.barrageSaturateSec == 45
    let echo = config.configJson()
    var reread = defaultGameConfig()
    reread.update(echo)
    check reread.barrageMaxPerSec == 18
    check reread.barrageStartPerSec == 6
    check reread.barrageStartSec == 25
    check reread.barrageSaturateSec == 45

  test "a default game's config echo carries no barrage keys":
    let node = parseJson(defaultGameConfig().configJson())
    check not node.hasKey("barrageMaxPerSec")
    check not node.hasKey("barrageStartPerSec")
    check not node.hasKey("barrageStartSec")
    check not node.hasKey("barrageSaturateSec")

  test "rates outside 0..the ceiling are rejected":
    var config = defaultGameConfig()
    expect CtfError:
      config.update("""{"barrageMaxPerSec": -1}""")
    expect CtfError:
      config.update(
        """{"barrageMaxPerSec": """ & $(BarrageAbsMaxPerSec + 1) & "}")

  test "the barrage requires a timed game":
    var config = defaultGameConfig()
    expect CtfError:
      config.update("""{"maxTicks": 0, "barrageMaxPerSec": 5}""")

  test "the start rate must be 1..max":
    var config = defaultGameConfig()
    expect CtfError:
      config.update("""{"barrageMaxPerSec": 5, "barrageStartPerSec": 6}""")
    expect CtfError:
      config.update("""{"barrageMaxPerSec": 5, "barrageStartPerSec": 0}""")

  test "a start threshold under one second is rejected":
    var config = defaultGameConfig()
    expect CtfError:
      config.update("""{"barrageMaxPerSec": 5, "barrageStartSec": 0}""")

  test "a saturate window under one second is rejected":
    var config = defaultGameConfig()
    expect CtfError:
      config.update("""{"barrageMaxPerSec": 5, "barrageSaturateSec": 0}""")

suite "grenade barrage sim":
  test "latches when the clock reaches the threshold":
    var sim = barrageGame(maxPerSec = 12)
    let thresholdTicks = sim.config.barrageStartSec * TargetFps
    sim.runClockTo(thresholdTicks + 3)
    sim.stepIdle(1)
    check sim.barrageStartTick == -1
    check sim.barrageDepth() == 0
    check sim.barrageRatePermille() == 0
    sim.stepIdle(2)
    check sim.barrageStartTick == sim.tickCount

  test "never latches while the mode is off":
    var sim = barrageGame(maxPerSec = 12)
    sim.config.barrageMaxPerSec = 0
    sim.runClockTo(10)
    sim.stepIdle(5)
    check sim.barrageStartTick == -1

  test "the ramp runs edge band + start rate to full board + max rate":
    # Saturate is its OWN knob: a 10s ramp under a 30s start window.
    var sim = barrageGame(maxPerSec = 16, startPerSec = 4, saturateSec = 10)
    sim.runClockTo(sim.config.barrageStartSec * TargetFps)
    sim.stepIdle(1)                    # latch tick.
    check sim.barrageProgressPermille() == 0
    check sim.barrageDepth() == BarrageEdgeBandPx
    check sim.barrageRatePermille() == 4000
    # Halfway through the saturate window: linear interpolation.
    sim.tickCount += sim.config.barrageSaturateSec * TargetFps div 2
    check sim.barrageProgressPermille() == 500
    check sim.barrageDepth() ==
      BarrageEdgeBandPx + (barrageFullDepth() - BarrageEdgeBandPx) div 2
    check sim.barrageRatePermille() == 10000
    # Past the full window: pinned at total coverage and max rate.
    sim.tickCount += sim.config.barrageSaturateSec * TargetFps
    check sim.barrageProgressPermille() == 1000
    check sim.barrageDepth() == barrageFullDepth()
    check sim.barrageRatePermille() == 16000
    # The default schedule saturates exactly at the scheduled end: latch at
    # startSec remaining + a saturateSec ramp = clock zero.
    check BarrageStartSec == BarrageSaturateSec

  test "GV41: kills never extend the clock":
    var sim = barrageGame(maxPerSec = 12)
    sim.runClockTo(100)
    sim.killPlayer(1, 0)
    check sim.effectiveMaxTicks() == sim.config.maxTicks
    check sim.effectiveMaxTicks() - sim.gameTicksElapsed() == 100

  test "a barrage game plays past the scheduled deadline until a wipe":
    var sim = barrageGame(maxPerSec = 12)
    sim.runClockTo(sim.config.barrageStartSec * TargetFps)
    sim.stepIdle(10)
    check sim.barrageStartTick > 0
    # Step past the nominal draw ceiling: with the barrage on there is no
    # timeout — the game is still Playing on borrowed time.
    sim.runClockTo(1)
    sim.stepIdle(5)
    check sim.phase == Playing
    check sim.gameTicksElapsed() > sim.config.maxTicks
    # A wipe still ends it the moment one team stands alone.
    sim.players[1].lives = 0
    sim.killPlayer(1, 0)
    sim.stepIdle(1)
    check sim.phase == GameOver
    check sim.winner == Red
    check not sim.isDraw

  test "a barrage-off timed game still ends in the timeout draw":
    var sim = barrageGame(maxPerSec = 12)
    sim.config.barrageMaxPerSec = 0
    sim.runClockTo(1)
    sim.stepIdle(3)
    check sim.phase == GameOver
    check sim.isDraw
    check sim.timeLimitReached

  test "shells launch on the accumulator cadence, into the band, unowned":
    # start == max == 6/s: one launch every 4 ticks, no ramp to reason about.
    var sim = barrageGame(maxPerSec = 6, startPerSec = 6)
    sim.runClockTo(sim.config.barrageStartSec * TargetFps)
    sim.stepIdle(1)                    # latch; no shell yet.
    check sim.airborneGrenades.len == 0
    sim.stepIdle(8)                    # 8 accumulating ticks = 2 launches.
    check sim.airborneGrenades.len == 2
    for shell in sim.airborneGrenades:
      check shell.thrower == -1
      check shell.throwerSlot == -1
      check shell.throwerAccount == -1
      check nearEdge(shell.tx, shell.ty, sim.barrageDepth())

  test "a landing shell wounds and kills with no combat credit":
    var sim = barrageGame(maxPerSec = 6)
    sim.placeStill(0, MapWidth div 2, MapHeight div 2 - 100)
    sim.players[0].hp = 1
    let
      px = sim.players[0].x
      py = sim.players[0].y
    sim.airborneGrenades.add AirborneGrenade(
      sx: px, sy: py - 40, tx: px, ty: py,
      launchTick: sim.tickCount, flightTicks: 1,
      thrower: -1, throwerSlot: -1, throwerAccount: -1
    )
    sim.stepIdle(2)
    check not sim.players[0].alive
    check sim.players[0].deaths == 1
    check sim.players[0].lives == Lives - 1
    # Nobody gets combat credit for an environment shell.
    for player in sim.players:
      check player.kills == 0

  test "a timed barrage game never ends in a timeout draw":
    var sim = barrageGame(maxPerSec = 20, maxTicks = 600)
    var steps = 0
    while sim.phase == Playing and steps < 40000:
      sim.stepIdle(1)
      inc steps
    check sim.phase == GameOver
    check not sim.timeLimitReached

  test "the latch tick and accumulator are hashed only once latched":
    var sim1 = barrageGame(maxPerSec = 12)
    var sim2 = barrageGame(maxPerSec = 12)
    check sim1.gameHash == sim2.gameHash
    sim1.barrageStartTick = sim1.tickCount
    check sim1.gameHash != sim2.gameHash

  test "a mid-barrage keyframe round-trips the barrage state":
    var sim = barrageGame(maxPerSec = 12)
    sim.runClockTo(sim.config.barrageStartSec * TargetFps)
    sim.stepIdle(30)
    check sim.barrageStartTick > 0
    let
      hash = sim.gameHash()
      bytes = serializeReplaySim(sim)
    var restored = deserializeReplaySim(bytes, sim)
    check restored.gameHash() == hash
    check restored.barrageStartTick == sim.barrageStartTick
    check restored.barrageAccum == sim.barrageAccum

suite "grenade barrage emission":
  test "both streams state the barrage marker whenever the mode is on":
    var sim = barrageGame(maxPerSec = 12)
    var state = initGlobalViewerState()
    check sim.buildGlobalMessages(state).hasObject(BarrageMarkerObjectId)
    check sim.playerMessages(0).hasObject(BarrageMarkerObjectId)

  test "the marker labels current depth, rate, and start":
    var sim = barrageGame(maxPerSec = 6, startPerSec = 6)
    sim.runClockTo(sim.config.barrageStartSec * TargetFps)
    sim.stepIdle(1)                    # latched: edge band, full start rate.
    var state = initGlobalViewerState()
    var found = false
    for message in sim.buildGlobalMessages(state):
      if message.kind == spkSprite and
          message.sprite.label == labelBarrage(
            BarrageEdgeBandPx, 6, BarrageStartSec, BarrageSaturateSec):
        found = true
    check found

  test "no marker in a default game":
    var sim = barrageGame(maxPerSec = 12)
    sim.config.barrageMaxPerSec = 0
    var state = initGlobalViewerState()
    check not sim.buildGlobalMessages(state).hasObject(BarrageMarkerObjectId)
