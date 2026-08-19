import
  helpers,
  std/[json, os, unittest],
  bitworld/spriteprotocol,
  ctf/[global, replay_runtime, replays, sim]

const
  # A fresh, drama-complete fixture recorded against the CURRENT gameplay rules
  # (GameVersion 44, seed 1, tools/record_fixture.sh). This capture-ending
  # fixture exceeds every tick target below and hash-verifies clean end to end.
  # (tests/replays/ctf.bitreplay is the event-substrate fixture:
  # GameVersion 44, seed 907, lives 9 — see
  # test_extract_events.)
  CtfReplayPath = GameDir / "tests" / "fixtures" / "capture-seed1.bitreplay"

proc initReplaySim(data: ReplayData): SimServer =
  ## Initializes a replay simulation from the replay config JSON.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    var config = defaultGameConfig()
    config.update(data.configJson)
    result = initSimServer(config)
    result.gameEventLoggingEnabled = false
  finally:
    setCurrentDir(previousDir)

suite "ctf replay":
  test "shared runtime initializes, advances, controls, and renders replay":
    let
      data = loadReplay(CtfReplayPath)
      previousDir = getCurrentDir()
    setCurrentDir(GameDir)
    var runtime: InitializedReplay
    try:
      runtime = initReplayRuntime(
        data,
        mismatchQuit = true,
        gameEventLoggingEnabled = false
      )
    finally:
      setCurrentDir(previousDir)

    check runtime.player.playing
    check runtime.sim.tickCount == runtime.player.replayStartTick()
    check not runtime.sim.gameEventLoggingEnabled

    let tickBefore = runtime.sim.tickCount
    discard runtime.player.advanceReplayFrame(
      runtime.sim,
      runtime.tracker,
      newSeq[int](),
      @['6']
    )
    check runtime.player.replaySpeed() == 16
    check runtime.sim.tickCount == tickBefore + 16

    var
      viewer = initGlobalViewerState()
      nextViewer: GlobalViewerState
    # The whole-match precompute walk now advances a slice per frame instead
    # of running before the first pixel; the lead chrome (momentum series,
    # beats, lull spans) ships only once it completes. One frame in, the walk
    # must still be in flight — finish it before asserting the lead sends.
    check not runtime.player.scanComplete
    runtime.player.advanceReplayScan(int.high)
    check runtime.player.scanComplete
    let packet = runtime.sim.buildReplayViewerPacket(
      runtime.player,
      viewer,
      nextViewer,
      newJArray()
    )
    var chrome: JsonNode
    for message in packet.parseSpritePacket():
      if message.kind == spkSprite and
          message.sprite.id == BroadcastChromeSpriteId:
        chrome = message.sprite.label.parseJson()
    check packet.len > 0
    check not chrome.isNil
    check chrome["t"].getInt() == runtime.sim.tickCount
    check chrome["en"].getBool()
    check nextViewer.momentumSent

    runtime.player.seekReplay(runtime.sim, runtime.player.replayMaxTick())
    runtime.player.endHoldFrames = ReplayFps * 2
    var holdViewer: GlobalViewerState
    let holdPacket = runtime.sim.buildReplayViewerPacket(
      runtime.player,
      nextViewer,
      holdViewer,
      newJArray()
    )
    var holdChrome: JsonNode
    for message in holdPacket.parseSpritePacket():
      if message.kind == spkSprite and
          message.sprite.id == BroadcastChromeSpriteId:
        holdChrome = message.sprite.label.parseJson()
    check not holdChrome.isNil
    check holdChrome["hold"].getInt() == 2

    let seekTick = runtime.player.replayStartTick() + 20
    discard runtime.player.advanceReplayFrame(
      runtime.sim,
      runtime.tracker,
      @[seekTick],
      newSeq[char]()
    )
    check runtime.sim.tickCount == seekTick
    check not runtime.player.playing
    check runtime.player.endHoldFrames == 0

  test "sim serializes with flatty":
    let data = loadReplay(CtfReplayPath)
    var
      sim = data.initReplaySim()
      replay = initReplayPlayer(data)
    replay.looping = false
    replay.mismatchQuit = true

    while sim.tickCount < 250:
      replay.stepReplay(sim)

    let
      hash = sim.gameHash()
      mapBakeBytes = sim.mapPixels.len + sim.mapRgba.len +
        sim.darkBgPixels.len + sim.walkMask.len
      bytes = serializeReplaySim(sim)

    check bytes.len > 0
    # Keyframes must EXCLUDE the static map bakes: serializing them into
    # every keyframe cost ~40 MB x ~55 keyframes on giant maps, more than
    # the wasm32 replay viewer can address at all. The whole keyframe must
    # come out smaller than the bakes it stripped...
    check bytes.len < mapBakeBytes
    # ...while the serialized sim itself reads back untouched.
    check sim.gameHash() == hash
    check sim.mapPixels.len > 0

    let restored = deserializeReplaySim(bytes, sim)
    check restored.tickCount == sim.tickCount
    check restored.gameHash() == hash
    # The donor's bakes moved into the restored sim.
    check restored.mapPixels.len > 0

  test "keyframed seek restores matching state":
    let data = loadReplay(CtfReplayPath)
    var
      baseline = data.initReplaySim()
      baselineReplay = initReplayPlayer(data)
      sim = data.initReplaySim()
      replay = initReplayPlayer(data)
    baselineReplay.looping = false
    baselineReplay.mismatchQuit = true
    replay.looping = false
    replay.mismatchQuit = true

    let target = 300
    while baseline.tickCount < target:
      baselineReplay.stepReplay(baseline)
    let hash = baseline.gameHash()

    replay.buildReplayKeyframes(sim)
    replay.seekReplay(sim, target)

    check replay.keyframes.len > 1
    check sim.tickCount == target
    check sim.gameHash() == hash

  test "keyframed seek restamps diamond geometry into donated masks":
    ## Keyframes strip walkMask/wallMask as "static" bakes and take them from
    ## the donor sim on restore (deserializeReplaySim) — but the spinning
    ## diamonds stamp tick-dependent stone into those masks, and
    ## applyDiamondGeometry skips a diamond whose frame "has not changed", so
    ## the donor's stale footprint could survive the restore until the next
    ## spin-frame advance (~4.8k phantom wall pixels on the default arena) —
    ## long enough for a collision with the phantom stone to diverge the sim
    ## permanently: a hash mismatch from that tick on.
    proc mismatches(a, b: seq[bool]): int =
      doAssert a.len == b.len and a.len > 0
      for i in 0 ..< a.len:
        if a[i] != b[i]:
          inc result

    let data = loadReplay(CtfReplayPath)
    var
      baseline = data.initReplaySim()
      baselineReplay = initReplayPlayer(data)
      sim = data.initReplaySim()
      replay = initReplayPlayer(data)
    baselineReplay.looping = false
    baselineReplay.mismatchQuit = true
    replay.looping = false
    replay.mismatchQuit = true

    ## 600 sits on both a keyframe boundary and a spin-frame boundary: the
    ## seek restores the keyframe and steps zero-to-few ticks, none of which
    ## advance the spin, so no post-restore tick restamps the masks — the
    ## worst case for a stale donor footprint. The static guard keeps a
    ## future constant change from silently de-fanging the alignment.
    const target = 600
    static:
      doAssert target mod ReplayKeyframeTicks == 0
      doAssert target mod DiamondSpinTicksPerFrame == 0
    while baseline.tickCount < target:
      baselineReplay.stepReplay(baseline)

    replay.buildReplayKeyframes(sim)
    ## The whole point is a seek that steps ZERO ticks after the restore, so
    ## the premise "a keyframe sits exactly on target" must hold — if the
    ## keyframe cadence or the fixture ever changes, fail loudly instead of
    ## letting a natural restamp mask the defect.
    var targetIsKeyframe = false
    for keyframe in replay.keyframes:
      if keyframe.tick == target:
        targetIsKeyframe = true
    check targetIsKeyframe

    replay.seekReplay(sim, target)
    check sim.tickCount == target

    ## fovBlocked matters too: restamping goes through stampDiamondPatch,
    ## whose refreshFovCells is the only thing keeping post-seek fog honest —
    ## the hash loop below cannot see it (inputs are recorded, so stale
    ## vision never feeds back into gameplay state).
    let
      staleWalk = mismatches(sim.walkMask, baseline.walkMask)
      staleWall = mismatches(sim.wallMask, baseline.wallMask)
      staleFov = mismatches(sim.fovBlocked, baseline.fovBlocked)
    check staleWalk == 0
    check staleWall == 0
    check staleFov == 0

    let
      walkAtTarget = baseline.walkMask
      wallAtTarget = baseline.wallMask
      fovAtTarget = baseline.fovBlocked

    ## The stale region only reaches the game hash once a player collides
    ## with it — hold the seeked sim to tick-by-tick hash equality with the
    ## linear run.
    for _ in 0 ..< 200:
      baselineReplay.stepReplay(baseline)
      replay.stepReplay(sim)
      check sim.tickCount == baseline.tickCount
      check sim.gameHash() == baseline.gameHash()

    ## Seek backward to the same target with the donor now 200 ticks ahead —
    ## a different spin frame — so a repeated seek must clean a MOVED donor
    ## footprint from the freshly donated masks.
    replay.seekReplay(sim, target)
    check sim.tickCount == target
    let
      reWalk = mismatches(sim.walkMask, walkAtTarget)
      reWall = mismatches(sim.wallMask, wallAtTarget)
      reFov = mismatches(sim.fovBlocked, fovAtTarget)
    check reWalk == 0
    check reWall == 0
    check reFov == 0

  test "hashes match":
    let data = loadReplay(CtfReplayPath)
    var
      sim = data.initReplaySim()
      replay = initReplayPlayer(data)
    replay.looping = false
    replay.mismatchQuit = true

    while replay.playing:
      replay.stepReplay(sim)

    check replay.hashIndex == data.hashes.len
    check not replay.hashValidationFailed
    check replay.hashMismatchTick == -1
    check sim.tickCount >= int(data.hashes[^1].tick)
