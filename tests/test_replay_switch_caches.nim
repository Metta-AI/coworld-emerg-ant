import
  helpers,
  std/[os, strutils, unittest],
  bitworld/spriteprotocol,
  ctf/[global, sim]

proc startedGame(configJson: string): SimServer =
  ## A started two-player game over the map the config JSON selects.
  var config = defaultGameConfig()
  if configJson.len > 0:
    config.update(configJson)
  result = initCtfForTest(config)
  discard result.addPlayer("red0")
  discard result.addPlayer("blue0")
  result.startGame()

proc initBandPixels(sim: var SimServer): seq[seq[uint8]] =
  ## The compressed map-band sprite payloads a brand-new global viewer's
  ## init packet carries, in band order.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    var
      state = initGlobalViewerState()
      nextState: GlobalViewerState
    let packet = sim.buildSpriteProtocolUpdates(state, nextState)
    for message in packet.parseSpritePacket():
      if message.kind == spkSprite and
          message.sprite.label.startsWith("map band"):
        result.add message.sprite.compressedPixels
  finally:
    setCurrentDir(previousDir)

suite "replay switch render caches":
  test "invalidateBoardMapCaches stops serving the previous sim's map":
    # The serve loop's replay hot-switch swaps in a sim over a NEW map while
    # the board render caches (map bands, arena bakes, endzone strips) are
    # process-wide. This pins the switch contract: after
    # invalidateBoardMapCaches(), a fresh viewer of the new sim must receive
    # that sim's map bands, not the previous arena's cached bytes.
    var simA = startedGame("")
    let bandsA = simA.initBandPixels()
    check bandsA.len > 0
    var simB = startedGame("""{"mapPath": "pool", "mapPoolIndex": 3}""")
    invalidateBoardMapCaches()
    let bandsB = simB.initBandPixels()
    check bandsB.len > 0
    check bandsB != bandsA
    # The repopulated cache serves the NEW map to the next viewer too, and
    # re-invalidating rebuilds the identical bytes (the cache is a pure
    # function of the current map).
    check simB.initBandPixels() == bandsB
    invalidateBoardMapCaches()
    check simB.initBandPixels() == bandsB

  test "endzone fade bands tile the diff crop exactly":
    # The fade crops ship as stacked horizontal bands so no single frame
    # bakes/ships a whole giant-board crop (a 100-300 ms stall — the
    # rhythmic early-replay stutter). A gap or overlap between bands would
    # read as a horizontal seam in the powered-down glow, so pin the
    # tiling: uniform x/width, contiguous in y, every band non-empty.
    let previousDir = getCurrentDir()
    setCurrentDir(GameDir)
    try:
      var sim = startedGame("")
      for team in sim.teams():
        let bands = sim.endzoneFadeBandCount(team)
        check bands > 0
        let first = sim.endzoneFadeBandBox(team, 0)
        var expectedY = first.y
        for band in 0 ..< bands:
          let box = sim.endzoneFadeBandBox(team, band)
          check box.w == first.w
          check box.x == first.x
          check box.h > 0
          check box.y == expectedY
          expectedY += box.h
    finally:
      setCurrentDir(previousDir)

  test "endzone caches self-heal across a map size switch, no invalidate":
    # tests.nim runs every module in ONE process, and board-state modules
    # build sims over different-size maps back-to-back without any
    # invalidateBoardMapCaches() courtesy call. The endzone diff boxes are
    # cached process-wide per TEAM while the fade strips cache per (team,
    # stage): a box baked on a larger map, served onto a smaller map for a
    # stage whose strip is not cached yet, indexes out of the (correctly
    # re-baked) board buffers — the IndexDefect that used to kill
    # test_shouts/test_shield_bubble in the full-suite binary. Pin the
    # self-heal: bake Red's box + stage-1 strip on the 1606x858 large arena,
    # then drive one 1235x659 default-arena viewer far enough into the
    # prewarm drip to bake Red's stage-2 strip, with no invalidation in
    # between.
    var simLarge = startedGame("""{"mapPath": "arena-large"}""")
    check simLarge.initBandPixels().len > 0
    var simDefault = startedGame("")
    var viewer = initGlobalViewerState()
    # The prewarm now drips one BAND per EndzonePrewarmEveryFrames, so
    # reaching a stage-2 crop (the "strip not cached yet on the new map"
    # path this test exists to pin) takes a full stage-1 sweep of bands
    # first — derive the frame budget instead of hardcoding the old
    # one-crop-per-step cadence.
    let stageBands = simDefault.endzoneFadeBandCount(Team(0))
    for _ in 0 .. (stageBands + 1) * EndzonePrewarmEveryFrames:
      discard simDefault.buildGlobalMessages(viewer)

# The suite above installs pool and arena-large maps as THE process map
# (selectCtfMap runs inside initSimServer) and repopulates the render caches
# from whichever map its last test touched. Both are process-wide, so leave
# no footprint: restore the default arena and drop the map-derived caches,
# whatever order the tests above ran in. (tests.nim runs ALL shards in one
# process, unlike CI's four binaries — test_shouts/test_shield_bubble once
# crashed with an IndexDefect on this module's leftovers; the size-mismatch
# case now also self-heals in endzoneDiffBox, pinned by the suite's second
# test.)
discard loadCtfMap()
invalidateBoardMapCaches()
