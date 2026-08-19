import
  helpers,
  std/[json, os, sets, strutils, tables, unittest],
  bitworld/spriteprotocol,
  ctf/[global, labels, replay_runtime, replays, sim]

const
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

proc keyframeTicks(replay: ReplayPlayer): seq[int] =
  for keyframe in replay.keyframes:
    result.add(keyframe.tick)

suite "incremental replay scan":
  test "sliced scan produces byte-identical outputs to the synchronous walk":
    # The hosted viewer advances the whole-match precompute walk a bounded
    # slice per frame; tests and tools run it to completion in one call.
    # Slicing must be observationally transparent: any state lost across a
    # slice boundary (lastLives, beatTicks, keyframe cadence, the finalize
    # block) would corrupt the momentum graph / lull map ONLY in the hosted
    # viewer, invisible to every offline consumer.
    let data = loadReplay(CtfReplayPath)
    var reference = initReplayPlayer(data)
    reference.buildReplayKeyframes(initReplaySim(data))
    for slice in [96, 17]:
      var sliced = initReplayPlayer(data)
      sliced.initReplayScan(initReplaySim(data))
      var guard = 0
      while not sliced.scanComplete:
        sliced.advanceReplayScan(slice)
        inc guard
        doAssert guard < 100_000, "scan never completed"
      check sliced.livesSeries == reference.livesSeries
      check $sliced.beatEvents == $reference.beatEvents
      check sliced.lullSpans == reference.lullSpans
      check sliced.keyframeTicks() == reference.keyframeTicks()
      check sliced.startTick == reference.startTick

  test "lead chrome is omitted mid-scan and ships exactly once when done":
    let
      data = loadReplay(CtfReplayPath)
      previousDir = getCurrentDir()
    setCurrentDir(GameDir)
    var runtime: InitializedReplay
    try:
      runtime = initReplayRuntime(
        data, mismatchQuit = true, gameEventLoggingEnabled = false)
    finally:
      setCurrentDir(previousDir)
    check not runtime.player.scanComplete

    proc chromeOf(packet: seq[uint8]): JsonNode =
      for message in packet.parseSpritePacket():
        if message.kind == spkSprite and
            message.sprite.id == BroadcastChromeSpriteId:
          return message.sprite.label.parseJson()

    # Mid-scan: the chrome must carry NO lead payload (it ships once per
    # viewer; a half-scanned series would freeze into the HUD), and
    # momentumSent must stay false so the real one still goes out later.
    var
      viewer = initGlobalViewerState()
      nextViewer: GlobalViewerState
    let early = runtime.sim.buildReplayViewerPacket(
      runtime.player, viewer, nextViewer, newJArray())
    let earlyChrome = early.chromeOf()
    check not earlyChrome.isNil
    check not earlyChrome.hasKey("lead")
    check not earlyChrome.hasKey("lulls")
    check not earlyChrome.hasKey("beats")
    check not nextViewer.momentumSent
    viewer = nextViewer

    runtime.player.advanceReplayScan(int.high)
    check runtime.player.scanComplete
    let late = runtime.sim.buildReplayViewerPacket(
      runtime.player, viewer, nextViewer, newJArray())
    let lateChrome = late.chromeOf()
    check lateChrome.hasKey("lead")
    check nextViewer.momentumSent

  test "seeking past the scanned prefix lands exactly and survives the scan":
    # The first thing a viewer does on a slow-scanning giant board is scrub
    # ahead of the walk. The seek must land on the target (re-simulating
    # forward past the keyframe prefix, hash-checked), and the scan finishing
    # afterwards must not disturb the playback position.
    let
      data = loadReplay(CtfReplayPath)
      previousDir = getCurrentDir()
    setCurrentDir(GameDir)
    var runtime: InitializedReplay
    try:
      runtime = initReplayRuntime(
        data, mismatchQuit = true, gameEventLoggingEnabled = false)
      check not runtime.player.scanComplete
      let target = runtime.player.replayMaxTick() div 2
      runtime.player.seekReplay(runtime.sim, target)
      check runtime.sim.tickCount == target
      runtime.player.advanceReplayScan(int.high)
      check runtime.player.scanComplete
      check runtime.sim.tickCount == target
      check runtime.player.lullSpans.len > 0
    finally:
      setCurrentDir(previousDir)

suite "endzone fade ramp":
  test "a cold viewer ramps to fully cold with uniform stages, bounded bands":
    # A steal on a viewer whose prewarm has not finished must POWER DOWN the
    # endzone by holding each stage until its bands are all shipped — never
    # a frame mixing stages across bands (a horizontal seam), never more
    # than the ramp + prewarm band allowance in one packet, and always
    # reaching the fully-cold stage while the heart stays carried. Every rig
    # object a packet places must also reference a sprite def this viewer
    # has been shipped (the pose-budget fallback exists precisely to keep
    # that true).
    let
      data = loadReplay(CtfReplayPath)
      previousDir = getCurrentDir()
    setCurrentDir(GameDir)
    try:
      var runtime = initReplayRuntime(
        data, mismatchQuit = true, gameEventLoggingEnabled = false)
      runtime.player.advanceReplayScan(int.high)
      # The fixture's flag story: seek just past the LAST steal (its carry
      # runs to the capture, so the fade stays powered down long enough to
      # observe the whole ramp).
      var stealTick = -1
      for event in runtime.player.beatEvents:
        if event["k"].getStr() == "steal":
          stealTick = event["t"].getInt()
      check stealTick > 0
      runtime.player.seekReplay(runtime.sim, stealTick + 10)

      var
        viewer = initGlobalViewerState()
        shippedSprites = initHashSet[int]()
        maxStage = 0
        maxNewBands = 0
        mixedStageFrames = 0
      let bandObjectHigh =
        EndzoneFadeObjectBase + 4 * MaxEndzoneFadeBands
      for frame in 0 ..< 60:
        var nextViewer: GlobalViewerState
        let events = runtime.player.advanceReplayFrame(
          runtime.sim, runtime.tracker, [],
          (if frame == 0: @['p'] else: @[]))
        let packet = runtime.sim.buildReplayViewerPacket(
          runtime.player, viewer, nextViewer, events)
        viewer = nextViewer
        var
          newBands = 0
          stagesByTeam = initTable[int, seq[int]]()
        for message in packet.parseSpritePacket():
          case message.kind
          of spkSprite:
            shippedSprites.incl(message.sprite.id)
            if message.sprite.label.startsWith(LabelPrefixEndzone) and
                " band " in message.sprite.label:
              inc newBands
          of spkObject:
            let objectDef = message.objectDef
            if objectDef.id >= EndzoneFadeObjectBase and
                objectDef.id < bandObjectHigh:
              let key = objectDef.spriteId - endzoneFadeSpriteId(Team(0), 0, 0)
              stagesByTeam.mgetOrPut(
                key div (GlowFadeStages * MaxEndzoneFadeBands), @[]).add(
                  (key div MaxEndzoneFadeBands) mod GlowFadeStages)
            check objectDef.spriteId in shippedSprites
          else:
            discard
        for team, stages in stagesByTeam:
          for stage in stages:
            if stage != stages[0]:
              inc mixedStageFrames
            if stage > maxStage:
              maxStage = stage
        if newBands > maxNewBands:
          maxNewBands = newBands
      check maxStage == GlowFadeStages - 1
      check mixedStageFrames == 0
      # One prewarm band may ride alongside the ramp's own allowance.
      check maxNewBands <= EndzoneRampBandsPerFrame + 1
    finally:
      setCurrentDir(previousDir)
