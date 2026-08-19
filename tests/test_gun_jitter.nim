import
  helpers,
  std/unittest,
  ctf/sim

## The firing scene: the widest fully clear corridor on the default arena is
## ~313px (x 10..322, y 72..88), so every live-fire test runs with a config
## gunRange OVERRIDE of 250 inside that lane. That is the point of the jitter
## design: sigma derives from the LIVE config.gunRange, so "80% at max range"
## holds for any configured range and can be pinned without a 1050px lane
## (which no hand-authored arena has).
const
  ShortRange = 250
  ShooterX = 24
  ShooterY = 80
  LaneX0 = 12                  # asserted wall-free rectangle around the lane:
  LaneX1 = 310                 # covers both bodies (±PlayerHalf) and every
  LaneY0 = 72                  # silhouette sample the shots can probe.
  LaneY1 = 88
  MaxRangeTargetX = ShooterX + ShortRange
  BeyondTargetX = ShooterX + ShortRange + 12
  HalfRangeTargetX = ShooterX + ShortRange div 2
  PointBlankTargetX = ShooterX + 60

proc shortRangeSim(seed: int): SimServer =
  var config = defaultGameConfig()
  config.update("""{"gunRange": """ & $ShortRange &
    """, "seed": """ & $seed & "}")
  result = initCtfForTest(config)
  result.gameEventLoggingEnabled = false
  discard result.addPlayer("red0")
  discard result.addPlayer("blue0")
  result.startGame()
  result.players[0].team = Red
  result.players[1].team = Blue
  result.players[0].x = ShooterX
  result.players[0].y = ShooterY
  result.players[0].aimBrads = 0    # due east, exactly down the lane.
  result.players[1].y = ShooterY

proc fireOnce(game: var SimServer, targetX: int): bool =
  ## One armed shot at a full-health target parked at (targetX, ShooterY);
  ## returns whether it connected.
  game.players[1].x = targetX
  game.players[0].windupBrads = -1
  game.players[0].fireCooldown = 0
  game.players[1].hp = 3
  game.tryFire(0)
  game.players[1].hp < 3

proc hitCount(game: var SimServer, targetX, shots: int): int =
  for _ in 0 ..< shots:
    if game.fireOnce(targetX):
      inc result

suite "gun range: one fixed cap, every map":
  test "the default range is the small map's field width":
    ## round(1235 * 0.85) = 1050: map-wide only on the smallest field.
    var config = defaultGameConfig()
    config.update("""{"mapPath": "gen", "mapSeed": 7, "mapSize": "small"}""")
    let smallMap = resolveCtfMapMetadata(config)
    check smallMap.width == 1050
    check config.gunRange == smallMap.width
    check GunRange == smallMap.width

  test "larger maps keep the same absolute range":
    for lock in [
      """{"mapPath": "gen", "mapSeed": 7, "mapSize": "giant"}""",
      """{"mapPath": "arena-large"}""",
      """{"mapPath": "arena"}"""
    ]:
      var config = defaultGameConfig()
      config.update(lock)
      check config.gunRange == GunRange
      check resolveCtfMapMetadata(config).gunRange == GunRange

suite "gun jitter: fuzzed aim, calibrated at max range":
  test "the scene is laid out as documented":
    var game = shortRangeSim(1)
    for y in LaneY0 .. LaneY1:
      for x in LaneX0 .. LaneX1:
        check not game.isWall(x, y)
    check game.canOccupy(ShooterX, ShooterY)
    check game.canOccupy(BeyondTargetX, ShooterY)
    check game.config.gunRange == ShortRange

  test "a fully visible target past max range is never hit":
    var game = shortRangeSim(2)
    check game.hitCount(BeyondTargetX, 300) == 0

  test "a miss's tracer never travels past max range":
    var game = shortRangeSim(3)
    discard game.hitCount(BeyondTargetX, 50)
    for shot in game.recentShots:
      check shot.x1 - shot.x0 <= ShortRange

  test "a fully visible target at max range is hit ~80% of the time":
    var game = shortRangeSim(4)
    let hits = game.hitCount(MaxRangeTargetX, 5000)
    ## 0.80 +- 0.03 is ~5 standard errors at 5000 shots: deterministic per
    ## seed, and loose enough that any correct sigma stays inside.
    check hits >= 3850
    check hits <= 4150

  test "closer targets are hit near-deterministically":
    var game = shortRangeSim(5)
    ## At half range the same sigma leaves ~99% (2.57 sigma of margin).
    check game.hitCount(HalfRangeTargetX, 2000) >= 1940
    ## Point-blank the jitter cannot miss a fully visible body.
    check game.hitCount(PointBlankTargetX, 500) == 500

  test "jitter rides the seeded sim RNG: same seed, same shots":
    var
      a = shortRangeSim(999)
      b = shortRangeSim(999)
    for _ in 0 ..< 200:
      check a.fireOnce(MaxRangeTargetX) == b.fireOnce(MaxRangeTargetX)
