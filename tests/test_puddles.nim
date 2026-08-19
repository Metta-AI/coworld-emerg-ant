import
  std/[algorithm, json, strutils, unittest],
  ctf/sim
import helpers except twoTeamGame

proc puddleGame(damagePct = DefaultPuddleDamagePct, puddles = 1): SimServer =
  ## A started game with one Red player (0) and one Blue player (1) on a
  ## generated map with `puddles` paint puddles — an odd count anchors one
  ## at the map center — since no map ships puddles by default.
  var config = defaultGameConfig()
  config.update(
    """{"mapPath": "gen", "mapSeed": 4242, "mapPuddles": """ & $puddles &
    """, "puddleDamagePct": """ & $damagePct & "}"
  )
  result = initCtfForTest(config)
  discard result.addPlayer("red0")
  discard result.addPlayer("blue0")
  result.startGame()
  result.players[0].team = Red
  result.players[1].team = Blue

proc placeAt(game: var SimServer, playerIndex, px, py: int) =
  ## Puts one player's CENTER exactly on map pixel (px, py), at rest.
  game.players[playerIndex].x = px - CollisionW div 2
  game.players[playerIndex].y = py - CollisionH div 2
  game.players[playerIndex].velX = 0
  game.players[playerIndex].velY = 0

proc stepTicks(game: var SimServer, ticks: int) =
  let prev = game.none()
  for _ in 0 ..< ticks:
    game.step(game.none(), prev)

suite "paint puddles":
  test "no map has puddles by default, and the config echo stays clean":
    let plain = initCtfForTest(defaultGameConfig())
    check plain.gameMap.puddles.len == 0
    check ArenaPuddles.len == 0
    check puddleIndexAt(plain.gameMap.center.x, plain.gameMap.center.y) == -1
    # The default replay config carries NO puddle keys: an unconditional
    # echo would change every existing fixture's bytes (the no-GV-bump rule).
    let echoed = parseJson(defaultGameConfig().configJson())
    check not echoed.hasKey("mapPuddles")
    check not echoed.hasKey("puddleDamagePct")

  test "mapPuddles:1 anchors one organic splat at the generated map's center":
    let game = puddleGame()
    check ArenaPuddles.len == 1
    let
      cx = game.gameMap.center.x
      cy = game.gameMap.center.y
      splat = ArenaPuddles[0]
      box = puddleBounds(splat)
    # An organic union of overlapping paint discs, not a square: several
    # spots, bbox inside the radius envelope, and the map center submerged.
    check splat.spots.len >= 4
    check box.w >= PuddleSize div 2
    check box.h >= PuddleSize div 2
    check box.w <= 2 * PuddleMaxRadiusPx + 2
    check box.h <= 2 * PuddleMaxRadiusPx + 2
    check puddleIndexAt(cx, cy) == 0
    check puddleIndexAt(cx - 2 * PuddleSize, cy) == -1

  test "the center splat is exactly its own symmetry image":
    let game = puddleGame()
    let splat = ArenaPuddles[0]
    let image =
      case game.gameMap.symmetry
      of symMirror: splat.mirrorX(game.gameMap.width)
      of symRot180: splat.rot180(game.gameMap.width, game.gameMap.height)
      else: splat
    # The stitched cluster is self-symmetric as a DISC SET (the transform
    # reorders the discs, never moves one off the set) — the exact
    # team-fairness invariant the rect center pit had.
    proc sortedSpots(puddle: Puddle): seq[(int, int, int)] =
      for s in puddle.spots:
        result.add (s.cx, s.cy, s.r)
      result.sort()
    check sortedSpots(image) == sortedSpots(splat)

  test "an even request places mirror-symmetric pairs on open floor":
    let game = puddleGame(puddles = 6)
    let blobs = game.gameMap.puddles
    check blobs.len > 0
    check blobs.len mod 2 == 0
    check blobs.len <= 6
    # Every splat's symmetry image is in the set — as an exact DISC set,
    # not just a matching box — and every splat sits clear of both base
    # pockets.
    for blob in blobs:
      let
        rect = puddleBounds(blob)
        image =
          case game.gameMap.symmetry
          of symMirror: blob.mirrorX(game.gameMap.width)
          of symRot180: blob.rot180(game.gameMap.width, game.gameMap.height)
          else: blob
      var found = false
      for other in blobs:
        if other.spots == image.spots:
          found = true
          break
      check found
      for room in game.gameMap.rooms:
        if room.name.endsWith("Base"):
          let base = MapRect(x: room.x, y: room.y, w: room.w, h: room.h)
          check not (rect.x < base.x + base.w and base.x < rect.x + rect.w and
            rect.y < base.y + base.h and base.y < rect.y + rect.h)

  test "the puddle set pins into the map spec and round-trips exactly":
    let game = puddleGame(puddles = 4)
    check game.gameMap.puddles.len > 0
    let spec = mapSpecJson(game.gameMap)
    check parseJson(spec).hasKey("puddles")
    let rebuilt = mapFromSpecJson(spec)
    check rebuilt.puddles.len == game.gameMap.puddles.len
    for i in 0 ..< rebuilt.puddles.len:
      check rebuilt.puddles[i].spots == game.gameMap.puddles[i].spots
    # A puddle-free map pins NO key (pre-puddle specs must stay byte-stable),
    # and a spec without the key loads as puddle-free.
    let plain = initCtfForTest(defaultGameConfig())
    check not parseJson(mapSpecJson(plain.gameMap)).hasKey("puddles")

  test "placement is deterministic from the map seed":
    let a = puddleGame(puddles = 6)
    let firstSpec = mapSpecJson(a.gameMap)
    let b = puddleGame(puddles = 6)
    check mapSpecJson(b.gameMap) == firstSpec

  test "a full second of continuous occupancy rolls; dipping out resets":
    var game = puddleGame(damagePct = 0)
    let
      cx = game.gameMap.center.x
      cy = game.gameMap.center.y
    game.placeAt(0, cx, cy)
    check game.playerPuddle(0) == 0
    game.stepTicks(PuddleRollTicks - 1)
    check game.players[0].puddleTicks == PuddleRollTicks - 1
    # One tick on clean floor restarts the second.
    game.placeAt(0, cx - PuddleSize * 2, cy)
    game.stepTicks(1)
    check game.players[0].puddleTicks == 0
    game.placeAt(0, cx, cy)
    game.stepTicks(PuddleRollTicks - 1)
    check game.players[0].puddleTicks == PuddleRollTicks - 1
    # At pct 0 the completed second resets the clock and never hurts.
    game.stepTicks(1)
    check game.players[0].puddleTicks == 0
    check game.players[0].hp == game.config.hitPoints

  test "puddleDamagePct 100 deals exactly 1 damage per completed second":
    var game = puddleGame(damagePct = 100)
    game.placeAt(0, game.gameMap.center.x, game.gameMap.center.y)
    game.stepTicks(PuddleRollTicks - 1)
    check game.players[0].hp == game.config.hitPoints
    game.stepTicks(1)
    check game.players[0].hp == game.config.hitPoints - 1
    # The clock restarted: the next damage lands one full second later.
    game.stepTicks(PuddleRollTicks - 1)
    check game.players[0].hp == game.config.hitPoints - 1
    game.stepTicks(1)
    check game.players[0].hp == game.config.hitPoints - 2

  test "the shield layer soaks the puddle hit before base hp":
    var game = puddleGame(damagePct = 100)
    game.players[0].hasShield = true
    game.players[0].shieldHp = 1
    game.placeAt(0, game.gameMap.center.x, game.gameMap.center.y)
    game.stepTicks(PuddleRollTicks)
    check game.players[0].shieldHp == 0
    check game.players[0].hasShield == false
    check game.players[0].hp == game.config.hitPoints

  test "a lethal roll is an environmental death: nobody gets the kill":
    var game = puddleGame(damagePct = 100)
    game.players[0].hp = 1
    game.placeAt(0, game.gameMap.center.x, game.gameMap.center.y)
    game.stepTicks(PuddleRollTicks)
    check not game.players[0].alive
    check game.players[0].deaths == 1
    check game.players[0].puddleTicks == 0
    for player in game.players:
      check player.kills == 0

  test "a dead body in the puddle never ticks the clock":
    var game = puddleGame(damagePct = 0)
    game.placeAt(0, game.gameMap.center.x, game.gameMap.center.y)
    game.players[0].alive = false
    game.stepTicks(PuddleRollTicks)
    check game.players[0].puddleTicks == 0

  test "a puddle game's replay config echoes both knobs":
    let game = puddleGame(damagePct = 25, puddles = 2)
    let echoed = parseJson(game.config.configJson())
    check echoed["mapPuddles"].getInt() == 2
    check echoed["puddleDamagePct"].getInt() == 25

  test "placePuddles patches a pinned spec deterministically (mapkit entry)":
    # The tool path mapkit's `puddles` subcommand drives: round-trip a
    # puddle-free map through its pinned spec, then place against the
    # spec's final terrain.
    let game = puddleGame(puddles = 0)
    var patched = mapFromSpecJson(mapSpecJson(game.gameMap))
    check patched.puddles.len == 0
    patched.placePuddles(6, seed = 77)
    check patched.puddles.len > 0
    check patched.puddles.len mod 2 == 0
    # Every patched splat's symmetry image is in the set — the same
    # team-fairness invariant generation guarantees.
    for blob in patched.puddles:
      let image =
        case patched.symmetry
        of symMirror: blob.mirrorX(patched.width)
        of symRot180: blob.rot180(patched.width, patched.height)
        else: blob
      var found = false
      for other in patched.puddles:
        if other.spots == image.spots:
          found = true
          break
      check found
    # Deterministic from (spec, count, seed).
    var again = mapFromSpecJson(mapSpecJson(game.gameMap))
    again.placePuddles(6, seed = 77)
    check mapSpecJson(again) == mapSpecJson(patched)
    # Re-patching REPLACES the set (no accumulation); count 0 strips it.
    patched.placePuddles(2, seed = 5)
    check patched.puddles.len <= 2
    patched.placePuddles(0, seed = 5)
    check patched.puddles.len == 0

  test "placePuddles refuses 4-team maps and over-cap requests":
    var config = defaultGameConfig()
    config.update("""{"mapPath": "gen", "mapSeed": 1, "teams": 4}""")
    var quad = initCtfForTest(config).gameMap
    expect CtfError:
      quad.placePuddles(2, seed = 1)
    var flat = puddleGame(puddles = 0).gameMap
    expect CtfError:
      flat.placePuddles(MaxPuddles + 1, seed = 1)

  test "config validation rejects out-of-range knobs":
    var config = defaultGameConfig()
    expect CtfError:
      config.update("""{"puddleDamagePct": 101}""")
    expect CtfError:
      config.update("""{"mapPath": "gen", "mapSeed": 1, "mapPuddles": 65}""")
    expect CtfError:
      ## 4-team maps refuse an explicit puddle request, like trenches.
      config.update(
        """{"mapPath": "gen", "mapSeed": 1, "teams": 4, "mapPuddles": 2}""")
